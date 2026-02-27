#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"

usage() {
  cat >&2 <<EOF
usage: review-pr.sh --repo <owner/repo> --pr <number> --task-id <id>

  --repo      github repo in owner/repo format
  --pr        pull request number
  --task-id   task id in the registry
EOF
  exit 1
}

# --- parse args ---

REPO="" PR_NUMBER="" TASK_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     REPO="$2"; shift 2 ;;
    --pr)       PR_NUMBER="$2"; shift 2 ;;
    --task-id)  TASK_ID="$2"; shift 2 ;;
    *)          usage ;;
  esac
done

[[ -z "$REPO" || -z "$PR_NUMBER" || -z "$TASK_ID" ]] && usage

# --- gather PR context ---

echo "reviewing PR #$PR_NUMBER in $REPO for task '$TASK_ID'..."

PR_DIFF="$(gh pr diff "$PR_NUMBER" --repo "$REPO" 2>/dev/null || echo "")"
if [[ -z "$PR_DIFF" ]]; then
  echo "ERROR: could not get PR diff" >&2
  exit 1
fi

PR_BODY="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title,body --jq '"\(.title)\n\n\(.body)"' 2>/dev/null || echo "")"

# --- build review prompt ---

REVIEW_CONTEXT="## pull request #$PR_NUMBER in $REPO

### description
$PR_BODY

### diff
\`\`\`diff
$PR_DIFF
\`\`\`"

REVIEW_PROMPT="you are reviewing a pull request. analyze the diff and provide a concise code review.

focus on:
- correctness: logic errors, edge cases, off-by-one errors
- security: injection, auth issues, secret exposure, OWASP top 10
- missing error handling: unhandled exceptions, missing null checks
- performance: obvious bottlenecks, unnecessary allocations
- style: consistency with the existing codebase

format your review as:

## summary
one paragraph overview of the changes.

## issues
list any problems found, with severity (critical/warning/nit).
if no issues, say 'no issues found'.

## suggestions
optional improvements that aren't blocking.

keep the review concise and actionable. do not repeat the diff back."

# --- run review ---

REVIEW_OUTPUT="$(echo "$REVIEW_CONTEXT" | claude -p "$REVIEW_PROMPT" 2>/dev/null || echo "")"

if [[ -z "$REVIEW_OUTPUT" ]]; then
  echo "ERROR: claude review returned empty output" >&2
  registry_set_field "$TASK_ID" "error" "review produced empty output"
  exit 1
fi

# --- post review as PR comment ---

COMMENT_BODY="## automated code review (claude)

$REVIEW_OUTPUT

---
*reviewed by claude code via agent swarm*"

gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$COMMENT_BODY"

echo "review posted to PR #$PR_NUMBER"

# --- update registry ---

registry_set_field "$TASK_ID" "reviewPosted" "true"
