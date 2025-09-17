# GitHub Organization CODEOWNERS Audit Script

This Ruby script fetches all repositories created in the last month for a specified GitHub organization, checks if a `CODEOWNERS` file exists in each repository, and outputs the results as CSV (to both console and `output.csv`).

## Features

- **Organization filter:** Only repos in your chosen organization.
- **Date filter:** Only repos created in the last month.
- **CODEOWNERS file check:** Searches for `CODEOWNERS` in root, `.github/`, or `docs/`.
- **Pagination:** Handles up to 1000 repositories (GitHub Search API limit).
- **CSV Output:** Prints to console and writes to `output.csv`.
- **Console Progress:** See progress and summary in real-time.

## Requirements

- Ruby (tested on Ruby 2.6+)
- [GitHub Personal Access Token](https://github.com/settings/tokens) with `repo` or `public_repo` scope

## Usage

1. **Clone or copy this script to your machine.**

2. **Set your GitHub token as an environment variable:**
    ```bash
    export GITHUB_TOKEN=your_token_here
    ```

3. **Edit the script (if needed):**
    - Change the `ORG_NAME` variable at the top to your org, e.g.:
      ```ruby
      ORG_NAME = "your-org-name"
      ```

4. **Run the script:**
    ```bash
    ruby fetch_org_codeowners_report.rb
    ```

5. **Output:**
    - The script will print CSV results to the console.
    - It will also save the same CSV output to `output.csv`.

## Sample Output

```csv
repo_name,repo_url,has_codeowners_file
ps-resources/example-repo,https://github.com/ps-resources/example-repo,yes
ps-resources/another-repo,https://github.com/ps-resources/another-repo,no
```

## Troubleshooting

- If you get zero results, check:
    - The `ORG_NAME` is correct.
    - Your GitHub token has access to the org’s repos.
    - There are repos created within the last month.
- If you see API limit errors, try re-running with a token that has higher rate limits.

## License

MIT License
