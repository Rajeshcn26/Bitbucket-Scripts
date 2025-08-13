#!/usr/bin/env ruby
require 'net/http'
require 'json'
require 'uri'
require 'csv'

# ==== CONFIGURATION ====
BITBUCKET_BASE_URL = "https://your-bitbucket-server.com"
USERNAME = "your-username"
PASSWORD = "your-password"  # or personal access token
PROJECT_KEY = "" # Optional: set project key or leave empty to fetch from all projects
OUTPUT_CSV = "archived_repos.csv"

def fetch_archived_repos(project_key = nil)
  start = 0
  limit = 100
  archived_repos = []

  loop do
    # Build API URL
    url = if project_key && !project_key.empty?
            "#{BITBUCKET_BASE_URL}/rest/api/1.0/projects/#{project_key}/repos?start=#{start}&limit=#{limit}"
          else
            "#{BITBUCKET_BASE_URL}/rest/api/1.0/repos?start=#{start}&limit=#{limit}"
          end

    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(USERNAME, PASSWORD)

    # Send request
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(req)
    end

    # Handle errors
    unless res.code.to_i == 200
      puts "❌ Failed to fetch repositories (HTTP #{res.code})"
      break
    end

    # Parse JSON
    data = JSON.parse(res.body)

    # Select only archived repos
    archived_repos.concat(
      data["values"].select { |repo| repo["archived"] }
    )

    # Pagination check
    if data["isLastPage"]
      break
    else
      start = data["nextPageStart"]
    end
  end

  archived_repos
end

# ==== MAIN ====
repos = fetch_archived_repos(PROJECT_KEY)

if repos.empty?
  puts "No archived repositories found."
else
  CSV.open(OUTPUT_CSV, "w") do |csv|
    csv << ["Project Key", "Repo Slug", "Repo URL"]
    repos.each do |repo|
      project_key = repo["project"]["key"]
      slug = repo["slug"]
      url = repo["links"]["self"].first["href"]
      csv << [project_key, slug, url]
    end
  end

  puts "✅ Archived repositories saved to #{OUTPUT_CSV} (#{repos.size} repos)"
end
