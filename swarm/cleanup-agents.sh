#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"

NOTIFY="$SCRIPT_DIR/notify.sh"

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1"; }

registry_init

CLEANED=0
ERRORS=0
NOW_EPOCH="$(date +%s)"
ARCHIVE_THRESHOLD_SECS=$(( ARCHIVE_AFTER_HOURS * 3600 ))

# --- archive old completed/failed tasks ---

for status in merged closed failed ready; do
  tasks="$(registry_list_by_status "$status")"
  count="$(echo "$tasks" | jq 'length')"

  [[ "$count" -eq 0 ]] && continue

  echo "$tasks" | jq -c '.[]' | while IFS= read -r task; do
    id="$(echo "$task" | jq -r '.id')"
    completed_at="$(echo "$task" | jq -r '.completedAt // .updatedAt')"
    worktree_path="$(echo "$task" | jq -r '.worktreePath')"
    repo="$(echo "$task" | jq -r '.repo')"
    branch="$(echo "$task" | jq -r '.branch')"

    # check age
    completed_epoch="$(date -d "$completed_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$completed_at" +%s 2>/dev/null || echo 0)"
    age_secs=$(( NOW_EPOCH - completed_epoch ))

    if [[ "$age_secs" -lt "$ARCHIVE_THRESHOLD_SECS" ]]; then
      log "task '$id' ($status) not old enough to archive ($(( age_secs / 3600 ))h < ${ARCHIVE_AFTER_HOURS}h)"
      continue
    fi

    log "cleaning up task '$id' ($status, $(( age_secs / 3600 ))h old)..."

    # remove worktree
    if [[ -d "$worktree_path" ]]; then
      log "  removing worktree: $worktree_path"
      git -C "$repo" worktree remove "$worktree_path" --force 2>/dev/null || {
        log "  WARNING: failed to remove worktree, trying rm"
        rm -rf "$worktree_path" 2>/dev/null || true
      }
    fi

    # delete remote branch (only for merged/closed)
    if [[ "$status" == "merged" || "$status" == "closed" ]]; then
      log "  deleting remote branch: $branch"
      git -C "$repo" push origin --delete "$branch" 2>/dev/null || true
    fi

    # archive the task
    registry_archive_task "$id" 2>/dev/null || {
      log "  WARNING: failed to archive task '$id'"
      ERRORS=$((ERRORS + 1))
    }

    CLEANED=$((CLEANED + 1))
  done
done

# --- prune worktrees across known repos ---

repos="$(jq -r '[.tasks[].repo] | unique | .[]' "$TASK_REGISTRY" 2>/dev/null || echo "")"
if [[ -n "$repos" ]]; then
  while IFS= read -r repo; do
    if [[ -d "$repo" ]]; then
      log "pruning worktrees in $repo"
      git -C "$repo" worktree prune 2>/dev/null || true
    fi
  done <<< "$repos"
fi

# also prune repos from the archive
archive_repos="$(jq -r '[.tasks[].repo] | unique | .[]' "$TASK_ARCHIVE" 2>/dev/null || echo "")"
if [[ -n "$archive_repos" ]]; then
  while IFS= read -r repo; do
    if [[ -d "$repo" ]]; then
      git -C "$repo" worktree prune 2>/dev/null || true
    fi
  done <<< "$archive_repos"
fi

# --- rotate old logs ---

if [[ -d "$LOG_DIR" ]]; then
  old_logs="$(find "$LOG_DIR" -name "*.log" -mtime +"$LOG_RETAIN_DAYS" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$old_logs" -gt 0 ]]; then
    log "removing $old_logs log files older than ${LOG_RETAIN_DAYS} days"
    find "$LOG_DIR" -name "*.log" -mtime +"$LOG_RETAIN_DAYS" -delete 2>/dev/null || true
  fi
fi

# --- summary ---

SUMMARY="swarm cleanup: $CLEANED tasks archived, $ERRORS errors"
log "$SUMMARY"

if [[ "$CLEANED" -gt 0 || "$ERRORS" -gt 0 ]]; then
  "$NOTIFY" --message "$SUMMARY" --all 2>/dev/null || true
fi
