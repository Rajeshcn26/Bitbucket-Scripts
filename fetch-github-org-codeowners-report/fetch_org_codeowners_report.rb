require 'net/http'
require 'json'
require 'csv'
require 'uri'
require 'date'

# === CONFIGURE ===
GITHUB_TOKEN = ENV['GITHUB_TOKEN'] # Set your GitHub token as an environment variable
ORG_NAME = "ps-resources"          # <-- CHANGE to your org if needed
PER_PAGE = 100

def github_api_request(uri)
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "token #{GITHUB_TOKEN}" if GITHUB_TOKEN
  req['User-Agent'] = "Ruby Script"
  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(req)
  end
end

def fetch_repositories(since_date, org_name)
  repos = []
  page = 1
  puts "Fetching repositories created since #{since_date} for organization #{org_name}..."
  loop do
    q = "org:#{org_name} created:>=#{since_date}"
    url = URI("https://api.github.com/search/repositories?q=#{URI.encode_www_form_component(q)}&sort=created&order=desc&per_page=#{PER_PAGE}&page=#{page}")
    resp = github_api_request(url)
    raise "Failed to fetch repos: #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)
    body = JSON.parse(resp.body)
    repos += body['items']
    puts "Fetched page #{page}, total repos so far: #{repos.size}"
    break if repos.size >= body['total_count'] || body['items'].empty? || page >= 10
    page += 1
  end
  puts "Total repositories fetched: #{repos.size}"
  repos
end

def has_codeowners?(repo_full_name, default_branch)
  codeowners_paths = [
    "CODEOWNERS",
    ".github/CODEOWNERS",
    "docs/CODEOWNERS"
  ]
  codeowners_paths.any? do |path|
    url = URI("https://api.github.com/repos/#{repo_full_name}/contents/#{path}?ref=#{default_branch}")
    resp = github_api_request(url)
    resp.is_a?(Net::HTTPSuccess)
  end
end

# === MAIN ===
since_date = (Date.today << 1).strftime("%Y-%m-%d") # 1 month ago
repositories = fetch_repositories(since_date, ORG_NAME)

csv_rows = []
header = %w[repo_name repo_url has_codeowners_file]
csv_rows << header

repositories.each_with_index do |repo, idx|
  repo_name = repo['full_name']
  repo_url = repo['html_url']
  default_branch = repo['default_branch']
  codeowners = has_codeowners?(repo_name, default_branch)
  csv_rows << [repo_name, repo_url, codeowners ? "yes" : "no"]
  puts "[#{idx+1}/#{repositories.size}] #{repo_name} - CODEOWNERS: #{codeowners ? 'yes' : 'no'}"
end

puts "\n=== CSV Output ==="
csv_string = CSV.generate do |csv|
  csv_rows.each { |row| csv << row }
end
puts csv_string

File.write("output.csv", csv_string)
puts "\nCSV also written to output.csv"
