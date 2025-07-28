# Bitbucket vs GitHub Branch/Tag Comparison Script

This Ruby script helps you compare the **branches and tags** of a repository migrated from **Bitbucket Server/Data Center** to **GitHub**.

It prints the total number of branches/tags on both platforms and lists the ones **missing in GitHub**.

---

## ✅ Features

- Fetches **branches and tags** from both Bitbucket and GitHub
- Handles **pagination**
- Prints a **summary table**
- Shows **missing branches and tags** in GitHub
- Easy CLI usage

---

## 📦 Prerequisites

1. Ruby 3.x installed
2. Required Ruby gem:
   ```bash
   gem install dotenv
3. Environment variables setup via `.env` file or shell export.

## 🔐 Setup .env File
Create a file named .env in the same directory and add the following:

```
BITBUCKET_USERNAME=your_bitbucket_username
BITBUCKET_TOKEN=your_bitbucket_token_or_app_password
GITHUB_TOKEN=your_github_personal_access_token
```

Or you can export them directly in your terminal:

```
export BITBUCKET_USERNAME=your_bitbucket_username
export BITBUCKET_TOKEN=your_bitbucket_token
export GITHUB_TOKEN=your_github_token
```

## ▶️ Usage

```
ruby compare_repos.rb <BITBUCKET_REPO_URL> <GITHUB_REPO_URL>
```

**Example**

```
ruby compare_repos.rb https://bitbucket.company.com/scm/dev/myrepo.git https://github.com/myorg/myrepo
```

## 🧾 Output Format
The script prints comparison tables like:
```
=== Branches Comparison ===
+---------------------+----------------+----------------+
| Metric              | Bitbucket      | GitHub         |
+---------------------+----------------+----------------+
| Total Count         | 12             | 10             |
| Missing in GitHub   | 2              | -              |
+---------------------+----------------+----------------+

Missing branches in GitHub:
+--------------------------+
| Name                     |
+--------------------------+
| feature/api-v1           |
| release-2022             |
+--------------------------+
```
