#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_DIR="$HOME/.openclaw"

# --- helpers ---

log() { echo "==> $1"; }
err() { echo "ERROR: $1" >&2; exit 1; }

prompt_secret() {
  local var_name="$1"
  local current_value="${!var_name:-}"
  if [[ -n "$current_value" ]]; then
    echo "==> $var_name provided via env" >&2
  else
    read -rp "$var_name: " current_value
    [[ -z "$current_value" ]] && err "$var_name is required"
  fi
  echo "$current_value"
}

# --- preflight checks ---

if [[ "$(id -u)" -eq 0 ]]; then
  echo "WARNING: running as root is not recommended."
  echo "the gateway should run as a regular user."
  echo "press ctrl-c to abort, or enter to continue anyway."
  read -r
fi

if [[ ! -f /etc/debian_version ]]; then
  err "only Ubuntu/Debian is supported for now"
fi

# --- install node 22 if needed ---

install_node() {
  log "installing node.js 22 via nodesource..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
}

if command -v node &>/dev/null; then
  NODE_MAJOR="$(node --version | sed 's/v\([0-9]*\).*/\1/')"
  if [[ "$NODE_MAJOR" -lt 22 ]]; then
    log "node $NODE_MAJOR found, need 22+"
    install_node
  else
    log "node $(node --version) already installed"
  fi
else
  install_node
fi

# --- install openclaw ---

log "installing openclaw globally..."
sudo npm install -g openclaw@latest

# --- create config directory ---

log "setting up $OPENCLAW_DIR..."
mkdir -p "$OPENCLAW_DIR"
chmod 700 "$OPENCLAW_DIR"

# --- copy config template ---

if [[ -f "$OPENCLAW_DIR/openclaw.json" ]]; then
  log "openclaw.json already exists, skipping copy"
else
  cp "$SCRIPT_DIR/config/openclaw.json" "$OPENCLAW_DIR/openclaw.json"
  log "copied config template to $OPENCLAW_DIR/openclaw.json"
fi

# --- collect secrets and write .env ---

log "configuring secrets..."

SLACK_APP_TOKEN="$(prompt_secret SLACK_APP_TOKEN)"
SLACK_BOT_TOKEN="$(prompt_secret SLACK_BOT_TOKEN)"
ANTHROPIC_API_KEY="$(prompt_secret ANTHROPIC_API_KEY)"

cat > "$OPENCLAW_DIR/.env" <<EOF
SLACK_APP_TOKEN=$SLACK_APP_TOKEN
SLACK_BOT_TOKEN=$SLACK_BOT_TOKEN
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
EOF

chmod 600 "$OPENCLAW_DIR/.env"
log "wrote secrets to $OPENCLAW_DIR/.env"

# --- create required directories ---

mkdir -p "$OPENCLAW_DIR/agents/main/sessions" "$OPENCLAW_DIR/credentials"

# --- install and start gateway ---

log "installing gateway service..."
openclaw gateway install

log "starting gateway..."
openclaw gateway start

# --- verify ---

log "waiting 5 seconds for gateway to start..."
sleep 5

log "checking gateway status..."
openclaw gateway status || true

log "checking channel status..."
openclaw channels status || true

log "running doctor..."
openclaw doctor --non-interactive || true

log "done. gateway should be running with slack connected."
