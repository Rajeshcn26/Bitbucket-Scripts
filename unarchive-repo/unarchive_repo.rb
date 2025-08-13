#!/usr/bin/env ruby
require 'csv'
require 'net/http'
require 'json'
require 'uri'

# ==== CONFIGURATION ====
BITBUCKET_BASE_URL = "https://your-bitbucket-server.com"
USERNAME = "your-username"
PASSWORD = "your-password"  # or personal access token

CSV_FILE = "repos.csv"  # CSV containing repo URLs (one per line)

# ==== FUNCTION TO UNARCHIVE ====
def unarchive_repo(project_key, repo_slug)
  uri = URI("#{BITBUCKET_BASE_URL}/rest/api/1.0/projects/#{project_key}/repos/#{repo_slug}")
  
  req = Net::HTTP::Put.new(uri)
  req.content_type = "application/json"
  req.body = { archived: false }.to_json
  req.basic_auth(USERNAME, PASSWORD)

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.request(req)
  end

  if res.code.to_i == 200
    puts "✅ Successfully unarchived #{project_key}/#{repo_slug}"
  else
    puts "❌ Failed to unarchive #{project_key}/#{repo_slug} (HTTP #{res.code})"
  end
end

# ==== MAIN ====
CSV.foreach(CSV_FILE) do |row|
  repo_url = row[0].strip
  if repo_url =~ %r{/projects/([^/]+)/repos/([^/]+)}
    project_key = $1
    repo_slug = $2
    unarchive_repo(project_key, repo_slug)
  else
    puts "⚠️ Invalid repo URL format: #{repo_url}"
  end
end
