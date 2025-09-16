require 'json'
require 'net/http'
require 'uri'
require 'dotenv/load'
require 'time'

def parse_repo_url(url)
  if url.include?('bitbucket') || url.include?('stash')
    if url =~ %r{/projects/([^/]+)/repos/([^/]+)}
      return { type: 'bitbucket', project: Regexp.last_match(1), repo: Regexp.last_match(2) }
    elsif url =~ %r{/scm/([^/]+)/([^/.]+)}
      return { type: 'bitbucket', project: Regexp.last_match(1), repo: Regexp.last_match(2) }
    end
  elsif url.include?('github.com')
    if url =~ %r{github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?(?:[/?#].*)?$}
      return { type: 'github', org: Regexp.last_match(1), repo: Regexp.last_match(2) }
    end
  end
  nil
end

def bitbucket_api_base(url)
  uri = URI(url)
  "#{uri.scheme}://#{uri.host}"
end

def bitbucket_api_get(url)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req.basic_auth(ENV['BITBUCKET_USERNAME'], ENV['BITBUCKET_TOKEN'])
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
  raise "Bitbucket API error: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

def github_api_get(url)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}"
  req['Accept'] = 'application/vnd.github+json'
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  raise "GitHub API error: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

def github_graphql_query(query)
  uri = URI("https://api.github.com/graphql")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "bearer #{ENV['GITHUB_TOKEN']}"
  req['Content-Type'] = 'application/json'
  req.body = { query: query }.to_json
  res = http.request(req)
  raise "GitHub GraphQL error: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

def fetch_bitbucket_items(type, base_url, project, repo)
  items = []
  start = 0
  loop do
    url = "#{base_url}/rest/api/1.0/projects/#{project}/repos/#{repo}/#{type}?limit=100&start=#{start}"
    data = bitbucket_api_get(url)
    items += data['values']
    break if data['isLastPage']
    start = data['nextPageStart']
  end
  items
end

def fetch_github_items(type, org, repo)
  items = []
  page = 1
  per_page = 100
  base = "https://api.github.com/repos/#{org}/#{repo}/#{type}"
  loop do
    uri = "#{base}?per_page=#{per_page}&page=#{page}"
    data = github_api_get(uri)
    break if data.empty?
    items += data
    break if data.size < per_page
    page += 1
  end
  items
end

def fetch_bitbucket_commits_count(base_url, project, repo, branch)
  count = 0
  start = 0
  loop do
    url = "#{base_url}/rest/api/1.0/projects/#{project}/repos/#{repo}/commits?until=#{branch}&limit=100&start=#{start}"
    data = bitbucket_api_get(url)
    count += data['values'].size
    break if data['isLastPage']
    start = data['nextPageStart']
  end
  count
end

def fetch_github_commits_count(org, repo, branch)
  url = "https://api.github.com/repos/#{org}/#{repo}/commits?sha=#{branch}&per_page=1"
  res = Net::HTTP.start(URI(url).hostname, 443, use_ssl: true) do |http|
    req = Net::HTTP::Get.new(URI(url))
    req['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}"
    req['Accept'] = 'application/vnd.github+json'
    http.request(req)
  end
  if res['Link'] && res['Link'][/page=(\d+)>; rel="last"/]
    $1.to_i
  else
    data = JSON.parse(res.body)
    data.is_a?(Array) ? data.size : 0
  end
end

def fetch_bitbucket_prs(base_url, project, repo, state)
  total = 0
  start = 0
  loop do
    url = "#{base_url}/rest/api/1.0/projects/#{project}/repos/#{repo}/pull-requests?state=#{state}&limit=100&start=#{start}"
    data = bitbucket_api_get(url)
    total += data['values'].size
    break if data['isLastPage']
    start = data['nextPageStart']
  end
  total
end

def fetch_github_prs(org, repo, state)
  total = 0
  page = 1
  per_page = 100
  loop do
    url = "https://api.github.com/repos/#{org}/#{repo}/pulls?state=#{state}&per_page=#{per_page}&page=#{page}"
    data = github_api_get(url)
    total += data.size
    break if data.size < per_page
    page += 1
  end
  total
end

def fetch_bitbucket_last_commit(base_url, project, repo, branch)
  url = "#{base_url}/rest/api/1.0/projects/#{project}/repos/#{repo}/commits?until=#{branch}&limit=1"
  data = bitbucket_api_get(url)
  commit = data['values'].first
  {
    date: commit['authorTimestamp'],
    author: commit['author']['name'],
    sha: commit['id']
  }
end

def fetch_github_last_commit(org, repo, branch)
  url = "https://api.github.com/repos/#{org}/#{repo}/commits?sha=#{branch}&per_page=1"
  data = github_api_get(url)
  commit = data.first
  {
    date: Time.parse(commit['commit']['committer']['date']).to_i * 1000,
    author: commit['commit']['committer']['name'],
    sha: commit['sha']
  }
end

def fetch_bitbucket_codeowners(base_url, project, repo, branch)
  url = "#{base_url}/rest/api/1.0/projects/#{project}/repos/#{repo}/files?at=#{branch}"
  data = bitbucket_api_get(url)
  data['values'].any? { |f| f =~ %r{(^|/)codeowners$}i }
end

def fetch_github_codeowners(org, repo, branch)
  urls = [
    "https://api.github.com/repos/#{org}/#{repo}/contents/.github/CODEOWNERS?ref=#{branch}",
    "https://api.github.com/repos/#{org}/#{repo}/contents/CODEOWNERS?ref=#{branch}"
  ]
  urls.any? do |url|
    begin
      github_api_get(url)
      true
    rescue
      false
    end
  end
end

# --- RECURSIVE BROWSE API FILE COUNT FOR BITBUCKET SERVER ---
def fetch_bitbucket_files_count_browse(base_url, project, repo, branch)
  count = 0
  stack = ['']
  while stack.any?
    entry = stack.pop
    browse_url = "#{base_url}/rest/api/1.0/projects/#{project}/repos/#{repo}/browse/#{entry}?at=#{branch}"
    begin
      data = bitbucket_api_get(browse_url)
    rescue => e
      raise unless entry == ''
      next
    end
    children = data.dig('children', 'values') || []
    children.each do |c|
      if c['type'] == 'DIRECTORY'
        arr = c.dig('path', 'to_a') || []
        next if arr.empty?
        stack.push(arr.join('/'))
      elsif c['type'] == 'FILE'
        count += 1
      end
    end
  end
  count
end

def fetch_github_files_count_graphql(org, repo, branch)
  query = <<~GRAPHQL
    {
      repository(owner: "#{org}", name: "#{repo}") {
        object(expression: "#{branch}:") {
          ... on Tree {
            entries {
              name
              type
              object {
                ... on Tree {
                  entries {
                    name
                    type
                    object {
                      ... on Tree {
                        entries {
                          name
                          type
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  GRAPHQL
  resp = github_graphql_query(query)
  tree = resp.dig("data", "repository", "object", "entries")
  raise "GitHub GraphQL: Unable to get tree (repo or branch may not exist, or is private and token is insufficient)" unless tree

  count_entries = lambda do |entries|
    return 0 unless entries
    entries.sum do |entry|
      if entry['type'] == 'blob'
        1
      elsif entry['type'] == 'tree'
        nested = entry.dig('object', 'entries')
        count_entries.call(nested)
      else
        0
      end
    end
  end

  count_entries.call(tree)
end

def print_table(results)
  headers = ["Metric", "BitBucket Server", "GitHub", "Validation Status"]
  table = [headers] + results.map { |r| [r[:metric], r[:bb].to_s, r[:gh].to_s, r[:status]] }
  col_widths = table.transpose.map { |col| col.map { |cell| cell.to_s.length }.max }
  sep = "+-" + col_widths.map { |w| "-" * w }.join("-+-") + "-+"
  puts "\n#{sep}"
  puts "| " + headers.each_with_index.map { |h, i| h.ljust(col_widths[i]) }.join(" | ") + " |"
  puts sep
  results.each do |row|
    cells = [row[:metric], row[:bb].to_s, row[:gh].to_s, row[:status]]
    puts "| " + cells.each_with_index.map { |cell, i| cell.ljust(col_widths[i]) }.join(" | ") + " |"
  end
  puts sep
end

if ARGV.length != 2
  puts "Usage: ruby compare_repo_stats.rb BITBUCKET_REPO_URL GITHUB_REPO_URL"
  exit 1
end

bitbucket_url, github_url = ARGV

bitbucket_info = parse_repo_url(bitbucket_url)
github_info = parse_repo_url(github_url)

unless bitbucket_info && github_info
  puts "Error: Invalid repository URLs."
  exit 1
end

bitbucket_base = bitbucket_api_base(bitbucket_url)

puts "\nFetching data from Bitbucket Server and GitHub Cloud. Please wait..."

begin
  bb_branches = fetch_bitbucket_items("branches", bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo]).map { |b| b['displayId'] }
  gh_branches = fetch_github_items("branches", github_info[:org], github_info[:repo]).map { |b| b['name'] }
  bb_tags = fetch_bitbucket_items("tags", bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo]).map { |t| t['displayId'] }
  gh_tags = fetch_github_items("tags", github_info[:org], github_info[:repo]).map { |t| t['name'] }

  bb_branch = fetch_bitbucket_items("branches", bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo]).find { |b| b['isDefault'] }
  default_branch = bb_branch ? bb_branch['displayId'] : 'master'
  gh_branch = fetch_github_items("branches", github_info[:org], github_info[:repo]).find { |b| b['name'] == default_branch }
  gh_branch ||= fetch_github_items("branches", github_info[:org], github_info[:repo]).find { |b| b['name'] == 'main' }

  bb_commit_count = fetch_bitbucket_commits_count(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], default_branch)
  gh_commit_count = fetch_github_commits_count(github_info[:org], github_info[:repo], default_branch)

  bb_open_prs = fetch_bitbucket_prs(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], 'OPEN')
  gh_open_prs = fetch_github_prs(github_info[:org], github_info[:repo], 'open')
  bb_closed_prs = fetch_bitbucket_prs(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], 'MERGED')
  gh_closed_prs = fetch_github_prs(github_info[:org], github_info[:repo], 'closed')

  bb_last_commit = fetch_bitbucket_last_commit(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], default_branch)
  gh_last_commit = fetch_github_last_commit(github_info[:org], github_info[:repo], default_branch)
  bb_last_date = Time.at(bb_last_commit[:date] / 1000).strftime("%d %B %Y")
  gh_last_date = Time.at(gh_last_commit[:date] / 1000).strftime("%d %B %Y")
  bb_last_author = bb_last_commit[:author]
  gh_last_author = gh_last_commit[:author]
  bb_last_sha = bb_last_commit[:sha]
  gh_last_sha = gh_last_commit[:sha]

  bb_codeowners = fetch_bitbucket_codeowners(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], default_branch) ? "Yes" : "No"
  gh_codeowners = fetch_github_codeowners(github_info[:org], github_info[:repo], default_branch) ? "Yes" : "No"

  # # Total Number of Files:
  # # Bitbucket: Uses the /browse API recursively to count only the files currently present in the default branch, matching how GitHub counts files in the latest tree.
  # bb_files = fetch_bitbucket_files_count_browse(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], default_branch)
  # gh_files = fetch_github_files_count_graphql(github_info[:org], github_info[:repo], default_branch)
rescue => e
  puts "Error occurred: #{e.message}"
  exit 1
end

results = [
  { metric: "Total Branch", bb: bb_branches.size, gh: gh_branches.size, status: bb_branches.size == gh_branches.size ? "Validation Success" : "Validation Failed" },
  { metric: "Total Tags", bb: bb_tags.size, gh: gh_tags.size, status: bb_tags.size == gh_tags.size ? "Validation Success" : "Validation Failed" },
  { metric: "Total commit in default branch", bb: bb_commit_count, gh: gh_commit_count, status: bb_commit_count == gh_commit_count ? "Validation Success" : "Validation Failed" },
  { metric: "Total Open PR", bb: bb_open_prs, gh: gh_open_prs, status: bb_open_prs == gh_open_prs ? "Validation Success" : "Validation Failed" },
  { metric: "Total Closed PR", bb: bb_closed_prs, gh: gh_closed_prs, status: bb_closed_prs == gh_closed_prs ? "Validation Success" : "Validation Failed" },
  { metric: "Last Commited Date", bb: bb_last_date, gh: gh_last_date, status: bb_last_date == gh_last_date ? "Validation Success" : "Validation Failed" },
  { metric: "Last commited Author", bb: bb_last_author, gh: gh_last_author, status: bb_last_author == gh_last_author ? "Validation Success" : "Validation Failed" },
  { metric: "Last Commit SHA", bb: bb_last_sha, gh: gh_last_sha, status: bb_last_sha == gh_last_sha ? "Validation Success" : "Validation Failed" },
  { metric: "CodeOwner File Exist", bb: bb_codeowners, gh: gh_codeowners, status: bb_codeowners == gh_codeowners ? "Validation Success" : "Validation Failed" }
  # { metric: "Total Number files", bb: bb_files, gh: gh_files, status: bb_files == gh_files ? "Validation Success" : "Validation Failed" }
]

print_table(results)
