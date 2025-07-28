require 'json'
require 'net/http'
require 'uri'
require 'dotenv/load'

def parse_repo_url(url)
  if url.include?('bitbucket')
    if url =~ %r{bitbucket[^/]+/scm/([^/]+)/([^/.]+)}
      return { type: 'bitbucket', project: Regexp.last_match(1), repo: Regexp.last_match(2) }
    end
  elsif url.include?('github.com')
    if url =~ %r{github\.com[:/]+([^/]+)/([^/.]+)}
      return { type: 'github', org: Regexp.last_match(1), repo: Regexp.last_match(2) }
    end
  end
  nil
end

def fetch_bitbucket_items(type, base_url, project_key, repo_slug)
  items = []
  start = 0
  loop do
    url = "#{base_url}/rest/api/1.0/projects/#{project_key}/repos/#{repo_slug}/#{type}?limit=100&start=#{start}"
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(ENV['BITBUCKET_USERNAME'], ENV['BITBUCKET_TOKEN'])

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
    raise "Bitbucket API error: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)

    data = JSON.parse(res.body)
    items += data['values'].map do |item|
      type == "tags" ? item['displayId'] || item['id'].gsub('refs/tags/', '') : item['displayId']
    end
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
    uri = URI("#{base}?per_page=#{per_page}&page=#{page}")
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}"
    req['Accept'] = 'application/vnd.github+json'

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
    raise "GitHub API error: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)

    data = JSON.parse(res.body)
    break if data.empty?

    items += data.map { |b| b['name'] }
    break if data.size < per_page

    page += 1
  end
  items
end

def print_table(title, bb_count, gh_count, missing_list)
  puts "\n=== #{title} Comparison ==="
  puts "+---------------------+----------------+----------------+"
  puts "| Metric              | Bitbucket      | GitHub         |"
  puts "+---------------------+----------------+----------------+"
  puts "| Total Count         | #{bb_count.to_s.ljust(14)} | #{gh_count.to_s.ljust(14)} |"
  puts "| Missing in GitHub   | #{missing_list.size.to_s.ljust(14)} | -              |"
  puts "+---------------------+----------------+----------------+"

  unless missing_list.empty?
    puts "\nMissing #{title.downcase} in GitHub:"
    puts "+--------------------------+"
    puts "| Name                     |"
    puts "+--------------------------+"
    missing_list.sort.each { |name| puts "| #{name.ljust(24)} |" }
    puts "+--------------------------+"
  end
end

if ARGV.length != 2
  puts "Usage: ruby compare_repos.rb BITBUCKET_REPO_URL GITHUB_REPO_URL"
  exit 1
end

bitbucket_url, github_url = ARGV

bitbucket_info = parse_repo_url(bitbucket_url)
github_info = parse_repo_url(github_url)

unless bitbucket_info && github_info
  puts "Error: Invalid repository URLs."
  exit 1
end

bitbucket_base = bitbucket_url.split('/scm/').first

puts "\nFetching Bitbucket and GitHub data. Please wait..."

begin
  bb_branches = fetch_bitbucket_items("branches", bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo])
  bb_tags = fetch_bitbucket_items("tags", bitbucket_base, bitbucket_info[:project], bitbucket_info[:repo])
  gh_branches = fetch_github_items("branches", github_info[:org], github_info[:repo])
  gh_tags = fetch_github_items("tags", github_info[:org], github_info[:repo])
rescue => e
  puts "Error occurred: #{e.message}"
  exit 1
end

missing_branches = bb_branches - gh_branches
missing_tags = bb_tags - gh_tags

print_table("Branches", bb_branches.size, gh_branches.size, missing_branches)
print_table("Tags", bb_tags.size, gh_tags.size, missing_tags)
