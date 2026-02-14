# OpenClaw Slack Bot Setup Plan

## Current Status

- [x] step 1: check node.js 22+ (v22.21.1)
- [x] step 2: install openclaw (v2026.2.13)
- [x] step 2b: create config files (~/.openclaw/openclaw.json, ~/.openclaw/.env)
- [x] step 2c: install gateway daemon (LaunchAgent)
- [ ] step 3: create slack app (manual -- browser)
- [ ] step 4: get tokens and update ~/.openclaw/.env
- [ ] step 5: add AI provider key to ~/.openclaw/.env
- [ ] step 6: restart gateway and verify locally
- [ ] step 7: test slack bot
- [ ] step 8: deploy to azure VM (free tier)

## Remaining Local Steps

### step 3: create the slack app

1. go to https://api.slack.com/apps -> "Create New App" -> "From an app manifest"
2. paste this manifest:

```json
{
  "display_information": {
    "name": "OpenClaw",
    "description": "Slack connector for OpenClaw"
  },
  "features": {
    "bot_user": {
      "display_name": "OpenClaw",
      "always_online": false
    },
    "app_home": {
      "messages_tab_enabled": true,
      "messages_tab_read_only_enabled": false
    }
  },
  "oauth_config": {
    "scopes": {
      "bot": [
        "chat:write",
        "channels:history",
        "channels:read",
        "groups:history",
        "im:history",
        "mpim:history",
        "users:read",
        "app_mentions:read",
        "reactions:read",
        "reactions:write",
        "pins:read",
        "pins:write",
        "emoji:read",
        "files:read",
        "files:write"
      ]
    }
  },
  "settings": {
    "socket_mode_enabled": true,
    "event_subscriptions": {
      "bot_events": [
        "app_mention",
        "message.channels",
        "message.groups",
        "message.im",
        "message.mpim",
        "reaction_added",
        "reaction_removed",
        "member_joined_channel",
        "member_left_channel",
        "channel_rename",
        "pin_added",
        "pin_removed"
      ]
    }
  }
}
```

3. install the app to your workspace

### step 4: get tokens and update env

from the slack app settings:

- **App Token** (`xapp-...`): Basic Information -> App-Level Tokens -> Generate Token with scope `connections:write`
- **Bot Token** (`xoxb-...`): OAuth & Permissions -> Bot User OAuth Token

edit `~/.openclaw/.env`:

```bash
SLACK_APP_TOKEN=xapp-YOUR_REAL_TOKEN
SLACK_BOT_TOKEN=xoxb-YOUR_REAL_TOKEN
```

### step 5: add AI provider key

add at least one to `~/.openclaw/.env`:

```bash
OPENROUTER_API_KEY=...
# or: ANTHROPIC_API_KEY=...
# or: GROQ_API_KEY=...
```

### step 6: restart gateway and verify locally

```bash
openclaw gateway restart
openclaw gateway status        # should show running
openclaw doctor --non-interactive
openclaw channels status       # should show slack connected
```

### step 7: test slack bot

1. open slack, find "OpenClaw" bot in DMs (Apps section)
2. send it a message
3. if using pairing mode, approve:
   ```bash
   openclaw pairing list slack
   openclaw pairing approve slack <CODE>
   ```
4. in a channel: `/invite @OpenClaw` then mention it

---

## Step 8: Deploy to Azure VM (Free Tier)

### why azure free tier

- Azure free tier: B1s VM (1 vCPU, 1GB RAM, 64GB disk) -- 750 hours/month free for 12 months
- OpenClaw gateway is lightweight, B1s is more than enough
- socket mode means no inbound ports needed (outbound websocket to slack)
- no need for a public IP or domain for socket mode

### 8a: create azure account and VM

1. sign up at https://azure.microsoft.com/free/ (requires credit card but won't charge for free tier)
2. create a resource group (e.g., `openclaw-rg`)
3. create a VM:
   - image: Ubuntu 24.04 LTS
   - size: **Standard_B1s** (free tier eligible)
   - authentication: SSH public key
   - inbound ports: SSH (22) only -- no HTTP needed for socket mode
   - disk: 64GB standard SSD (free tier)
   - region: pick closest to you

```bash
# or via CLI:
az group create --name openclaw-rg --location eastus
az vm create \
  --resource-group openclaw-rg \
  --name openclaw-vm \
  --image Canonical:ubuntu-24_04-lts:server:latest \
  --size Standard_B1s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-sku Standard
```

### 8b: install openclaw on the VM

```bash
ssh azureuser@<VM_PUBLIC_IP>

# install node 22
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# install openclaw
npm install -g openclaw@latest

# create config directory
mkdir -p ~/.openclaw
```

### 8c: copy config to the VM

from local machine:

```bash
scp ~/.openclaw/openclaw.json azureuser@<VM_PUBLIC_IP>:~/.openclaw/
scp ~/.openclaw/.env azureuser@<VM_PUBLIC_IP>:~/.openclaw/
```

### 8d: set up systemd service on the VM

```bash
ssh azureuser@<VM_PUBLIC_IP>

# install the gateway daemon
openclaw gateway install

# or manually create a systemd service:
sudo tee /etc/systemd/system/openclaw-gateway.service > /dev/null << 'EOF'
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=azureuser
EnvironmentFile=/home/azureuser/.openclaw/.env
ExecStart=/usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable openclaw-gateway
sudo systemctl start openclaw-gateway
```

### 8e: verify on the VM

```bash
# check service
sudo systemctl status openclaw-gateway

# check openclaw
openclaw gateway status
openclaw channels status
openclaw doctor --non-interactive
```

### 8f: stop local gateway (optional)

once the azure VM is confirmed working:

```bash
# on local machine
openclaw gateway stop
launchctl unload ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

### azure cost notes

- B1s: free for 750 hours/month (covers 24/7 for one month) for first 12 months
- after 12 months: ~$7.59/month (or shut down and recreate under new free trial)
- to check usage: Azure Portal -> Cost Management -> Cost Analysis
- set up a budget alert to avoid surprise charges

---

## Key Files

| location                                           | purpose                    |
| -------------------------------------------------- | -------------------------- |
| `~/.openclaw/openclaw.json`                        | main config (JSON5)        |
| `~/.openclaw/.env`                                 | secrets (tokens, API keys) |
| `~/.openclaw/logs/`                                | local logs                 |
| `~/Library/LaunchAgents/ai.openclaw.gateway.plist` | local macOS daemon         |
| `/etc/systemd/system/openclaw-gateway.service`     | azure VM daemon            |

## Troubleshooting

- `openclaw doctor --fix` -- auto-fix common issues
- `openclaw logs --follow` -- tail logs
- `openclaw channels status --probe` -- test slack connection
- `openclaw security audit --deep` -- security check
- gateway crash on start: check `~/.openclaw/logs/gateway.err.log`
- `invalid_auth` error: tokens are wrong or missing in .env
