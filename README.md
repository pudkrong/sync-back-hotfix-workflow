# Sync-Back Hotfix Workflow

A GitHub Actions workflow that automatically propagates hotfixes backward through your branch hierarchy using cherry-pick and pull request creation.

## Problem

Teams using a forward-promotion branching model (`main` → `staging` → `production`) face a common challenge: when a hotfix is merged directly into `staging` or `production`, those changes need to flow back upstream to keep branches in sync. Doing this manually is error-prone and easily forgotten.

## Solution

This workflow detects when a PR is merged into `staging` or `production`, cherry-picks the commits onto the appropriate upstream branch, and creates a sync-back PR automatically.

```
main ←──────── staging ←──────── production
       staging→main    production→staging
```

| Merged into  | Syncs to  |
| ------------ | --------- |
| `staging`    | `main`    |
| `production` | `staging` |

## Features

- **Automatic routing** — determines sync direction from the merge target
- **Idempotent** — detects existing open sync PRs to avoid duplicates
- **Conflict-aware cherry-picking** — applies commits with `-x` for traceability, auto-skips already-present commits, flags conflicts with a `needs-manual-resolution` label and warning banner
- **Self-healing labels** — creates `sync-back`, `sync-to-*`, and `needs-manual-resolution` labels if they don't exist
- **Rich PR metadata** — generated PR body includes original PR link, commit SHAs, sync route, applied/skipped counts, and conflict status
- **Optional notifications** — push alerts via [ntfy.sh](https://ntfy.sh) for success, failure, and skip events
- **Concurrency-safe** — workflow concurrency groups per PR prevent race conditions

## Quick Start

### 1. Add the workflow

Copy `.github/workflows/create-hotfix-sync-pr.yml` into your repository.

### 2. Add the script

Copy `scripts/sync-back.sh` into your repository and ensure it is executable (`chmod +x scripts/sync-back.sh`).

### 3. Configure (optional)

Add `NTFY_URL` as a repository variable to enable push notifications. The value should be the full ntfy topic URL, for example:

```
https://ntfy.sh/my-sync-topic
```

No other secrets are required — the workflow uses the built-in `github.token`.

## How It Works

1. A PR is merged into `staging` or `production`
2. The workflow triggers on `pull_request.closed` with `merged == true`
3. `sync-back.sh` determines the sync route and checks for existing sync PRs
4. Commits from the original PR are cherry-picked one by one onto a new sync branch
5. A PR is created against the target branch with full metadata and labels
6. An optional ntfy notification is sent

## Repository Structure

```
.
├── .github/workflows/
│   └── create-hotfix-sync-pr.yml   # Workflow definition
├── scripts/
│   └── sync-back.sh                # Core cherry-pick and PR creation logic
└── README.md
```

## Script Reference

### sync-back.sh

Core orchestration script invoked by the workflow.

```
./sync-back.sh \
  --source-branch <branch> \
  --source-base <branch> \
  --pr-number <number> \
  --pr-title <title> \
  --pr-url <url> \
  --repo <owner/repo> \
  --ntfy-url <url>
```

All arguments except `--ntfy-url` are required.

## License

MIT
