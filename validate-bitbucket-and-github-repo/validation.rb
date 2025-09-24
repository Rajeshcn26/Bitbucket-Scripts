require 'octokit'
require 'net/http'
require 'json'
require 'date'
require 'open3'
require 'fileutils'
require 'base64'

def extract_var(body, key)
  body[/#{key}:\s*([^\n]+)/, 1]
end

def get_issue_body
  if ENV['GITHUB_EVENT_PATH'] && File.exist?(ENV['GITHUB_EVENT_PATH'])
    event = JSON.parse(File.read(ENV['GITHUB_EVENT_PATH']))
    event['issue'] ? event['issue']['body'] : ''
  else
    ""
  end
end

def get_issue_number_and_repo
  if ENV['GITHUB_EVENT_PATH'] && File.exist?(ENV['GITHUB_EVENT_PATH'])
    event = JSON.parse(File.read(ENV['GITHUB_EVENT_PATH']))
    repo = event['repository'] && event['repository']['full_name'] ? event['repository']['full_name'] : ENV['GITHUB_REPOSITORY']
    issue_number = event['issue'] && event['issue']['number'] ? event['issue']['number'] : nil
    return repo, issue_number
  end
  [ENV['GITHUB_REPOSITORY'], nil]
end

issue_body = get_issue_body

bb_project_key = extract_var(issue_body, 'bitbucket-source-project-key')
bb_repo_slug   = extract_var(issue_body, 'bitbucket-source-repo-slug')
bb_server_url  = ENV['BB_SERVER_URL'] || extract_var(issue_body, 'repo-url').sub(%r{/browse.*}, '')
gh_org         = extract_var(issue_body, 'github-target-org')
gh_repo        = extract_var(issue_body, 'github-target-repo-name')

gh_token       = ENV['GH_TOKEN']
bb_user        = ENV['BB_ACCT_USER']
bb_password    = ENV['BB_ACCT_PASSWORD']
bb_token       = ENV['BB_ACCT_TOKEN']

client = Octokit::Client.new(access_token: gh_token)
client.auto_paginate = true

def bitbucket_api(path, bb_server_url, bb_user, bb_password, bb_token)
  uri = URI("#{bb_server_url}/rest/api/1.0/#{path}")
  req = Net::HTTP::Get.new(uri)
  if bb_token && !bb_token.empty?
    req['Authorization'] = "Bearer #{bb_token}"
  else
    req.basic_auth(bb_user, bb_password)
  end
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
  JSON.parse(res.body)
end

def bitbucket_commit_count(bb_project_key, bb_repo_slug, bb_server_url, bb_user, bb_password, bb_token, branch)
  count = 0
  start = 0
  limit = 100
  more = true
  while more
    path = "projects/#{bb_project_key}/repos/#{bb_repo_slug}/commits?limit=#{limit}&start=#{start}&until=#{branch}"
    resp = bitbucket_api(path, bb_server_url, bb_user, bb_password, bb_token) rescue {}
    count += (resp['values'] ? resp['values'].size : 0)
    if resp['isLastPage'] || !resp['values'] || resp['values'].empty?
      more = false
    else
      start = resp['nextPageStart']
    end
  end
  count
end

def github_api_get_raw(url)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "token #{ENV['GH_TOKEN']}" if ENV['GH_TOKEN']
  req['Accept'] = "application/vnd.github+json"
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  res
end

def fetch_github_codeowners(org, repo, branch)
  urls = [
    "https://api.github.com/repos/#{org}/#{repo}/contents/.github/CODEOWNERS?ref=#{branch}",
    "https://api.github.com/repos/#{org}/#{repo}/contents/CODEOWNERS?ref=#{branch}"
  ]
  found = []
  urls.each do |url|
    begin
      res = github_api_get_raw(url)
      if res.is_a?(Net::HTTPSuccess)
        data = JSON.parse(res.body)
        if data && data["content"]
          content = Base64.decode64(data["content"])
          owners = content.lines.map do |line|
            next if line.strip.start_with?('#') || line.strip.empty?
            line.split(/\s+/)[1..-1]
          end.compact.flatten.uniq
          found.concat(owners)
        end
      end
    rescue
      next
    end
  end
  found.uniq
end

def fetch_github_direct_access_teams(org, repo, gh_token)
  teams = []
  page = 1
  per_page = 100
  headers = {
    "Authorization" => "token #{gh_token}",
    "Accept" => "application/vnd.github+json"
  }
  loop do
    url = URI("https://api.github.com/repos/#{org}/#{repo}/teams?per_page=#{per_page}&page=#{page}")
    req = Net::HTTP::Get.new(url, headers)
    res = Net::HTTP.start(url.hostname, url.port, use_ssl: true) { |http| http.request(req) }
    data = JSON.parse(res.body)
    break if data.empty?
    data.each do |team|
      teams << { name: team['name'], permission: team['permission'] } if !team['inherited']
    end
    break if data.size < per_page
    page += 1
  end
  teams
end

def extract_expected_teams_roles(roles_hash)
  expected = []
  roles_hash.each do |role, arr|
    arr.each do |r|
      expected << { name: r['name'],
                    permission: case role.downcase
                      when "rw" then "push"
                      when "ro" then "pull"
                      when "owner" then "admin"
                      else role end
                  }
    end
  end
  expected
end

# FIXED: Accept both 'admin' and 'maintain' as valid for owner role
def validate_teams_json_vs_github(expected_teams, github_teams)
  results = []
  expected_teams.each_with_index do |et, idx|
    gt = github_teams.find { |g| g[:name].to_s.strip.casecmp(et[:name].to_s.strip).zero? }
    perm = gt ? gt[:permission] : "-"
    status = "Validation Failed"
    if gt
      if et[:permission] == "admin"
        status = (perm == "admin" || perm == "maintain" || perm == "Repo-Owner") ? "Validation Success" : "Validation Failed"
      else
        status = (et[:permission] == perm) ? "Validation Success" : "Validation Failed"
      end
    else
      status = "Team not in GitHub"
    end
    results << { si_no: idx+1, name: et[:name], permission: et[:permission], status: status }
  end
  results
end

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
    []
  end
end

def clone_repo_if_missing(local_dir, remote_url, token=nil)
  FileUtils.rm_rf(local_dir) if Dir.exist?(local_dir)
  puts "Cloning #{remote_url} into #{local_dir} ..."
  # Use HTTPS token authentication if available
  if token && !remote_url.include?("#{token}@")
    uri = URI.parse(remote_url)
    remote_url = "https://#{token}@#{uri.host}#{uri.path}"
  end
  env = { "GIT_TERMINAL_PROMPT" => "0" }
  system(env, "git clone --depth 1 #{remote_url} #{local_dir}")
  unless Dir.exist?(local_dir)
    puts "Error: Unable to clone #{remote_url}! Skipping teams.json validation."
    return false
  end
  true
end

def read_teams_json(teams_json_path, project_key)
  data = JSON.parse(File.read(teams_json_path))
  arr = data["teams"] if data.is_a?(Hash) && data["teams"].is_a?(Array)
  arr ||= data if data.is_a?(Array)
  unless arr
    puts "ERROR: Could not find teams array in JSON"
    return nil
  end
  arr.find do |proj|
    k = (proj['Projectkey'] || proj['ProjectKey'] || proj['projectKey'] || proj['projectkey'])
    k && k.strip.casecmp(project_key.strip).zero?
  end
end

def markdown_codeowners_table(codeowners_result)
  return "\n**CodeOwners Validation:**\n\nNo CodeOwners data to validate.\n" if !codeowners_result || !codeowners_result[:expected] || codeowners_result[:expected].empty?
  <<~MD

**CodeOwners Validation:**

| Expected | Actual | Missing | Validation Status |
|----------|--------|---------|------------------|
| #{codeowners_result[:expected].join(', ')} | #{codeowners_result[:actual].join(', ')} | #{codeowners_result[:missing].join(', ')} | #{codeowners_result[:status]} |

  MD
end

metrics = []
bb_branch = bitbucket_api("projects/#{bb_project_key}/repos/#{bb_repo_slug}/branches/default", bb_server_url, bb_user, bb_password, bb_token)["displayId"] rescue nil
gh_repo_obj = client.repository("#{gh_org}/#{gh_repo}") rescue nil
gh_branch = gh_repo_obj ? gh_repo_obj.default_branch : nil
metrics << ["Default Branch Name", bb_branch, gh_branch, bb_branch == gh_branch ? "Validation Success" : "Validation Failed"]

bb_commit_count = bb_branch ? bitbucket_commit_count(bb_project_key, bb_repo_slug, bb_server_url, bb_user, bb_password, bb_token, bb_branch) : 0
gh_commits = gh_branch ? client.commits("#{gh_org}/#{gh_repo}", gh_branch) : []
gh_commit_count = gh_commits.count
metrics << ["Total Commits in Default Br.", bb_commit_count, gh_commit_count, bb_commit_count == gh_commit_count ? "Validation Success" : "Validation Failed"]

bb_commits_first_page = bitbucket_api("projects/#{bb_project_key}/repos/#{bb_repo_slug}/commits?limit=1&until=#{bb_branch}", bb_server_url, bb_user, bb_password, bb_token) rescue nil
bb_last_commit = bb_commits_first_page && bb_commits_first_page["values"] ? bb_commits_first_page["values"].first : nil
bb_last_date = bb_last_commit ? Time.at(bb_last_commit["authorTimestamp"]/1000).utc.strftime("%d %B %Y") : ""
gh_last_commit = gh_commits.first
gh_last_date = gh_last_commit ? gh_last_commit.commit.author.date.utc.strftime("%d %B %Y") : ""
metrics << ["Last Commit Date", bb_last_date, gh_last_date, bb_last_date == gh_last_date ? "Validation Success" : "Validation Failed"]

bb_author = bb_last_commit && bb_last_commit["author"] ? bb_last_commit["author"]["name"] : ""
gh_author = gh_last_commit && gh_last_commit.author ? gh_last_commit.author.login : "[bot]"
metrics << ["Last Commit Author", bb_author, gh_author, bb_author == gh_author ? "Validation Success" : "Validation Failed"]

bb_sha = bb_last_commit ? bb_last_commit["id"][0..6] : ""
gh_sha = gh_last_commit ? gh_last_commit.sha[0..6] : ""
metrics << ["Last Commit SHA", bb_sha, gh_sha, bb_sha == gh_sha ? "Validation Success" : "Validation Failed"]

bb_prs = bitbucket_api("projects/#{bb_project_key}/repos/#{bb_repo_slug}/pull-requests?state=OPEN", bb_server_url, bb_user, bb_password, bb_token) rescue nil
gh_prs = client.pull_requests("#{gh_org}/#{gh_repo}", state: 'open') rescue []
metrics << ["Open PRs", bb_prs ? bb_prs["size"] : 0, gh_prs.count, (bb_prs ? bb_prs["size"] : 0) == gh_prs.count ? "Validation Success" : "Validation Failed"]

bb_closed_prs = bitbucket_api("projects/#{bb_project_key}/repos/#{bb_repo_slug}/pull-requests?state=MERGED", bb_server_url, bb_user, bb_password, bb_token) rescue nil
gh_closed_prs = client.pull_requests("#{gh_org}/#{gh_repo}", state: 'closed') rescue []
metrics << ["Closed PRs", bb_closed_prs ? bb_closed_prs["size"] : 0, gh_closed_prs.count, (bb_closed_prs ? bb_closed_prs["size"] : 0) == gh_closed_prs.count ? "Validation Success" : "Validation Failed"]

bb_branches = bitbucket_api("projects/#{bb_project_key}/repos/#{bb_repo_slug}/branches", bb_server_url, bb_user, bb_password, bb_token) rescue nil
gh_branches = client.branches("#{gh_org}/#{gh_repo}") rescue []
metrics << ["Total Branches", bb_branches ? bb_branches["size"] : 0, gh_branches.count, (bb_branches ? bb_branches["size"] : 0) == gh_branches.count ? "Validation Success" : "Validation Failed"]

bb_tags = bitbucket_api("projects/#{bb_project_key}/repos/#{bb_repo_slug}/tags", bb_server_url, bb_user, bb_password, bb_token) rescue nil
gh_tags = client.tags("#{gh_org}/#{gh_repo}") rescue []
metrics << ["Total Tags", bb_tags ? bb_tags["size"] : 0, gh_tags.count, (bb_tags ? bb_tags["size"] : 0) == gh_tags.count ? "Validation Success" : "Validation Failed"]

teams_repo_url = "https://github.com/icesdlc/ghec.intcx.teams.git"
teams_json_path = "teams/teams.json"
work_dir = "tmp_teamsrepo_#{Time.now.to_i}"

teams_json_cloned = clone_repo_if_missing(work_dir, teams_repo_url, gh_token)
teams_json_file = File.join(work_dir, teams_json_path)
team_proj = nil
if teams_json_cloned && File.exist?(teams_json_file)
  team_proj = read_teams_json(teams_json_file, bb_project_key)
else
  puts "teams.json does not exist in cloned repo or clone failed"
end

roles_hash = team_proj && team_proj['Roles'] ? team_proj['Roles'] : {}
expected_teams = extract_expected_teams_roles(roles_hash)
expected_codeowners = team_proj && team_proj["CodeOwners"] ? team_proj["CodeOwners"].map { |n| "@#{n}" } : []
expected_webhook = team_proj && team_proj["Webhook"] ? team_proj["Webhook"] : ""

github_teams = fetch_github_direct_access_teams(gh_org, gh_repo, gh_token)
actual_webhooks = []
begin
  repo_hooks = client.hooks("#{gh_org}/#{gh_repo}")
  actual_webhooks = repo_hooks.map { |h| h[:config][:url] }
rescue => e
  puts "Error fetching repo webhook: #{e}"
end

codeowners_validation = nil
if team_proj && team_proj['CodeOwners']
  github_codeowners = fetch_github_codeowners(gh_org, gh_repo, gh_branch)
  expected_codeowners = team_proj['CodeOwners'].map { |n| "@#{n}" }
  missing = expected_codeowners.reject { |name| github_codeowners.any? { |real| real.include?(name) } }
  status = missing.empty? ? "Validation Success" : "Validation Failed"
  codeowners_validation = {
    expected: expected_codeowners,
    actual: github_codeowners,
    missing: missing,
    status: status
  }
end

teams_validation = validate_teams_json_vs_github(expected_teams, github_teams)
webhook_status = actual_webhooks.include?(expected_webhook) ? "Validation Success" : "Validation Failed"
github_custom_properties = fetch_github_custom_properties_values(gh_org, gh_repo)

report_md = []
report_md << "\n**Repository Validation Metrics:**\n"
report_md << "| Metric | Bitbucket Server | GitHub Cloud | Validation Status |"
report_md << "|--------|------------------|--------------|-------------------|"
metrics.each do |row|
  report_md << "| #{row[0]} | #{row[1]} | #{row[2]} | #{row[3]} |"
end

report_md << markdown_codeowners_table(codeowners_validation) if codeowners_validation

report_md << "\n**Webhook Validation:**\n"
report_md << "| Expected | Actual | Validation Status |"
report_md << "|----------|--------|------------------|"
report_md << "| #{expected_webhook} | #{actual_webhooks.join(', ')} | #{webhook_status} |"

report_md << "\n**Teams Validation:**\n"
report_md << "| SI No | Team Name | Permission | Validation Status |"
report_md << "|-------|-----------|------------|------------------|"
teams_validation.each do |row|
  report_md << "| #{row[:si_no]} | #{row[:name]} | #{row[:permission]} | #{row[:status]} |"
end

report_md << "\n**GitHub Custom Properties Validation:**\n"
report_md << "| SINO | Property-Name | Property-Value |"
report_md << "|------|---------------|---------------|"
github_custom_properties.each_with_index do |prop, idx|
  report_md << "| #{idx+1} | #{prop[:property_name]} | #{prop[:value]} |"
end

comment_body = report_md.join("\n")

repo_name, issue_number = get_issue_number_and_repo
if issue_number
  begin
    client.add_comment(repo_name, issue_number, comment_body)
    puts "Posted result as a comment to issue ##{issue_number} in #{repo_name}"
  rescue => e
    puts "Failed to post result as a comment: #{e.class}: #{e.message}"
  end
else
  puts "No triggering issue context found; skipping comment."
end

FileUtils.rm_rf(work_dir)
