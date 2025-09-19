require 'json'
require 'net/http'
require 'uri'
require 'base64'
require 'time'

def bitbucket_api_request(path)
  base = ENV.fetch('BITBUCKET_BASEURL')
  user = ENV.fetch('BITBUCKET_USER')
  pass = ENV.fetch('BITBUCKET_PASS')
  uri = URI("#{base}/rest/api/1.0#{path}")
  req = Net::HTTP::Get.new(uri)
  req.basic_auth(user, pass)
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
  [res.code.to_i, res.body]
end

def bitbucket_branches(project, repo)
  branches = []
  start = 0
  loop do
    code, body = bitbucket_api_request("/projects/#{project}/repos/#{repo}/branches?limit=100&start=#{start}")
    raise "Bitbucket branches HTTP #{code}" unless code == 200
    data = JSON.parse(body)
    branches += data['values']
    break if data['isLastPage']
    start = data['nextPageStart']
  end
  branches
end

def bitbucket_tags(project, repo)
  tags = []
  start = 0
  loop do
    code, body = bitbucket_api_request("/projects/#{project}/repos/#{repo}/tags?limit=100&start=#{start}")
    raise "Bitbucket tags HTTP #{code}" unless code == 200
    data = JSON.parse(body)
    tags += data['values']
    break if data['isLastPage']
    start = data['nextPageStart']
  end
  tags
end

def bitbucket_default_branch(project, repo)
  branches = bitbucket_branches(project, repo)
  default = branches.find { |b| b['isDefault'] }
  default ? default['displayId'] : (branches[0] && branches[0]['displayId']) || 'master'
end

def bitbucket_commit_count(project, repo, branch)
  count = 0
  start = 0
  loop do
    code, body = bitbucket_api_request("/projects/#{project}/repos/#{repo}/commits?until=#{branch}&limit=100&start=#{start}")
    raise "Bitbucket commits HTTP #{code}" unless code == 200
    data = JSON.parse(body)
    count += data['values'].size
    break if data['isLastPage']
    start = data['nextPageStart']
  end
  count
end

def bitbucket_prs(project, repo, state)
  prs = []
  start = 0
  loop do
    code, body = bitbucket_api_request("/projects/#{project}/repos/#{repo}/pull-requests?state=#{state}&limit=100&start=#{start}")
    raise "Bitbucket PRs HTTP #{code}" unless code == 200
    data = JSON.parse(body)
    prs += data['values']
    break if data['isLastPage']
    start = data['nextPageStart']
  end
  prs
end

def bitbucket_last_commit(project, repo, branch)
  code, body = bitbucket_api_request("/projects/#{project}/repos/#{repo}/commits?limit=1&until=#{branch}")
  raise "Bitbucket commit HTTP #{code}" unless code == 200
  data = JSON.parse(body)
  c = data['values'][0]
  {
    date: c && c['authorTimestamp'],
    author: c && c['author'] && (c['author']['name'] || c['author']['displayName']),
    sha: c && c['id']
  }
end

def github_api_get_raw(url)
  req = Net::HTTP::Get.new(URI(url))
  req['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}"
  req['Accept'] = 'application/vnd.github+json'
  req['X-GitHub-Api-Version'] = '2022-11-28'
  res = Net::HTTP.start(req.uri.hostname, req.uri.port, use_ssl: true) { |http| http.request(req) }
  res
end

def github_api_get(url, max_retries = 5)
  retries = 0
  begin
    res = github_api_get_raw(url)
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
  found = []
  urls.each do |url|
    begin
      _code, data = github_api_get(url)
      if data && data["content"]
        content = Base64.decode64(data["content"])
        owners = content.lines.map do |line|
          next if line.strip.start_with?('#') || line.strip.empty?
          line.split(/\s+/)[1..-1]
        end.compact.flatten.uniq
        found.concat(owners)
      end
    rescue
      next
    end
  end
  found.uniq
end

def fetch_github_webhooks(org, repo)
  hooks = []
  page = 1
  per_page = 100
  loop do
    url = "https://api.github.com/repos/#{org}/#{repo}/hooks?per_page=#{per_page}&page=#{page}"
    _code, data = github_api_get(url)
    break if data.empty?
    hooks += data.map { |h| h['config'] && h['config']['url'] ? h['config']['url'] : (h['name'] || h['url'] || h['id'].to_s) }
    break if data.size < per_page
    page += 1
  end
  hooks.uniq
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

def clone_teams_repo_if_missing
  repo_dir = File.join(File.dirname(__FILE__), "ghec.intcx.teams")
  teams_json_path = File.join(repo_dir, "teams", "teams.json")
  unless File.exist?(teams_json_path)
    puts "Cloning icesdlc/ghec.intcx.teams repo..."
    if Dir.exist?(repo_dir)
      require 'fileutils'
      FileUtils.rm_rf(repo_dir)
    end
    git_url = "https://github.com/icesdlc/ghec.intcx.teams.git"
    system("git clone --depth 1 #{git_url} #{repo_dir}")
    unless File.exist?(teams_json_path)
      puts "Error: Unable to clone repo or teams.json missing!"
      exit 1
    end
  end
  teams_json_path
end

def clone_repo_repo_if_missing
  repo_dir = File.join(File.dirname(__FILE__), "ghec.intcx.repo")
  unless Dir.exist?(repo_dir)
    puts "Cloning icesdlc/ghec.intcx.repo repo..."
    git_url = "https://github.com/icesdlc/ghec.intcx.repo.git"
    system("git clone --depth 1 #{git_url} #{repo_dir}")
    unless Dir.exist?(repo_dir)
      puts "Error: Unable to clone icesdlc/ghec.intcx.repo!"
      exit 1
    end
  end
  repo_dir
end

def read_teams_json(teams_json_path, project_key)
  data = JSON.parse(File.read(teams_json_path))
  arr = data["teams"] if data.is_a?(Hash) && data["teams"].is_a?(Array)
  arr ||= data if data.is_a?(Array)
  unless arr
    puts "ERROR: Could not find teams array in JSON"
    exit 1
  end
  arr.find do |proj|
    k = (proj['Projectkey'] || proj['ProjectKey'] || proj['projectKey'] || proj['projectkey'])
    k && k.strip.casecmp(project_key.strip).zero?
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

def print_heading(text)
  puts "\n#{text}\n" + "-" * text.length
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

def print_codeowners_table(codeowners_result)
  headers = ["Expected", "Actual", "Missing", "Validation Status"]
  rows = []
  if codeowners_result
    rows << [
      codeowners_result[:expected].join(', '),
      codeowners_result[:actual].join(', '),
      codeowners_result[:missing].join(', '),
      codeowners_result[:status]
    ]
  end
  col_widths = rows.transpose.each_with_index.map { |col, i| [headers[i].length, *col.map { |c| c.to_s.length }].max }
  sep = "+-" + col_widths.map { |w| "-" * w }.join("-+-") + "-+"
  puts "\nCodeOwners Validation:\n#{sep}"
  puts "| " + headers.each_with_index.map { |h, i| h.ljust(col_widths[i]) }.join(" | ") + " |"
  puts sep
  rows.each do |row|
    puts "| " + row.each_with_index.map { |cell, i| cell.to_s.ljust(col_widths[i]) }.join(" | ") + " |"
  end
  puts sep
end

def print_webhook_table(webhook_result)
  headers = ["Expected", "Actual", "Validation Status"]
  rows = []
  if webhook_result
    rows << [
      webhook_result[:expected],
      webhook_result[:actual].join(', '),
      webhook_result[:status]
    ]
  end
  col_widths = rows.transpose.each_with_index.map { |col, i| [headers[i].length, *col.map { |c| c.to_s.length }].max }
  sep = "+-" + col_widths.map { |w| "-" * w }.join("-+-") + "-+"
  puts "\nWebhook Validation:\n#{sep}"
  puts "| " + headers.each_with_index.map { |h, i| h.ljust(col_widths[i]) }.join(" | ") + " |"
  puts sep
  rows.each do |row|
    puts "| " + row.each_with_index.map { |cell, i| cell.to_s.ljust(col_widths[i]) }.join(" | ") + " |"
  end
  puts sep
end

def print_teams_table(team_results)
  headers = ["SI No", "Team Name", "Permission", "Validation Status"]
  col_widths = [
    6,
    [25, *team_results.map { |t| t[:name].to_s.length }].max,
    [12, *team_results.map { |t| t[:permission].to_s.length }].max,
    18
  ]
  sep = "+-" + col_widths.map { |w| "-"*w }.join("-+-") + "-+"
  puts "\n#{sep}"
  puts "| " + headers.each_with_index.map { |h, i| h.ljust(col_widths[i]) }.join(" | ") + " |"
  puts sep
  team_results.each_with_index do |row, idx|
    puts "| #{row[:si_no].to_s.ljust(col_widths[0])} | #{row[:name].ljust(col_widths[1])} | #{row[:permission].ljust(col_widths[2])} | #{row[:status].ljust(col_widths[3])} |"
  end
  puts sep
end

# --- UPDATED: Custom Properties Table prints WITHOUT validation status ---
def print_github_custom_properties_table(props, repo_entry = nil)
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
      pname = prop[:property_name].to_s
      pval = prop[:value].to_s
      puts "| #{(idx+1).to_s.ljust(col_widths[0])} | #{pname.ljust(col_widths[1])} | #{pval.ljust(col_widths[2])} |"
    end
  end
  puts sep
end
# --- END UPDATED ---

def print_bsn_icebid_validation_table(validation_results)
  headers = ["Property", "Repo File Value", "GitHub Value", "Validation Status"]
  col_widths = headers.map(&:length)
  validation_results.each do |result|
    col_widths[0] = [col_widths[0], result[:property].to_s.length].max
    col_widths[1] = [col_widths[1], result[:repo_value].to_s.length].max
    col_widths[2] = [col_widths[2], result[:gh_value].to_s.length].max
    col_widths[3] = [col_widths[3], result[:status].to_s.length].max
  end
  sep = "+-" + col_widths.map { |w| "-"*w }.join("-+-") + "-+"
  puts "\nBSN/ICEBID Validation:\n#{sep}"
  puts "| " + headers.each_with_index.map { |h, i| h.ljust(col_widths[i]) }.join(" | ") + " |"
  puts sep
  validation_results.each do |row|
    puts "| #{row[:property].ljust(col_widths[0])} | #{row[:repo_value].to_s.ljust(col_widths[1])} | #{row[:gh_value].to_s.ljust(col_widths[2])} | #{row[:status].ljust(col_widths[3])} |"
  end
  puts sep
end

def validate_teams_against_roles(github_teams, roles_hash)
  expected_team_names = []
  roles_hash.each do |role, arr|
    arr.each { |r| expected_team_names << r['name'] }
  end
  results = []
  expected_team_names.each_with_index do |team_name, idx|
    gt = github_teams.find { |t| t[:name] == team_name }
    status = gt ? "Validation Success" : "Validation Failed"
    perm = gt ? gt[:permission] : "-"
    results << { si_no: idx+1, name: team_name, permission: perm, status: status }
  end
  results
end

def load_repo_json_and_validate_bsn_icebid(repo_dir, bitbucket_project_key, gh_repo, github_custom_props)
  repo_json_path = File.join(repo_dir, "repos", "#{bitbucket_project_key}_repos.json")
  unless File.exist?(repo_json_path)
    puts "Repo JSON file not found at #{repo_json_path}"
    return [], nil
  end
  repo_json = JSON.parse(File.read(repo_json_path))
  repo_entry = nil
  if repo_json.is_a?(Array)
    repo_entry = repo_json.find do |r|
      nameval = (r["Name"] || r["name"])
      nameval && nameval.strip.casecmp(gh_repo.strip).zero?
    end
  end
  return [], nil unless repo_entry
  bsn = repo_entry["BSN"] || repo_entry["bsn"]
  icebid = repo_entry["ICEBID"] || repo_entry["icebid"]
  gh_bsn = github_custom_props.find { |p| p[:property_name].to_s.downcase == "bsn" }&.dig(:value)
  gh_icebid = github_custom_props.find { |p| p[:property_name].to_s.downcase == "icebid" }&.dig(:value)

  validation_results = [
    {
      property: "BSN",
      repo_value: bsn,
      gh_value: gh_bsn,
      status: (bsn.to_s == gh_bsn.to_s ? "Validation Success" : "Validation Failed")
    },
    {
      property: "ICEBID",
      repo_value: icebid,
      gh_value: gh_icebid,
      status: (icebid.to_s == gh_icebid.to_s ? "Validation Success" : "Validation Failed")
    }
  ]
  return validation_results, repo_entry
end

if __FILE__ == $0
  if ARGV.length != 2
    puts "Usage: ruby compare_repo_stats.rb BITBUCKET_REPO_URL GITHUB_REPO_URL"
    puts "Requires BITBUCKET_BASEURL, BITBUCKET_USER, BITBUCKET_PASS, GITHUB_TOKEN env vars."
    exit 1
  end

  bitbucket_url, github_url = ARGV
  teams_json_path = clone_teams_repo_if_missing
  repo_dir = clone_repo_repo_if_missing

  unless bitbucket_url =~ %r{/projects/([^/]+)/repos/([^/]+)/browse}
    puts "Invalid Bitbucket URL format"
    exit 1
  end
  project = $1
  repo = $2

  unless github_url =~ %r{github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?(?:[/?#].*)?$}
    puts "Invalid GitHub URL format"
    exit 1
  end
  gh_org = $1
  gh_repo = $2

  puts "\nFetching data from Bitbucket Server and GitHub Cloud. Please wait..."

  begin
    bb_branches = bitbucket_branches(project, repo)
    gh_branches = fetch_github_items("branches", gh_org, gh_repo)
    bb_tags = bitbucket_tags(project, repo)
    gh_tags = fetch_github_items("tags", gh_org, gh_repo)
    bb_default_branch = bitbucket_default_branch(project, repo)
    gh_branch = gh_branches.map { |b| b['name'] }.include?(bb_default_branch) ? bb_default_branch : (gh_branches.map { |b| b['name'] }.include?('main') ? 'main' : gh_branches[0]['name'])
    bb_commit_count = bitbucket_commit_count(project, repo, bb_default_branch)
    gh_commit_count = fetch_github_commits_count(gh_org, gh_repo, gh_branch)
    bb_open_prs = bitbucket_prs(project, repo, 'OPEN').size
    gh_open_prs = fetch_github_prs(gh_org, gh_repo, 'open')
    bb_closed_prs = bitbucket_prs(project, repo, 'MERGED').size
    gh_closed_prs = fetch_github_prs(gh_org, gh_repo, 'closed')
    bb_last_commit = bitbucket_last_commit(project, repo, bb_default_branch)
    gh_last_commit = fetch_github_last_commit(gh_org, gh_repo, gh_branch)
    bb_last_date = bb_last_commit[:date] ? Time.at(bb_last_commit[:date] / 1000).strftime("%d %B %Y") : ""
    gh_last_date = Time.at(gh_last_commit[:date] / 1000).strftime("%d %B %Y")
    bb_last_author = bb_last_commit[:author] || ""
    gh_last_author = gh_last_commit[:author]
    bb_last_sha = bb_last_commit[:sha] || ""
    gh_last_sha = gh_last_commit[:sha]

    team_proj = read_teams_json(teams_json_path, project)
    if !team_proj
      puts "Project key #{project} not found in teams.json!"
      exit 1
    end

    github_teams = fetch_github_direct_access_teams(gh_org, gh_repo)
    teams_validation = []
    if team_proj['Roles']
      teams_validation = validate_teams_against_roles(github_teams, team_proj['Roles'])
    end

    codeowners_validation = nil
    if team_proj['CodeOwners']
      github_codeowners = fetch_github_codeowners(gh_org, gh_repo, gh_branch)
      expected_codeowners = team_proj['CodeOwners'] || []
      missing = expected_codeowners.reject { |name| github_codeowners.any? { |real| real.include?(name) } }
      status = missing.empty? ? "Validation Success" : "Validation Failed"
      codeowners_validation = {
        expected: expected_codeowners,
        actual: github_codeowners,
        missing: missing,
        status: status
      }
    end

    webhook_validation = nil
    if team_proj['Webhook']
      github_webhooks = fetch_github_webhooks(gh_org, gh_repo)
      expected_webhook = team_proj['Webhook']
      status = github_webhooks.include?(expected_webhook) ? "Validation Success" : "Validation Failed"
      webhook_validation = {
        expected: expected_webhook,
        actual: github_webhooks,
        status: status
      }
    end

    github_custom_props = fetch_github_custom_properties_values(gh_org, gh_repo)
    bsn_icebid_validation, repo_entry = load_repo_json_and_validate_bsn_icebid(repo_dir, project, gh_repo, github_custom_props)
  rescue => e
    puts "Error occurred: #{e.message}"
    exit 1
  end

  print_heading("Repository Validation")
  results = [
    { metric: "Total Branch", bb: bb_branches.size, gh: gh_branches.size, status: bb_branches.size == gh_branches.size ? "Validation Success" : "Validation Failed" },
    { metric: "Total Tags", bb: bb_tags.size, gh: gh_tags.size, status: bb_tags.size == gh_tags.size ? "Validation Success" : "Validation Failed" },
    { metric: "Total commit in default branch", bb: bb_commit_count, gh: gh_commit_count, status: bb_commit_count == gh_commit_count ? "Validation Success" : "Validation Failed" },
    { metric: "Total Open PR", bb: bb_open_prs, gh: gh_open_prs, status: bb_open_prs == gh_open_prs ? "Validation Success" : "Validation Failed" },
    { metric: "Total Closed PR", bb: bb_closed_prs, gh: gh_closed_prs, status: bb_closed_prs == gh_closed_prs ? "Validation Success" : "Validation Failed" },
    { metric: "Last Commited Date", bb: bb_last_date, gh: gh_last_date, status: bb_last_date == gh_last_date ? "Validation Success" : "Validation Failed" },
    { metric: "Last commited Author", bb: bb_last_author, gh: gh_last_author, status: bb_last_author == gh_last_author ? "Validation Success" : "Validation Failed" },
    { metric: "Last Commit SHA", bb: bb_last_sha, gh: gh_last_sha, status: bb_last_sha == gh_last_sha ? "Validation Success" : "Validation Failed" }
  ]
  print_table(results)
  print_codeowners_table(codeowners_validation)
  print_webhook_table(webhook_validation)
  print_heading("Teams Validation")
  print_teams_table(teams_validation) if teams_validation.any?
  print_heading("Custom Properties Validation")
  print_github_custom_properties_table(github_custom_props, repo_entry)
  print_bsn_icebid_validation_table(bsn_icebid_validation) if bsn_icebid_validation && !bsn_icebid_validation.empty?
end
