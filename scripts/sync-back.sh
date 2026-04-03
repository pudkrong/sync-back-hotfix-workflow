#!/usr/bin/env bash
set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
# ./sync-back.sh \
#   --source-branch <branch> \
#   --source-base <branch> \
#   --pr-number <number> \
#   --pr-title <title> \
#   --pr-url <url> \
#   --repo <owner/repo> \
#   --ntfy-url <https://ntfy.sh/topic>

# ── Argument parsing ─────────────────────────────────────────────────────────
SOURCE_BRANCH=""
SOURCE_BASE=""
PR_NUMBER=""
PR_TITLE=""
PR_URL=""
REPO=""
NTFY_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-branch) SOURCE_BRANCH="$2"; shift 2 ;;
    --source-base)   SOURCE_BASE="$2";   shift 2 ;;
    --pr-number)     PR_NUMBER="$2";     shift 2 ;;
    --pr-title)      PR_TITLE="$2";      shift 2 ;;
    --pr-url)        PR_URL="$2";        shift 2 ;;
    --repo)          REPO="$2";          shift 2 ;;
    --ntfy-url)      NTFY_URL="$2";      shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
require_var() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    echo "Missing required argument: $name" >&2
    exit 1
  fi
}

sanitize_branch_fragment() {
  printf '%s' "$1" | tr '/[:space:]' '-' | tr -cd '[:alnum:]._-' | tr -s '-'
}

ensure_label() {
  local name="$1" color="$2" description="$3"
  if gh api "repos/$REPO/labels/$name" >/dev/null 2>&1; then
    return 0
  fi
  gh api "repos/$REPO/labels" \
    --method POST \
    -f name="$name" \
    -f color="$color" \
    -f description="$description" >/dev/null
}

send_ntfy() {
  local title="$1" body="$2" priority="$3" tags="$4" actions="${5:-}"

  if [[ -z "$NTFY_URL" ]]; then
    return 0
  fi

  local server="${NTFY_URL%/*}"
  local topic="${NTFY_URL##*/}"

  local curl_args=(
    -s
    -H "Title: $title"
    -H "Priority: $priority"
    -H "Tags: $tags"
    -d "$body"
  )

  if [[ -n "$actions" ]]; then
    curl_args+=(-H "Actions: $actions")
  fi

  curl "${curl_args[@]}" "$server/$topic" >/dev/null 2>&1 || true
}

# ── Validation ────────────────────────────────────────────────────────────────
require_var "--source-branch" "$SOURCE_BRANCH"
require_var "--source-base"   "$SOURCE_BASE"
require_var "--pr-number"     "$PR_NUMBER"
require_var "--pr-title"      "$PR_TITLE"
require_var "--pr-url"        "$PR_URL"
require_var "--repo"          "$REPO"

# ── Routing ───────────────────────────────────────────────────────────────────
case "$SOURCE_BASE" in
  staging)
    TARGET_BRANCH="main"
    TARGET_LABEL="sync-to-main"
    ;;
  production)
    TARGET_BRANCH="staging"
    TARGET_LABEL="sync-to-staging"
    ;;
  *)
    echo "Merged PR does not target staging or production. No sync-back is required."
    send_ntfy \
      "[sync-back] Skipped" \
      "PR #$PR_NUMBER merged into $SOURCE_BASE — no sync-back route defined." \
      "default" \
      "information"
    exit 0
    ;;
esac

OWNER="${REPO%%/*}"
SANITIZED_SOURCE_BRANCH="$(sanitize_branch_fragment "$SOURCE_BRANCH")"
SYNC_BRANCH="sync-back/${SOURCE_BASE}-to-${TARGET_BRANCH}/pr-${PR_NUMBER}-${SANITIZED_SOURCE_BRANCH}"

COMMITS_FILE="$(mktemp)"
BODY_FILE="$(mktemp)"
trap 'rm -f "$COMMITS_FILE" "$BODY_FILE"' EXIT

# ── Fetch PR commits ─────────────────────────────────────────────────────────
echo "Loading commits for PR #$PR_NUMBER"
gh api "repos/$REPO/pulls/$PR_NUMBER/commits" --paginate --jq '.[].sha' > "$COMMITS_FILE"

if [[ ! -s "$COMMITS_FILE" ]]; then
  echo "No commits were returned for PR #$PR_NUMBER." >&2
  send_ntfy \
    "[sync-back] FAILED — PR #$PR_NUMBER" \
    "No commits found for PR #$PR_NUMBER merged into $SOURCE_BASE." \
    "high" \
    "rotating_light"
  exit 1
fi

# ── Idempotency check ────────────────────────────────────────────────────────
existing_open_pr_url="$(gh pr list \
  --repo "$REPO" \
  --state open \
  --base "$TARGET_BRANCH" \
  --head "$OWNER:$SYNC_BRANCH" \
  --json url \
  --jq '.[0].url // ""')"

if [[ -n "$existing_open_pr_url" ]]; then
  echo "An open sync-back PR already exists: $existing_open_pr_url"
  send_ntfy \
    "[sync-back] Already exists" \
    "PR already exists: $existing_open_pr_url" \
    "default" \
    "information" \
    "view, View Sync PR, $existing_open_pr_url"
  exit 0
fi

# ── Ensure labels exist ──────────────────────────────────────────────────────
ensure_label "sync-back"     "1d76db" "Automated branch synchronization pull request"
ensure_label "$TARGET_LABEL" "0e8a16" "Automated sync-back PR targeting $TARGET_BRANCH"

# ── Git setup ────────────────────────────────────────────────────────────────
git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git fetch --no-tags origin \
  "+refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH" \
  "+refs/pull/$PR_NUMBER/head:refs/remotes/origin/pull/$PR_NUMBER/head"

git checkout -B "$SYNC_BRANCH" "origin/$TARGET_BRANCH"

# ── Cherry-pick loop ─────────────────────────────────────────────────────────
applied_commits=0
skipped_commits=0
conflicted_commits=()

while IFS= read -r commit_sha; do
  [[ -z "$commit_sha" ]] && continue

  if ! git cat-file -e "$commit_sha^{commit}" 2>/dev/null; then
    echo "Commit $commit_sha is not available locally after fetching the PR ref." >&2
    send_ntfy \
      "[sync-back] FAILED — PR #$PR_NUMBER" \
      "Commit $commit_sha not found." \
      "high" \
      "rotating_light"
    exit 1
  fi

  parent_count="$(git rev-list --parents -n 1 "$commit_sha" | awk '{ print NF - 1 }')"
  if [[ "$parent_count" -gt 1 ]]; then
    echo "Commit $commit_sha is a merge commit and cannot be cherry-picked automatically." >&2
    send_ntfy \
      "[sync-back] FAILED — PR #$PR_NUMBER" \
      "Merge commit $commit_sha cannot be cherry-picked." \
      "high" \
      "rotating_light"
    exit 1
  fi

  if git cherry-pick -x "$commit_sha"; then
    applied_commits=$((applied_commits + 1))
    continue
  fi

  if [[ -z "$(git status --porcelain)" ]]; then
    echo "Commit $commit_sha is already present on $TARGET_BRANCH. Skipping."
    git cherry-pick --skip || true
    skipped_commits=$((skipped_commits + 1))
    continue
  fi

  if git diff --name-only --diff-filter=U | grep -q '.'; then
    echo "Cherry-pick conflict on $commit_sha. Staging conflict markers and continuing..."
    git add -A
    GIT_EDITOR=true git cherry-pick --continue
    conflicted_commits+=("$commit_sha")
    applied_commits=$((applied_commits + 1))
    continue
  fi

  git cherry-pick --abort || true
  echo "Cherry-pick failed for $commit_sha for an unexpected reason." >&2
  send_ntfy \
    "[sync-back] FAILED — PR #$PR_NUMBER" \
    "Unexpected cherry-pick failure on $commit_sha." \
    "high" \
    "rotating_light"
  exit 1
done < "$COMMITS_FILE"

# ── Skip if nothing to sync ──────────────────────────────────────────────────
if [[ "$applied_commits" -eq 0 ]]; then
  echo "All PR commits are already present on $TARGET_BRANCH. No sync PR is required."
  send_ntfy \
    "[sync-back] Nothing to sync" \
      "All commits from PR #$PR_NUMBER already exist on $TARGET_BRANCH." \
      "default" \
      "information"
  exit 0
fi

# ── Push branch ──────────────────────────────────────────────────────────────
git push origin "$SYNC_BRANCH" --force

# ── Build labels ─────────────────────────────────────────────────────────────
LABELS="sync-back,$TARGET_LABEL"
if [[ "${#conflicted_commits[@]}" -gt 0 ]]; then
  ensure_label "needs-manual-resolution" "e4e669" "PR contains conflict markers that require manual resolution"
  LABELS="$LABELS,needs-manual-resolution"
fi

# ── PR title ─────────────────────────────────────────────────────────────────
SYNC_PR_TITLE="[sync-back][$SOURCE_BASE->$TARGET_BRANCH] $PR_TITLE (#$PR_NUMBER)"

# ── PR body ──────────────────────────────────────────────────────────────────
{
  if [[ "${#conflicted_commits[@]}" -gt 0 ]]; then
    echo "> [!WARNING]"
    echo "> This PR contains **${#conflicted_commits[@]} commit(s) with conflict markers** that require manual resolution before merging."
    echo
  fi

  echo "## Automated Sync-Back"
  echo
  echo "This PR was generated automatically after #$PR_NUMBER was merged into \`$SOURCE_BASE\`."
  echo
  echo "- Original PR: $PR_URL"
  echo "- Original source branch: \`$SOURCE_BRANCH\`"
  echo "- Sync route: \`$SOURCE_BASE\` -> \`$TARGET_BRANCH\`"
  echo "- Cherry-picked commits applied here: $applied_commits"
  echo "- Commits already present on target: $skipped_commits"
  echo
  echo "### Cherry-Picked Commits"
  while IFS= read -r commit_sha; do
    [[ -n "$commit_sha" ]] && echo "- \`$commit_sha\`"
  done < "$COMMITS_FILE"

  if [[ "${#conflicted_commits[@]}" -gt 0 ]]; then
    echo
    echo "### Commits Requiring Manual Resolution"
    echo
    echo "The following commits were applied with conflict markers. Resolve them before merging:"
    echo
    for sha in "${conflicted_commits[@]}"; do
      echo "- \`$sha\`"
    done
  fi
} > "$BODY_FILE"

# ── Create PR ────────────────────────────────────────────────────────────────
CREATED_PR_URL="$(gh pr create \
  --repo "$REPO" \
  --head "$SYNC_BRANCH" \
  --base "$TARGET_BRANCH" \
  --title "$SYNC_PR_TITLE" \
  --body-file "$BODY_FILE" \
  --label "$LABELS")"

echo "Sync-back PR created: $CREATED_PR_URL"

# ── Notify via ntfy ──────────────────────────────────────────────────────────
BRANCH_URL="${GITHUB_SERVER_URL:-https://github.com}/$REPO/tree/$SYNC_BRANCH"

send_ntfy \
  "[sync-back] PR created" \
  "$SYNC_PR_TITLE"$'\n'"Route: $SOURCE_BASE -> $TARGET_BRANCH"$'\n'"$BRANCH_URL" \
  "default" \
  "white_check_mark" \
  "view, View Sync Branch, $CREATED_PR_URL"

echo "Done."
