# Bitbucket Repository Info Script

This Ruby script fetches information about Bitbucket repositories (such as branches, tags, pull requests, and repository URL) from a list provided in a CSV file, and outputs the results to another CSV file.

## Prerequisites

- Ruby (v2.5+ recommended)
- The following Ruby gems:
  - `dotenv`
- Access to your Bitbucket Server/Data Center instance and credentials (username/password or token)

## Setup

1. **Install dependencies**  
   Run in your terminal:
   ```sh
   gem install dotenv
   ```

2. **Prepare the `.env` file**  
   In the same directory as the script, create a `.env` file with your Bitbucket credentials:
   ```
   BITBUCKET_USER=your_username
   BITBUCKET_PASS=your_password_or_token
   ```

3. **Prepare the `repos.csv` file**  
   Create a CSV file named `repos.csv` with the following header and each Bitbucket repo URL on a separate line:
   ```
   url
   http://bitbucket.local:7990/projects/PROJ/repos/my-repo/browse
   http://bitbucket.local:7990/projects/PROJ2/repos/another-repo/browse
   ```

## Usage

Run the script with:
```sh
ruby bitbucket_repo_info.rb
```

- The script will read repo URLs from `repos.csv`.
- It will generate (or append to) `output.csv` with details for each repository.

## Output

The `output.csv` file will contain columns like:

- Project
- Repo
- Repo_URL
- Branches
- Tags
- Open_PRs
- Closed_PRs

---

**Tip:**  
If you encounter issues with authentication or API access, check your Bitbucket permissions and network connectivity.
