#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# load environment for cron (PATH, GITHUB_TOKEN, etc.)
if [[ -f "$HOME/.openclaw/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$HOME/.openclaw/.env"
  set +a
fi

# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"

NOTIFY="$SCRIPT_DIR/notify.sh"
REVIEW="$SCRIPT_DIR/review-pr.sh"
SPAWN="$SCRIPT_DIR/spawn-agent.sh"

# --- status mode ---

if [[ "${1:-}" == "--status" ]]; then
  registry_init
  echo "=== agent swarm status ==="
  echo ""

  for status in running queued completed reviewing ready failed; do
    tasks="$(registry_list_by_status "$status")"
    count="$(echo "$tasks" | jq 'length')"
    if [[ "$count" -gt 0 ]]; then
      echo "[$status] ($count)"
      echo "$tasks" | jq -r '.[] | "  \(.id): \(.repo) (\(.branch))"'
      echo ""
    fi
  done

  active="$(registry_count_active)"
  echo "active: $active / $MAX_CONCURRENT"
  exit 0
fi

# --- cron mode ---

registry_init

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1"; }

# --- check running tasks ---

running_tasks="$(registry_list_by_status "running")"
running_count="$(echo "$running_tasks" | jq 'length')"

if [[ "$running_count" -gt 0 ]]; then
  echo "$running_tasks" | jq -c '.[]' | while IFS= read -r task; do
    id="$(echo "$task" | jq -r '.id')"
    pid="$(echo "$task" | jq -r '.pid')"
    repo="$(echo "$task" | jq -r '.repo')"
    branch="$(echo "$task" | jq -r '.branch')"
    created="$(echo "$task" | jq -r '.createdAt')"

    # check if process is still alive
    if [[ "$pid" != "null" ]] && kill -0 "$pid" 2>/dev/null; then
      # alive -- check age
      created_epoch="$(date -d "$created" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null || echo 0)"
      now_epoch="$(date +%s)"
      age_hours=$(( (now_epoch - created_epoch) / 3600 ))

      if [[ "$age_hours" -ge "$MAX_TASK_AGE_HOURS" ]]; then
        log "task '$id' exceeded max age (${age_hours}h >= ${MAX_TASK_AGE_HOURS}h). killing pid $pid."
        kill "$pid" 2>/dev/null || true
        sleep 2
        kill -9 "$pid" 2>/dev/null || true
        registry_update_status "$id" "failed"
        registry_set_field "$id" "error" "exceeded max age of ${MAX_TASK_AGE_HOURS}h"
        "$NOTIFY" --message "agent task '$id' killed: exceeded max age (${age_hours}h)" --all 2>/dev/null || true
      else
        log "task '$id' still running (pid $pid, age ${age_hours}h)"
      fi
    else
      # process is dead -- check if PR was created
      log "task '$id' process (pid $pid) is dead. checking for PR..."

      pr_info="$(gh pr list --repo "$repo" --head "$branch" --json number,url --jq '.[0]' 2>/dev/null || echo "")"

      if [[ -n "$pr_info" && "$pr_info" != "null" ]]; then
        pr_number="$(echo "$pr_info" | jq -r '.number')"
        pr_url="$(echo "$pr_info" | jq -r '.url')"
        log "task '$id' completed with PR #$pr_number"
        registry_update_status "$id" "completed"
        registry_set_field "$id" "prNumber" "$pr_number"
        registry_set_field "$id" "prUrl" "$pr_url"
      else
        log "task '$id' failed -- no PR found"
        registry_update_status "$id" "failed"
        registry_set_field "$id" "error" "agent exited without creating PR"

        notified="$(echo "$task" | jq -r '.notified')"
        if [[ "$notified" != "true" ]]; then
          "$NOTIFY" --message "agent task '$id' failed: exited without creating a PR. check log at $LOG_DIR/$id.log" --all 2>/dev/null || true
          registry_set_field "$id" "notified" "true"
        fi
      fi
    fi
  done
fi

# --- check completed tasks (trigger review) ---

completed_tasks="$(registry_list_by_status "completed")"
completed_count="$(echo "$completed_tasks" | jq 'length')"

if [[ "$completed_count" -gt 0 ]]; then
  echo "$completed_tasks" | jq -c '.[]' | while IFS= read -r task; do
    id="$(echo "$task" | jq -r '.id')"
    repo="$(echo "$task" | jq -r '.repo')"
    pr_number="$(echo "$task" | jq -r '.prNumber')"

    if [[ "$pr_number" == "null" ]]; then
      log "task '$id' completed but no PR number recorded, skipping review"
      continue
    fi

    # get remote repo for gh commands
    remote_repo="$(git -C "$repo" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")"
    if [[ -z "$remote_repo" ]]; then
      log "task '$id' cannot determine remote repo, skipping review"
      continue
    fi

    # check CI status
    ci_status="$(gh pr checks "$pr_number" --repo "$remote_repo" 2>/dev/null || echo "pending")"

    if echo "$ci_status" | grep -qi "fail"; then
      log "task '$id' PR #$pr_number has failing CI"
      registry_set_field "$id" "ciStatus" "failing"

      notified="$(echo "$task" | jq -r '.notified')"
      if [[ "$notified" != "true" ]]; then
        "$NOTIFY" --message "task '$id' PR #$pr_number: CI is failing. check: https://github.com/$remote_repo/pull/$pr_number" --all 2>/dev/null || true
        registry_set_field "$id" "notified" "true"
      fi
      continue
    fi

    # trigger review
    log "task '$id' triggering review for PR #$pr_number"
    registry_update_status "$id" "reviewing"
    registry_set_field "$id" "ciStatus" "passing"
    "$REVIEW" --repo "$remote_repo" --pr "$pr_number" --task-id "$id"
  done
fi

# --- check reviewing tasks ---

reviewing_tasks="$(registry_list_by_status "reviewing")"
reviewing_count="$(echo "$reviewing_tasks" | jq 'length')"

if [[ "$reviewing_count" -gt 0 ]]; then
  echo "$reviewing_tasks" | jq -c '.[]' | while IFS= read -r task; do
    id="$(echo "$task" | jq -r '.id')"
    review_posted="$(echo "$task" | jq -r '.reviewPosted')"

    if [[ "$review_posted" == "true" ]]; then
      log "task '$id' review complete, marking ready"
      registry_update_status "$id" "ready"

      notified="$(echo "$task" | jq -r '.notified')"
      if [[ "$notified" != "true" ]]; then
        pr_url="$(echo "$task" | jq -r '.prUrl')"
        "$NOTIFY" --message "task '$id' PR ready for review: $pr_url" --all 2>/dev/null || true
        registry_set_field "$id" "notified" "true"
      fi
    fi
  done
fi

# --- spawn queued tasks ---

active_count="$(registry_count_active)"

if [[ "$active_count" -lt "$MAX_CONCURRENT" ]]; then
  # check free memory (linux only, skip on macos)
  if [[ -f /proc/meminfo ]]; then
    free_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
    if [[ "$free_kb" -lt "$MIN_FREE_MEMORY_KB" ]]; then
      log "low memory (${free_kb}KB free < ${MIN_FREE_MEMORY_KB}KB). skipping queued tasks."
      exit 0
    fi
  fi

  queued_tasks="$(registry_list_by_status "queued")"
  queued_count="$(echo "$queued_tasks" | jq 'length')"

  if [[ "$queued_count" -gt 0 ]]; then
    # spawn the oldest queued task
    next_task="$(echo "$queued_tasks" | jq -c '.[0]')"
    next_id="$(echo "$next_task" | jq -r '.id')"
    next_repo="$(echo "$next_task" | jq -r '.repo')"
    next_prompt="$(echo "$next_task" | jq -r '.prompt')"
    next_branch="$(echo "$next_task" | jq -r '.branch')"

    log "spawning queued task '$next_id'..."

    # remove the queued entry (spawn-agent will re-add as running)
    registry_updated="$(jq --arg id "$next_id" '.tasks |= map(select(.id != $id))' "$TASK_REGISTRY")"
    _registry_write "$TASK_REGISTRY" "$registry_updated"

    "$SPAWN" --repo "$next_repo" --id "$next_id" --prompt "$next_prompt" --branch "$next_branch"
  fi
fi

log "check complete. active: $(registry_count_active) / $MAX_CONCURRENT"
