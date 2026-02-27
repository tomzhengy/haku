#!/usr/bin/env bash
# jq-based JSON task registry functions.
# all writes use temp file + mv for atomicity.

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=constants.sh
source "$SCRIPT_LIB_DIR/constants.sh"

# ensure jq is available
command -v jq &>/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

# --- helpers ---

_registry_write() {
  local file="$1" content="$2"
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  echo "$content" > "$tmp"
  mv "$tmp" "$file"
}

_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# --- init ---

registry_init() {
  mkdir -p "$(dirname "$TASK_REGISTRY")"

  local _init_registry
  _init_registry="$(jq -n \
    --argjson max "$MAX_CONCURRENT" \
    --argjson age "$MAX_TASK_AGE_HOURS" \
    '{version: 1, config: {maxConcurrent: $max, maxTaskAgeHours: $age}, tasks: []}')"

  if [[ ! -f "$TASK_REGISTRY" ]]; then
    _registry_write "$TASK_REGISTRY" "$_init_registry"
  elif ! jq empty "$TASK_REGISTRY" 2>/dev/null; then
    echo "WARNING: $TASK_REGISTRY contains invalid JSON. backing up and reinitializing." >&2
    mv "$TASK_REGISTRY" "${TASK_REGISTRY}.bak.$(date +%s)"
    _registry_write "$TASK_REGISTRY" "$_init_registry"
  fi

  if [[ ! -f "$TASK_ARCHIVE" ]]; then
    _registry_write "$TASK_ARCHIVE" '{"version": 1, "tasks": []}'
  elif ! jq empty "$TASK_ARCHIVE" 2>/dev/null; then
    echo "WARNING: $TASK_ARCHIVE contains invalid JSON. backing up and reinitializing." >&2
    mv "$TASK_ARCHIVE" "${TASK_ARCHIVE}.bak.$(date +%s)"
    _registry_write "$TASK_ARCHIVE" '{"version": 1, "tasks": []}'
  fi
}

# --- read operations ---

registry_get_task() {
  local id="$1"
  jq -e --arg id "$id" '.tasks[] | select(.id == $id)' "$TASK_REGISTRY"
}

registry_list_by_status() {
  local status="$1"
  jq -r --arg s "$status" '[.tasks[] | select(.status == $s)]' "$TASK_REGISTRY"
}

registry_count_active() {
  jq '[.tasks[] | select(.status == "running")] | length' "$TASK_REGISTRY"
}

registry_list_all() {
  jq '.tasks' "$TASK_REGISTRY"
}

# --- write operations ---

registry_add_task() {
  local id="$1" repo="$2" branch="$3" worktree_path="$4" prompt="$5"
  local status="${6:-queued}"
  local now
  now="$(_now_iso)"

  local updated
  updated="$(jq --arg id "$id" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --arg wt "$worktree_path" \
    --arg prompt "$prompt" \
    --arg status "$status" \
    --arg now "$now" \
    '.tasks += [{
      id: $id,
      status: $status,
      repo: $repo,
      branch: $branch,
      worktreePath: $wt,
      prompt: $prompt,
      agent: "claude",
      pid: null,
      prNumber: null,
      prUrl: null,
      ciStatus: null,
      reviewPosted: false,
      createdAt: $now,
      updatedAt: $now,
      completedAt: null,
      error: null,
      notified: false,
      retryCount: 0
    }]' "$TASK_REGISTRY")"

  _registry_write "$TASK_REGISTRY" "$updated"
}

registry_update_status() {
  local id="$1" new_status="$2"
  local now
  now="$(_now_iso)"

  local updated
  updated="$(jq --arg id "$id" \
    --arg status "$new_status" \
    --arg now "$now" \
    '(.tasks[] | select(.id == $id)) |= (
      .status = $status |
      .updatedAt = $now |
      if ($status == "completed" or $status == "failed" or $status == "merged" or $status == "closed")
      then .completedAt = $now else . end
    )' \
    "$TASK_REGISTRY")"

  _registry_write "$TASK_REGISTRY" "$updated"
}

registry_set_field() {
  local id="$1" field="$2" value="$3"
  local now
  now="$(_now_iso)"

  local updated
  # handle numeric and boolean values without quotes
  if [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" == "true" ]] || [[ "$value" == "false" ]] || [[ "$value" == "null" ]]; then
    updated="$(jq --arg id "$id" \
      --arg field "$field" \
      --argjson value "$value" \
      --arg now "$now" \
      '(.tasks[] | select(.id == $id)) |= (.[$field] = $value | .updatedAt = $now)' \
      "$TASK_REGISTRY")"
  else
    updated="$(jq --arg id "$id" \
      --arg field "$field" \
      --arg value "$value" \
      --arg now "$now" \
      '(.tasks[] | select(.id == $id)) |= (.[$field] = $value | .updatedAt = $now)' \
      "$TASK_REGISTRY")"
  fi

  _registry_write "$TASK_REGISTRY" "$updated"
}

registry_archive_task() {
  local id="$1"

  # get the task
  local task
  task="$(registry_get_task "$id")" || { echo "ERROR: task $id not found" >&2; return 1; }

  # append to archive
  local archive_updated
  archive_updated="$(jq --argjson task "$task" '.tasks += [$task]' "$TASK_ARCHIVE")"
  _registry_write "$TASK_ARCHIVE" "$archive_updated"

  # remove from active registry
  local registry_updated
  registry_updated="$(jq --arg id "$id" '.tasks |= map(select(.id != $id))' "$TASK_REGISTRY")"
  _registry_write "$TASK_REGISTRY" "$registry_updated"
}
