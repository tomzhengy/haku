#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"

usage() {
  cat >&2 <<EOF
usage: spawn-agent.sh --repo <path> --id <task-id> --prompt <prompt> [--branch <name>]

  --repo     path to the git repository
  --id       unique task identifier (kebab-case)
  --prompt   the task prompt for the agent
  --branch   branch name (default: claude/<task-id>)
EOF
  exit 1
}

# --- parse args ---

REPO="" TASK_ID="" PROMPT="" BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --id)      TASK_ID="$2"; shift 2 ;;
    --prompt)  PROMPT="$2"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    *)         usage ;;
  esac
done

[[ -z "$REPO" || -z "$TASK_ID" || -z "$PROMPT" ]] && usage

BRANCH="${BRANCH:-claude/$TASK_ID}"

# --- validate ---

if [[ ! -d "$REPO/.git" ]] && ! git -C "$REPO" rev-parse --git-dir &>/dev/null; then
  echo "ERROR: $REPO is not a git repository" >&2
  exit 1
fi

# init registry if needed
registry_init

# check if task id already exists
if registry_get_task "$TASK_ID" &>/dev/null; then
  echo "ERROR: task '$TASK_ID' already exists" >&2
  exit 1
fi

# --- check concurrency ---

ACTIVE_COUNT="$(registry_count_active)"

if [[ "$ACTIVE_COUNT" -ge "$MAX_CONCURRENT" ]]; then
  echo "at max concurrent ($MAX_CONCURRENT). queuing task '$TASK_ID'."
  WORKTREE_PATH="$WORKTREE_BASE/$TASK_ID"
  registry_add_task "$TASK_ID" "$REPO" "$BRANCH" "$WORKTREE_PATH" "$PROMPT" "queued"
  echo "task '$TASK_ID' queued. it will start when a slot opens."
  exit 0
fi

# --- create worktree ---

WORKTREE_PATH="$WORKTREE_BASE/$TASK_ID"
mkdir -p "$WORKTREE_BASE"

echo "creating branch '$BRANCH' and worktree at $WORKTREE_PATH..."
git -C "$REPO" worktree add "$WORKTREE_PATH" -b "$BRANCH"

# --- register task ---

registry_add_task "$TASK_ID" "$REPO" "$BRANCH" "$WORKTREE_PATH" "$PROMPT" "running"

# --- build agent prompt ---

REPO_NAME="$(basename "$REPO")"
REMOTE_URL="$(git -C "$REPO" remote get-url origin 2>/dev/null || echo "unknown")"

AGENT_PROMPT="you are working on a coding task in a git worktree.

repository: $REPO_NAME ($REMOTE_URL)
branch: $BRANCH
worktree: $WORKTREE_PATH

## task

$PROMPT

## instructions

- work in the current directory (the worktree)
- make commits using conventional commit style, lowercase only
- when you are done, push the branch and create a PR:
  git push -u origin $BRANCH
  gh pr create --title '<short title>' --body '<description of changes>'
- if a CLAUDE.md file exists in the repo, follow its instructions
- exit cleanly when the task is complete"

# --- launch agent ---

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$TASK_ID.log"

echo "launching claude agent for task '$TASK_ID'..."
nohup claude --dangerously-skip-permissions -p "$AGENT_PROMPT" > "$LOG_FILE" 2>&1 &
AGENT_PID=$!

# record pid
registry_set_field "$TASK_ID" "pid" "$AGENT_PID"

echo ""
echo "task '$TASK_ID' spawned:"
echo "  pid:      $AGENT_PID"
echo "  branch:   $BRANCH"
echo "  worktree: $WORKTREE_PATH"
echo "  log:      $LOG_FILE"
echo "  repo:     $REPO"
