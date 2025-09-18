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

def fetch_bitbucket_codeowners(base_url, project, repo, branch)
  url = "#{base_url}/rest/api/1.0/projects/#{project}/repos/#{repo}/files?at=#{branch}"
  data = bitbucket_api_get(url)
  data['values'].any? { |f| f =~ %r{(^|/)codeowners$}i }
end

def fetch_bitbucket_webhooks(base_url, project, repo)
  hooks = []
  start = 0
  loop do
    url = "#{base_url}/rest/api/1.0/projects/#{project}/repos/#{repo}/webhooks?limit=100&start=#{start}"
    data = bitbucket_api_get(url)
    hooks += data['values'].map { |h| h['name'] || h['url'] || h['id'].to_s }
    break if data['isLastPage']
    start = data['nextPageStart']
  end
  hooks.uniq
end

def github_api_get_raw(url)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}"
  req['Accept'] = 'application/vnd.github+json'
  req['X-GitHub-Api-Version'] = '2022-11-28'
  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
end

def github_api_get(url, max_retries = 5)
  retries = 0
  begin
    res = github_api_get_raw(url)
    if res.code == '403' && res['X-RateLimit-Remaining'] == '0'
      reset_epoch = res['X-RateLimit-Reset'].to_i
      wait_time = [reset_epoch - Time.now.to_i, 1].max
      puts "Rate limit exceeded. Waiting #{wait_time} seconds to retry..."
      sleep(wait_time)
      raise 'Rate limit, retry'
    end
    [res.code, JSON.parse(res.body)]
  rescue => e
    retries += 1
    raise if retries > max_retries
    sleep(2 ** retries)
    retry
  end
end

def fetch_github_items(type, org, repo)
  items = []
  page = 1
  per_page = 100
  base = "https://api.github.com/repos/#{org}/#{repo}/#{type}"
  loop do
    uri = "#{base}?per_page=#{per_page}&page=#{page}"
    _code, data = github_api_get(uri)
    break if data.empty?
    items += data
    break if data.size < per_page
    page += 1
  end
  items
end

def fetch_github_commits_count(org, repo, branch)
  url = "https://api.github.com/repos/#{org}/#{repo}/commits?sha=#{branch}&per_page=1"
  res = github_api_get_raw(url)
  if res['Link'] && res['Link'][/page=(\d+)>; rel="last"/]
    $1.to_i
  else
    data = JSON.parse(res.body)
    data.is_a?(Array) ? data.size : 0
  end
end

def fetch_github_prs(org, repo, state)
  total = 0
  page = 1
  per_page = 100
  loop do
    url = "https://api.github.com/repos/#{org}/#{repo}/pulls?state=#{state}&per_page=#{per_page}&page=#{page}"
    _code, data = github_api_get(url)
    total += data.size
    break if data.size < per_page
    page += 1
  end
  total
end

def fetch_github_last_commit(org, repo, branch)
  url = "https://api.github.com/repos/#{org}/#{repo}/commits?sha=#{branch}&per_page=1"
  _code, data = github_api_get(url)
  commit = data.first
  {
    date: Time.parse(commit['commit']['committer']['date']).to_i * 1000,
    author: commit['commit']['committer']['name'],
    sha: commit['sha']
  }
end

def fetch_github_codeowners(org, repo, branch)
  urls = [
    "https://api.github.com/repos/#{org}/#{repo}/contents/.github/CODEOWNERS?ref=#{branch}",
    "https://api.github.com/repos/#{org}/#{repo}/contents/CODEOWNERS?ref=#{branch}"
  ]
  urls.any? do |url|
    begin
      _code, _data = github_api_get(url)
      true
    rescue
      false
    end
  end
end

def fetch_github_direct_access_teams(org, repo)
  teams = []
  page = 1
  per_page = 100
  loop do
    url = "https://api.github.com/repos/#{org}/#{repo}/teams?per_page=#{per_page}&page=#{page}"
    _code, data = github_api_get(url)
    break if data.empty?
    data.each do |team|
      teams << { name: team['name'], permission: team['permission'] } if !team['inherited']
    end
    break if data.size < per_page
    page += 1
  end
  teams
end

def fetch_github_webhooks(org, repo)
  hooks = []
  page = 1
  per_page = 100
  loop do
    url = "https://api.github.com/repos/#{org}/#{repo}/hooks?per_page=#{per_page}&page=#{page}"
    _code, data = github_api_get(url)
    break if data.empty?
    hooks += data.map { |h| h['name'] || h['url'] || h['id'].to_s }
    break if data.size < per_page
    page += 1
  end
  hooks.uniq
end

# --- GITHUB CUSTOM PROPERTIES, support both array and hash structure ---
def fetch_github_custom_properties_values(org, repo)
  url = "https://api.github.com/repos/#{org}/#{repo}/properties/values"
  res = github_api_get_raw(url)
  if res.is_a?(Net::HTTPSuccess)
    properties = JSON.parse(res.body)
    if properties.is_a?(Array) && !properties.empty?
      properties.map do |item|
        {
          property_name: item["property_name"] || item["name"] || item.keys.first,
          value: item["value"] || item.values.last
        }
      end
    elsif properties.is_a?(Hash) && !properties.empty?
      properties.map { |k, v| { property_name: k, value: v } }
    else
      []
    end
  else
    puts "HTTP Error fetching custom properties: #{res.code} #{res.message}"
    puts res.body
    []
  end
end

def print_table(results)
  headers = ["Metric", "Bitbucket Server", "GitHub", "Validation Status"]
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

def print_teams_table(teams)
  headers = ["SI No", "Team Name", "Permission"]
  col_widths = [6, [25, *teams.map { |t| t[:name].to_s.length }].max, [12, *teams.map { |t| t[:permission].to_s.length }].max]
  sep = "+-" + col_widths.map { |w| "-"*w }.join("-+-") + "-+"
  puts "\n#{sep}"
  puts "| " + headers.each_with_index.map { |h, i| h.ljust(col_widths[i]) }.join(" | ") + " |"
  puts sep
  teams.each_with_index do |team, idx|
    puts "| #{(idx+1).to_s.ljust(col_widths[0])} | #{team[:name].ljust(col_widths[1])} | #{team[:permission].ljust(col_widths[2])} |"
  end
  puts sep
end

def print_webhooks_table(hooks_results)
  headers = ["SI No", "Webhook Name", "Bitbucket Server", "GitHub", "Validation Status"]
  col_widths = [6, [14, *hooks_results.map { |h| h[:name].to_s.length }].max, 16, 8, 20]
  sep = "+-" + col_widths.map { |w| "-"*w }.join("-+-") + "-+"
  puts "\n#{sep}"
  puts "| " + headers.each_with_index.map { |h, i| h.ljust(col_widths[i]) }.join(" | ") + " |"
  puts sep
  if hooks_results.empty?
    puts "| " + "No webhooks found in either Bitbucket Server or GitHub repository.".ljust(col_widths.sum + (col_widths.size-1)*3) + " |"
  else
    hooks_results.each do |row|
      puts "| #{row[:si_no].to_s.ljust(col_widths[0])} | #{row[:name].ljust(col_widths[1])} | #{row[:bb].ljust(col_widths[2])} | #{row[:gh].ljust(col_widths[3])} | #{row[:status].ljust(col_widths[4])} |"
    end
  end
  puts sep
end

def print_github_custom_properties_table(props)
  headers = ["SINo", "Property-Name", "Property-Value"]
  col_widths = [
    5,
    [14, *props.map { |p| p[:property_name].to_s.length }].max,
    [14, *props.map { |p| p[:value].to_s.length }].max
  ]
  sep = "+-" + col_widths.map { |w| "-" * w }.join("-+-") + "-+"
  puts "\n#{sep}"
  puts "| " + headers.each_with_index.map { |h, i| h.ljust(col_widths[i]) }.join(" | ") + " |"
  puts sep
  if props.empty?
    puts "| " + "No custom properties found for this GitHub repository.".ljust(col_widths.sum + (col_widths.size-1)*3) + " |"
  else
    props.each_with_index do |prop, idx|
      puts "| #{(idx+1).to_s.ljust(col_widths[0])} | #{prop[:property_name].to_s.ljust(col_widths[1])} | #{prop[:value].to_s.ljust(col_widths[2])} |"
    end
  end
  puts sep
end

def compare_webhooks(bb_hooks, gh_hooks)
  all_hooks = (bb_hooks + gh_hooks).uniq
  results = []
  all_hooks.each_with_index do |name, idx|
    bb_present = bb_hooks.include?(name)
    gh_present = gh_hooks.include?(name)
    status = bb_present && gh_present ? "Validation Success" : "Validation Failed"
    results << {
      si_no: idx + 1,
      name: name,
      bb: bb_present ? "yes" : "no",
      gh: gh_present ? "yes" : "no",
      status: status
    }
  end
  results
end

if __FILE__ == $0
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
    gh_branch = gh_branches.include?(default_branch) ? default_branch : (gh_branches.include?('main') ? 'main' : gh_branches.first)

    bb_commit_count = fetch_bitbucket_commits_count(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], default_branch)
    gh_commit_count = fetch_github_commits_count(github_info[:org], github_info[:repo], gh_branch)

    bb_open_prs = fetch_bitbucket_prs(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], 'OPEN')
    gh_open_prs = fetch_github_prs(github_info[:org], github_info[:repo], 'open')
    bb_closed_prs = fetch_bitbucket_prs(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], 'MERGED')
    gh_closed_prs = fetch_github_prs(github_info[:org], github_info[:repo], 'closed')

    bb_last_commit = fetch_bitbucket_last_commit(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], default_branch)
    gh_last_commit = fetch_github_last_commit(github_info[:org], github_info[:repo], gh_branch)
    bb_last_date = Time.at(bb_last_commit[:date] / 1000).strftime("%d %B %Y")
    gh_last_date = Time.at(gh_last_commit[:date] / 1000).strftime("%d %B %Y")
    bb_last_author = bb_last_commit[:author]
    gh_last_author = gh_last_commit[:author]
    bb_last_sha = bb_last_commit[:sha]
    gh_last_sha = gh_last_commit[:sha]

    bb_codeowners = fetch_bitbucket_codeowners(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo], default_branch) ? "Yes" : "No"
    gh_codeowners = fetch_github_codeowners(github_info[:org], github_info[:repo], gh_branch) ? "Yes" : "No"

    github_teams = fetch_github_direct_access_teams(github_info[:org], github_info[:repo])

    bb_webhooks = fetch_bitbucket_webhooks(bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo])
    gh_webhooks = fetch_github_webhooks(github_info[:org], github_info[:repo])
    webhook_comparison = compare_webhooks(bb_webhooks, gh_webhooks)

    github_custom_props = fetch_github_custom_properties_values(github_info[:org], github_info[:repo])
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
  ]

  print_table(results)

  if github_teams.any?
    print_teams_table(github_teams)
  else
    puts "\nNo direct access teams found for this GitHub repository."
  end

  print_webhooks_table(webhook_comparison)

  print_github_custom_properties_table(github_custom_props)
end
