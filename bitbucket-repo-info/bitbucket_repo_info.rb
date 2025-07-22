require 'net/http'
require 'uri'
require 'json'
require 'csv'
require 'dotenv/load' # gem install dotenv

BITBUCKET_USER = ENV['BITBUCKET_USER']
BITBUCKET_PASS = ENV['BITBUCKET_PASS'] || ENV['BITBUCKET_TOKEN']

INPUT_CSV = 'repos.csv'
OUTPUT_CSV = 'output.csv'

def parse_url(url)
  m = url.match(%r{(https?://[^/]+)/projects/([^/]+)/repos/([^/]+)})
  raise "Invalid URL: #{url}" unless m
  { base_url: m[1], project: m[2], repo: m[3] }
end

def api_get(base_url, endpoint, params = {})
  uri = URI("#{base_url}#{endpoint}")
  uri.query = URI.encode_www_form(params) if params.any?

  req = Net::HTTP::Get.new(uri)
  req.basic_auth(BITBUCKET_USER, BITBUCKET_PASS) if BITBUCKET_USER && BITBUCKET_PASS

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  res = http.request(req)
  raise "HTTP #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

def paged_count(base_url, endpoint_with_params)
  count = 0
  start = 0
  loop do
    endpoint, param_str = endpoint_with_params.split('?', 2)
    params = { limit: 100, start: start }
    if param_str
      param_str.split('&').each do |pair|
        k, v = pair.split('=')
        params[k.to_sym] = v
      end
    end
    data = api_get(base_url, endpoint, params)
    count += data['values'].size
    break unless data['isLastPage'] == false
    start = data['nextPageStart']
  end
  count
end

def fetch_repo_url(repo_info)
  # Fetch the self link which is the actual repo URL
  return '' unless repo_info['links'] && repo_info['links']['self']
  self_link = repo_info['links']['self'].find { |c| c['href'].start_with?('http://') || c['href'].start_with?('https://') }
  self_link ? self_link['href'] : ''
end

def fetch_repo_info(url)
  parsed = parse_url(url)
  base_url, project, repo = parsed.values_at(:base_url, :project, :repo)
  repo_info = api_get(base_url, "/rest/api/1.0/projects/#{project}/repos/#{repo}")
  repo_url = fetch_repo_url(repo_info)
  total_branches = paged_count(base_url, "/rest/api/1.0/projects/#{project}/repos/#{repo}/branches")
  total_tags = paged_count(base_url, "/rest/api/1.0/projects/#{project}/repos/#{repo}/tags")
  open_prs = paged_count(base_url, "/rest/api/1.0/projects/#{project}/repos/#{repo}/pull-requests?state=OPEN")
  closed_prs_merged = paged_count(base_url, "/rest/api/1.0/projects/#{project}/repos/#{repo}/pull-requests?state=MERGED")
  closed_prs_declined = paged_count(base_url, "/rest/api/1.0/projects/#{project}/repos/#{repo}/pull-requests?state=DECLINED")
  closed_prs = closed_prs_merged + closed_prs_declined

  {
    project: project,
    repo: repo,
    repo_url: repo_url,
    branches: total_branches,
    tags: total_tags,
    open_prs: open_prs,
    closed_prs: closed_prs
  }
end

def main
  results = []

  CSV.foreach(INPUT_CSV, headers: true) do |row|
    url = row['url']
    begin
      info = fetch_repo_info(url)
      puts "#{info[:project]}, #{info[:repo]}, Repo URL: #{info[:repo_url]}, Branches: #{info[:branches]}, Tags: #{info[:tags]}, Open PRs: #{info[:open_prs]}, Closed PRs: #{info[:closed_prs]}"
      results << [info[:project], info[:repo], info[:repo_url], info[:branches], info[:tags], info[:open_prs], info[:closed_prs]]
    rescue => e
      puts "Error processing #{url}: #{e}"
    end
  end

  file_exists = File.exist?(OUTPUT_CSV)
  CSV.open(OUTPUT_CSV, "a") do |csv|
    unless file_exists
      csv << %w[Project Repo Repo_URL Branches Tags Open_PRs Closed_PRs]
    end
    results.each { |row| csv << row }
  end
end

main
