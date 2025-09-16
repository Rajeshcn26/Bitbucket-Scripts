# Repository Comparison Script

This Ruby script compares key statistics between a Bitbucket Server repository and a GitHub repository. It is especially useful for validating migrations or ensuring repository synchronization between Bitbucket Server (Stash) and GitHub.

## Features

- Compares:
  - Total branches
  - Total tags
  - Total commits in the default branch
  - Total open and closed pull requests
  - Last committed date, author, and commit SHA
  - Existence of CODEOWNERS file
- Presents results in an auto-sized table with validation status for each metric
- Uses Bitbucket Server and GitHub APIs for reliable, live data
- Handles nil and missing data gracefully

> **Note:**  
> The "Total Number files" comparison is currently commented out in the script.  
> If you want to enable file counting, uncomment the relevant code sections.

## Prerequisites

- Ruby (2.5+ recommended)
- [dotenv](https://github.com/bkeepers/dotenv) gem for environment variable handling

## Environment Variables

You need to set the following environment variables for API authentication:

- `BITBUCKET_USERNAME`: Bitbucket Server username
- `BITBUCKET_TOKEN`: Bitbucket Server personal access token or password
- `GITHUB_TOKEN`: GitHub personal access token

You can set these in a `.env` file in the same directory as the script:

```
BITBUCKET_USERNAME=your_bitbucket_username
BITBUCKET_TOKEN=your_bitbucket_token
GITHUB_TOKEN=your_github_token
```

## Usage

```sh
ruby compare_repo_stats.rb <BITBUCKET_REPO_URL> <GITHUB_REPO_URL>
```

**Example:**
```sh
ruby compare_repo_stats.rb https://stash.intcx.net/projects/QAAUT/repos/quantlib/browse https://github.com/intcx/QAAUT-quantlib
```

## Output

- Prints a formatted table comparing all metrics between the repositories.
- The "Validation Status" column shows "Validation Success" if the values match, or "Validation Failed" otherwise.

<img width="1012" height="263" alt="Screenshot 2025-09-16 at 10 51 06 AM" src="https://github.com/user-attachments/assets/22e5e8ed-a1e5-4f2b-8599-7f55cd6df2f5" />


## Customization

- To compare total number of files, uncomment the code sections related to file counting inside the script.
- You can further expand metrics by adding new rows in the `results` array.

## Troubleshooting

- If you encounter API errors, check your credentials and permissions.
- If you see "undefined method `join` for nil", ensure the Bitbucket Server repository and branch exist and you have access.

## License

MIT License

---
```
