#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWARM_DIR="$HOME/.clawdbot"
OPENCLAW_DIR="$HOME/.openclaw"

log() { echo "==> $1"; }
err() { echo "ERROR: $1" >&2; exit 1; }

# --- preflight ---

if [[ ! -f /etc/debian_version ]]; then
  err "only Ubuntu/Debian is supported"
fi

log "setting up agent swarm..."

# --- install system deps ---

log "installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y jq tmux

# --- install claude code ---

if command -v claude &>/dev/null; then
  log "claude code already installed: $(claude --version 2>/dev/null || echo 'unknown version')"
else
  log "installing claude code..."
  if command -v npm &>/dev/null; then
    sudo npm install -g @anthropic-ai/claude-code
  else
    err "npm not found. install node.js first (run setup.sh)"
  fi
fi

# --- install/verify gh CLI ---

if command -v gh &>/dev/null; then
  log "gh CLI already installed: $(gh --version 2>/dev/null | grep -m1 'gh version' || echo 'unknown')"
else
  log "installing gh CLI..."
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli-stable.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y gh
fi

# --- authenticate gh with GITHUB_TOKEN ---

if [[ -f "$OPENCLAW_DIR/.env" ]]; then
  # source the env file to get GITHUB_TOKEN
  set -a
  # shellcheck disable=SC1091
  source "$OPENCLAW_DIR/.env"
  set +a
fi

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  log "authenticating gh CLI with GITHUB_TOKEN..."
  echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || {
    log "WARNING: gh auth failed. you may need to run 'gh auth login' manually."
  }
else
  log "WARNING: GITHUB_TOKEN not set. add it to $OPENCLAW_DIR/.env and run 'gh auth login'."
fi

# --- create runtime directories ---

log "creating runtime directories..."
mkdir -p "$SWARM_DIR/worktrees" "$SWARM_DIR/logs"

# --- init task registry ---

TASK_REGISTRY="$SWARM_DIR/active-tasks.json"
TASK_ARCHIVE="$SWARM_DIR/archived-tasks.json"

MAX_CONCURRENT="${MAX_CONCURRENT:-2}"
MAX_TASK_AGE_HOURS="${MAX_TASK_AGE_HOURS:-24}"

if [[ ! -f "$TASK_REGISTRY" ]]; then
  log "initializing task registry..."
  cat > "$TASK_REGISTRY" <<EOF
{
  "version": 1,
  "config": {
    "maxConcurrent": $MAX_CONCURRENT,
    "maxTaskAgeHours": $MAX_TASK_AGE_HOURS
  },
  "tasks": []
}
EOF
else
  log "task registry already exists"
fi

if [[ ! -f "$TASK_ARCHIVE" ]]; then
  cat > "$TASK_ARCHIVE" <<EOF
{
  "version": 1,
  "tasks": []
}
EOF
fi

# --- symlink skill ---

SKILLS_DIR="$OPENCLAW_DIR/workspace/skills"
if [[ -d "$OPENCLAW_DIR" ]]; then
  mkdir -p "$SKILLS_DIR"
  ln -sfn "$SCRIPT_DIR/swarm/skill" "$SKILLS_DIR/agent-swarm"
  log "symlinked agent-swarm skill to $SKILLS_DIR/agent-swarm"
else
  log "WARNING: $OPENCLAW_DIR not found. run setup.sh first, then re-run this script."
fi

# --- make scripts executable ---

log "making swarm scripts executable..."
chmod +x "$SCRIPT_DIR/swarm/"*.sh

# --- create swap (safety net for B4ms) ---

if [[ ! -f /swapfile ]]; then
  log "creating 2GB swap file..."
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile

  # persist across reboots
  if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  fi
  log "swap created and enabled"
else
  log "swap file already exists"
fi

# --- install cron jobs ---

log "installing cron jobs..."

CRON_CHECK="*/10 * * * * PATH=/usr/local/bin:/usr/bin:/bin $SCRIPT_DIR/swarm/check-agents.sh >> $SWARM_DIR/logs/cron.log 2>&1"
CRON_CLEANUP="0 3 * * * PATH=/usr/local/bin:/usr/bin:/bin $SCRIPT_DIR/swarm/cleanup-agents.sh >> $SWARM_DIR/logs/cleanup.log 2>&1"

# get existing crontab (suppress "no crontab" error)
EXISTING_CRON="$(crontab -l 2>/dev/null || true)"

UPDATED_CRON="$EXISTING_CRON"

if ! echo "$EXISTING_CRON" | grep -qF "check-agents.sh"; then
  UPDATED_CRON="$UPDATED_CRON
$CRON_CHECK"
  log "  added check-agents cron (every 10 min)"
else
  log "  check-agents cron already installed"
fi

if ! echo "$EXISTING_CRON" | grep -qF "cleanup-agents.sh"; then
  UPDATED_CRON="$UPDATED_CRON
$CRON_CLEANUP"
  log "  added cleanup-agents cron (daily 3am)"
else
  log "  cleanup-agents cron already installed"
fi

echo "$UPDATED_CRON" | crontab -

# --- summary ---

echo ""
echo "========================================"
echo "  agent swarm setup complete"
echo "========================================"
echo ""
echo "runtime dir:    $SWARM_DIR"
echo "task registry:  $TASK_REGISTRY"
echo "worktrees:      $SWARM_DIR/worktrees/"
echo "logs:           $SWARM_DIR/logs/"
echo "skill:          $SKILLS_DIR/agent-swarm"
echo "max concurrent: $MAX_CONCURRENT"
echo ""
echo "to spawn an agent:"
echo "  $SCRIPT_DIR/swarm/spawn-agent.sh --repo /path/to/repo --id my-task --prompt 'do the thing'"
echo ""
echo "to check status:"
echo "  $SCRIPT_DIR/swarm/check-agents.sh --status"
echo ""

# --- verify ---

log "running verification checks..."

PASS=0 FAIL=0

check() {
  local desc="$1"
  shift
  if "$@" &>/dev/null; then
    echo "  [ok] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [!!] $desc"
    FAIL=$((FAIL + 1))
  fi
}

check "jq installed" command -v jq
check "claude installed" command -v claude
check "gh installed" command -v gh
check "gh authenticated" gh auth status
check "task registry exists" test -f "$TASK_REGISTRY"
check "worktrees dir exists" test -d "$SWARM_DIR/worktrees"
check "logs dir exists" test -d "$SWARM_DIR/logs"
check "skill symlinked" test -L "$SKILLS_DIR/agent-swarm"
check "swap enabled" bash -c "swapon --show | grep -q /swapfile"
check "cron installed" bash -c "crontab -l 2>/dev/null | grep -q check-agents"

echo ""
echo "  $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "WARNING: some checks failed. review the output above."
fi
