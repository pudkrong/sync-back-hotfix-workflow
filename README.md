# 🔄 Hotfix Sync-Back Workflow

> **Automated propagation of hotfixes and critical changes across your Git branch hierarchy**  
> _staging → main_ | _production → staging_

## 📋 Overview

This repository implements a robust GitHub Actions workflow that automatically creates "sync-back" pull requests when hotfixes are merged into protected branches. Designed for teams using a forward-promotion model (`main` → `staging` → `production`), it ensures critical fixes flow backward through your branch hierarchy without manual intervention.

## ✨ Key Features

- **Smart Branch Routing**: Automatically determines sync direction:
  - `staging` merges → sync to `main`
  - `production` merges → sync to `staging`
- **Idempotent Execution**: Detects existing open sync PRs to avoid duplicates
- **Conflict-Aware Cherry-Picking**:
  - Applies commits with `-x` for traceability
  - Auto-skips already-present commits
  - Flags merge conflicts with `needs-manual-resolution` label + warning banner
- **Self-Healing Labels**: Creates required labels (`sync-back`, `sync-to-*`, `needs-manual-resolution`) if missing
- **Rich PR Metadata**: Auto-generated PR body includes original PR link, commit SHAs, sync route, and conflict status
- **Observability**: Optional [ntfy](https://ntfy.sh) notifications for success/failure events
- **Concurrency-Safe**: Uses workflow concurrency groups per PR to prevent race conditions

## 🚀 Workflow Trigger

```yaml
on:
  pull_request:
    types: [closed] # Runs only when PR is merged into staging/production
```

## 🧠 Branch Propagation Logic

```
main (development)
  ↑ [sync-back: staging→main]
staging (pre-production)
  ↑ [sync-back: production→staging]
production (live)
```

When a PR is merged:

1. ✅ Merged into `staging`? → Create PR to sync changes to `main`
2. ✅ Merged into `production`? → Create PR to sync changes to `staging`
3. ❌ Merged elsewhere? → Exit silently (no sync needed)

## 🔧 Technical Requirements

| Component             | Version/Value                                               | Purpose                          |
| --------------------- | ----------------------------------------------------------- | -------------------------------- |
| GitHub Actions Runner | `ubuntu-latest`                                             | Execution environment            |
| GitHub CLI            | `2.89.0` (pinned)                                           | API interactions & PR management |
| Actions Used          | `actions/checkout@v4`, `peter-evans/create-pull-request@v6` | Git ops & PR creation            |
| Secrets Required      | `GH_TOKEN`, `NTFY_TOPIC` (optional)                         | Auth & notifications             |

## 📦 Repository Structure

```
.
├── .github/workflows/
│   └── create-hotfix-sync-pr.yml  # Main workflow definition
└── README.md                      # This file
```

## 🛡️ Safety & Guardrails

- **Merge Commit Protection**: Rejects PRs containing merge commits (cannot cherry-pick safely)
- **Fetch Depth 0**: Ensures full commit history for accurate cherry-picking
- **Atomic Git Reset**: Uses `git reset --mixed` to hand off clean changes to PR creation action
- **Explicit Exit Codes**: Clear success/failure paths for CI/CD integration

## 🔔 Notifications (Optional)

Enable real-time alerts via [ntfy.sh](https://ntfy.sh):

```bash
# Success: "✅ PR created" with link + sync route
# Failure: "🚨 FAILED" with run URL + context
```

Set `NTFY_TOPIC` in repository secrets to activate.

## 🧪 Testing & Validation

Before deploying to production:

1. Test with a feature branch → `staging` PR in a sandbox repo
2. Verify sync PR is created with correct base/head
3. Simulate a conflict to confirm `needs-manual-resolution` labeling
4. Check ntfy notifications (if enabled)

## 📄 License

MIT © [Pisut Sritrakulchai]
