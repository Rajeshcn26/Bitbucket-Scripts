require 'octokit'
require 'net/http'
require 'json'
require 'date'
require 'open3'
require 'fileutils'
require 'base64'

def safe(val)
  (val.nil? || val.to_s.strip.empty?) ? "-" : val
end

def github_api_request_with_rate_limit(req, uri)
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  if res.code == "403" && res['X-RateLimit-Remaining'] == "0"
    reset_time = res['X-RateLimit-Reset'].to_i
    now = Time.now.to_i
    wait = [reset_time - now, 1].max
    puts "Rate limit exceeded, sleeping for #{wait} seconds..."
    sleep(wait)
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  end
  res
end

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

def bitbucket_all_tags_count(bb_project_key, bb_repo_slug, bb_server_url, bb_user, bb_password, bb_token)
  start = 0
  limit = 100
  count = 0
  loop do
    path = "projects/#{bb_project_key}/repos/#{bb_repo_slug}/tags?limit=#{limit}&start=#{start}"
    resp = bitbucket_api(path, bb_server_url, bb_user, bb_password, bb_token) rescue {}
    tags = resp['values'] || []
    count += tags.size
    break if resp['isLastPage'] || tags.empty?
    start = resp['nextPageStart']
  end
  count
end

def bitbucket_all_branches_count(bb_project_key, bb_repo_slug, bb_server_url, bb_user, bb_password, bb_token)
  start = 0
  limit = 100
  count = 0
  loop do
    path = "projects/#{bb_project_key}/repos/#{bb_repo_slug}/branches?limit=#{limit}&start=#{start}"
    resp = bitbucket_api(path, bb_server_url, bb_user, bb_password, bb_token) rescue {}
    branches = resp['values'] || []
    count += branches.size
    break if resp['isLastPage'] || branches.empty?
    start = resp['nextPageStart']
  end
  count
end

def bitbucket_all_prs_count(bb_project_key, bb_repo_slug, bb_server_url, bb_user, bb_password, bb_token, state)
  start = 0
  limit = 100
  count = 0
  loop do
    path = "projects/#{bb_project_key}/repos/#{bb_repo_slug}/pull-requests?state=#{state}&limit=#{limit}&start=#{start}"
    resp = bitbucket_api(path, bb_server_url, bb_user, bb_password, bb_token) rescue {}
    prs = resp['values'] || []
    count += prs.size
    break if resp['isLastPage'] || prs.empty?
    start = resp['nextPageStart']
  end
  count
end

def github_api_get_raw(url)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "token #{ENV['GH_TOKEN']}" if ENV['GH_TOKEN']
  req['Accept'] = "application/vnd.github+json"
  github_api_request_with_rate_limit(req, uri)
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
    res = github_api_request_with_rate_limit(req, url)
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

def validate_teams_json_vs_github(expected_teams, github_teams)
  results = []
  expected_teams.each_with_index do |et, idx|
    gt = github_teams.find { |g| g[:name].to_s.strip.casecmp(et[:name].to_s.strip).zero? }
    perm = gt ? gt[:permission] : "-"
    status = "Validation Failed"
    if gt
      if et[:permission] == "admin"
        status = ["admin", "maintain", "Repo-Owner"].include?(perm) ? "Validation Success" : "Validation Failed"
      else
        status = (et[:permission] == perm) ? "Validation Success" : "Validation Failed"
      end
    else
      status = "Team not in GitHub"
    end
    results << { si_no: safe(idx+1), name: safe(et[:name]), permission: safe(et[:permission]), status: safe(status) }
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
          property_name: safe(item["property_name"] || item["name"] || item.keys.first),
          value: safe(item["value"] || item.values.last)
        }
      end
    elsif properties.is_a?(Hash) && !properties.empty?
      properties.map { |k, v| { property_name: safe(k), value: safe(v) } }
    else
      []
    end
  else
    []
  end
end

def clone_repo_if_missing(local_dir, remote_url, opts={})
  return true if Dir.exist?(local_dir) # already exists
  puts "Cloning into '#{local_dir}'..."

  url = remote_url.dup
  if opts[:type] == :bitbucket
    if opts[:token] && !opts[:token].empty?
      url = url.sub('https://', "https://x-token-auth:#{opts[:token]}@")
    elsif opts[:user] && opts[:password]
      url = url.sub('https://', "https://#{opts[:user]}:#{opts[:password]}@")
    end
  elsif opts[:type] == :github
    if opts[:token] && !opts[:token].empty?
      url = url.sub('https://', "https://#{opts[:token]}@")
    end
  end

  url_safe = url.gsub(/(\/\/)(.*):(.*)@/, '\1****:****@')
  puts "Cloning #{url_safe} ..."

  system("git clone --depth 1 #{url} #{local_dir}")
  unless Dir.exist?(local_dir)
    puts "Error: Unable to clone #{remote_url}!"
    return false
  end
  system("cd #{local_dir} && git lfs pull")
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
| #{safe(codeowners_result[:expected].join(', '))} | #{safe(codeowners_result[:actual].join(', '))} | #{safe(codeowners_result[:missing].join(', '))} | #{safe(codeowners_result[:status])} |

  MD
end

def lfs_files_and_shas_and_size(repo_path)
  lfs_files = []
  lfs_list = `cd #{repo_path} && git lfs ls-files`
  lfs_list.split("\n").each do |line|
    if line =~ /^([0-9a-f]+)\s+\*\s+(.+)$/
      sha = $1
      file = $2
      size = "-"
      file_path = File.join(repo_path, file)
      if File.exist?(file_path)
        size_bytes = File.size(file_path)
        size = (size_bytes.to_f / (1024*1024)).round(1)
      end
      lfs_files << { sha: sha, path: file, size: size }
    end
  end
  lfs_files
end

def lfs_validation_table(bb_repo_path, gh_repo_path)
  bb_lfs = lfs_files_and_shas_and_size(bb_repo_path)
  gh_lfs = lfs_files_and_shas_and_size(gh_repo_path)
  all_files = (bb_lfs.map{|f| f[:path]} | gh_lfs.map{|f| f[:path]})
  lfs_comparison = []
  bb_total = 0.0
  gh_total = 0.0

  all_files.each_with_index do |file, idx|
    bb_info = bb_lfs.find{ |f| f[:path] == file }
    gh_info = gh_lfs.find{ |f| f[:path] == file }
    bb_sha = bb_info ? bb_info[:sha] : "-"
    bb_size = bb_info ? bb_info[:size] : "-"
    gh_sha = gh_info ? gh_info[:sha] : "-"
    gh_size = gh_info ? gh_info[:size] : "-"
    status = (bb_sha == gh_sha && bb_size == gh_size) ? "Validation Success" : "Validation Failed"
    lfs_comparison << [
      safe(idx+1),
      "#{safe(bb_sha)} * #{safe(file)}",
      safe(bb_size),
      "#{safe(gh_sha)} * #{safe(file)}",
      safe(gh_size),
      safe(status)
    ]
    bb_total += bb_size == "-" ? 0.0 : bb_size.to_f
    gh_total += gh_size == "-" ? 0.0 : gh_size.to_f
  end

  md = []
  md << "\n**LFS Validation:**\n"
  md << "| SI NO | Bitbucket-Server-File/Path | Size (MB) | GitHub-File/Path | Size (MB) | Validation Status |"
  md << "|-------|----------------------------|-----------|------------------|-----------|-------------------|"
  lfs_comparison.each do |row|
    md << "| #{row[0]} | #{row[1]} | #{row[2]} | #{row[3]} | #{row[4]} | #{row[5]} |"
  end
  md << "| Total Size (MB) | | #{safe(bb_total)} | | #{safe(gh_total)} | |"
  md.join("\n")
end

# ====================
# Main Validation Script
# ====================
issue_body = get_issue_body

bb_project_key = extract_var(issue_body, 'bitbucket-source-project-key')
bb_repo_slug   = extract_var(issue_body, 'bitbucket-source-repo-slug')

repo_url_var = extract_var(issue_body, 'repo-url')
bb_server_url  = ENV['BB_SERVER_URL'] || (repo_url_var ? repo_url_var.sub(%r{/browse.*}, '') : nil)
gh_org         = extract_var(issue_body, 'github-target-org')
gh_repo        = extract_var(issue_body, 'github-target-repo-name')

gh_token       = ENV['GH_TOKEN']
bb_user        = ENV['BB_ACCT_USER']
bb_password    = ENV['BB_ACCT_PASSWORD']
bb_token       = ENV['BB_ACCT_TOKEN']

client = Octokit::Client.new(access_token: gh_token)
client.auto_paginate = true

# --- Compose Bitbucket and GitHub Clone URLs with credentials ---
bitbucket_repo_url = extract_var(issue_body, 'bitbucket-source-http-url')
github_repo_url = extract_var(issue_body, 'github-target-http-url')

if !bitbucket_repo_url && bb_server_url && bb_project_key && bb_repo_slug
  bitbucket_repo_url = "#{bb_server_url}/scm/#{bb_project_key.downcase}/#{bb_repo_slug.downcase}.git"
end
if !github_repo_url && gh_org && gh_repo
  github_repo_url = "https://github.com/#{gh_org}/#{gh_repo}.git"
end

# --- Clone both repos with credentials ---
clone_repo_if_missing('bb-repo', bitbucket_repo_url, type: :bitbucket, user: bb_user, password: bb_password, token: bb_token)
clone_repo_if_missing('gh-repo', github_repo_url, type: :github, token: gh_token)

metrics = []
bb_branch = bitbucket_api("projects/#{bb_project_key}/repos/#{bb_repo_slug}/branches/default", bb_server_url, bb_user, bb_password, bb_token)["displayId"] rescue nil
gh_repo_obj = client.repository("#{gh_org}/#{gh_repo}") rescue nil
gh_branch = gh_repo_obj ? gh_repo_obj.default_branch : nil
metrics << ["Default Branch Name", safe(bb_branch), safe(gh_branch), safe(bb_branch == gh_branch ? "Validation Success" : "Validation Failed")]

bb_commit_count = bb_branch ? bitbucket_commit_count(bb_project_key, bb_repo_slug, bb_server_url, bb_user, bb_password, bb_token, bb_branch) : 0
gh_commits = gh_branch ? client.commits("#{gh_org}/#{gh_repo}", gh_branch) : []
gh_commit_count = gh_commits.count
metrics << ["Total Commits in Default Br.", safe(bb_commit_count), safe(gh_commit_count), safe(bb_commit_count == gh_commit_count ? "Validation Success" : "Validation Failed")]

bb_commits_first_page = bitbucket_api("projects/#{bb_project_key}/repos/#{bb_repo_slug}/commits?limit=1&until=#{bb_branch}", bb_server_url, bb_user, bb_password, bb_token) rescue nil
bb_last_commit = bb_commits_first_page && bb_commits_first_page["values"] ? bb_commits_first_page["values"].first : nil
bb_last_date = bb_last_commit ? Time.at(bb_last_commit["authorTimestamp"]/1000).utc.strftime("%d %B %Y") : "-"
gh_last_commit = gh_commits.first rescue nil
gh_last_date = gh_last_commit ? gh_last_commit.commit.author.date.utc.strftime("%d %B %Y") : "-"
metrics << ["Last Commit Date", safe(bb_last_date), safe(gh_last_date), safe(bb_last_date == gh_last_date ? "Validation Success" : "Validation Failed")]

bb_author = bb_last_commit && bb_last_commit["author"] ? bb_last_commit["author"]["name"] : "-"

gh_author = "-"
if gh_last_commit
  login = nil
  if gh_last_commit.author && gh_last_commit.author.login
    login = gh_last_commit.author.login
  elsif gh_last_commit.commit && gh_last_commit.commit.author && gh_last_commit.commit.author.name
    login = gh_last_commit.commit.author.name
  end
  gh_author = safe(login)
  if !gh_author.eql?("-") && gh_author.downcase.include?("bot")
    gh_author = "#{gh_author} (bot)"
  end
end

metrics << ["Last Commit Author", safe(bb_author), safe(gh_author), safe(bb_author == gh_author ? "Validation Success" : "Validation Failed")]

bb_sha = bb_last_commit ? bb_last_commit["id"][0..6] : "-"
gh_sha = gh_last_commit ? gh_last_commit.sha[0..6] : "-"
metrics << ["Last Commit SHA", safe(bb_sha), safe(gh_sha), safe(bb_sha == gh_sha ? "Validation Success" : "Validation Failed")]

# Paginated PRs
bb_open_pr_count = bitbucket_all_prs_count(bb_project_key, bb_repo_slug, bb_server_url, bb_user, bb_password, bb_token, "OPEN")
gh_prs = client.pull_requests("#{gh_org}/#{gh_repo}", state: 'open') rescue []
metrics << ["Open PRs", safe(bb_open_pr_count), safe(gh_prs.count), safe(bb_open_pr_count == gh_prs.count ? "Validation Success" : "Validation Failed")]

bb_closed_pr_count = bitbucket_all_prs_count(bb_project_key, bb_repo_slug, bb_server_url, bb_user, bb_password, bb_token, "MERGED")
gh_closed_prs = client.pull_requests("#{gh_org}/#{gh_repo}", state: 'closed') rescue []
metrics << ["Closed PRs", safe(bb_closed_pr_count), safe(gh_closed_prs.count), safe(bb_closed_pr_count == gh_closed_prs.count ? "Validation Success" : "Validation Failed")]

bb_branches_count = bitbucket_all_branches_count(bb_project_key, bb_repo_slug, bb_server_url, bb_user, bb_password, bb_token)
gh_branches = client.branches("#{gh_org}/#{gh_repo}") rescue []
metrics << ["Total Branches", safe(bb_branches_count), safe(gh_branches.count), safe(bb_branches_count == gh_branches.count ? "Validation Success" : "Validation Failed")]

bb_tags_count = bitbucket_all_tags_count(bb_project_key, bb_repo_slug, bb_server_url, bb_user, bb_password, bb_token)
gh_tags = client.tags("#{gh_org}/#{gh_repo}") rescue []
metrics << ["Total Tags", safe(bb_tags_count), safe(gh_tags.count), safe(bb_tags_count == gh_tags.count ? "Validation Success" : "Validation Failed")]

teams_repo_url = "https://github.com/icesdlc/ghec.intcx.teams.git"
teams_json_path = "teams/teams.json"
work_dir = "tmp_teamsrepo_#{Time.now.to_i}"

clone_repo_if_missing(work_dir, teams_repo_url, type: :github, token: gh_token)
teams_json_file = File.join(work_dir, teams_json_path)
team_proj = nil
if File.exist?(teams_json_file)
  team_proj = read_teams_json(teams_json_file, bb_project_key)
else
  puts "teams.json does not exist in cloned repo or clone failed"
end

roles_hash = team_proj && team_proj['Roles'] ? team_proj['Roles'] : {}
expected_teams = extract_expected_teams_roles(roles_hash)
expected_codeowners = team_proj && team_proj["CodeOwners"] ? team_proj["CodeOwners"].map { |n| "@#{n}" } : []
expected_webhook = team_proj && team_proj["Webhook"] ? team_proj["Webhook"] : "-"

github_teams = fetch_github_direct_access_teams(gh_org, gh_repo, gh_token)
actual_webhooks = []
begin
  repo_hooks = client.hooks("#{gh_org}/#{gh_repo}")
  actual_webhooks = repo_hooks.map { |h| safe(h[:config][:url]) }
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
webhook_status = actual_webhooks.include?(safe(expected_webhook)) ? "Validation Success" : "Validation Failed"
github_custom_properties = fetch_github_custom_properties_values(gh_org, gh_repo)

report_md = []
report_md << "\n**Repository Validation Metrics:**\n"
report_md << "| Metric | Bitbucket Server | GitHub Cloud | Validation Status |"
report_md << "|--------|------------------|--------------|-------------------|"
metrics.each do |row|
  report_md << "| #{safe(row[0])} | #{safe(row[1])} | #{safe(row[2])} | #{safe(row[3])} |"
end

report_md << markdown_codeowners_table(codeowners_validation) if codeowners_validation

report_md << "\n**Webhook Validation:**\n"
report_md << "| Expected | Actual | Validation Status |"
report_md << "|----------|--------|------------------|"
report_md << "| #{safe(expected_webhook)} | #{safe(actual_webhooks.join(', '))} | #{safe(webhook_status)} |"

report_md << "\n**Teams Validation:**\n"
report_md << "| SI No | Team Name | Permission | Validation Status |"
report_md << "|-------|-----------|------------|------------------|"
teams_validation.each do |row|
  report_md << "| #{safe(row[:si_no])} | #{safe(row[:name])} | #{safe(row[:permission])} | #{safe(row[:status])} |"
end

report_md << "\n**GitHub Custom Properties Validation:**\n"
report_md << "| SINO | Property-Name | Property-Value |"
report_md << "|------|---------------|---------------|"
github_custom_properties.each_with_index do |prop, idx|
  report_md << "| #{safe(idx+1)} | #{safe(prop[:property_name])} | #{safe(prop[:value])} |"
end

report_md << lfs_validation_table('bb-repo', 'gh-repo')

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
