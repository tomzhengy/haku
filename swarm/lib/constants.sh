#!/usr/bin/env bash
# shared constants for the agent swarm.
# all paths support env var overrides.

SWARM_DIR="${SWARM_DIR:-$HOME/.clawdbot}"
TASK_REGISTRY="${TASK_REGISTRY:-$SWARM_DIR/active-tasks.json}"
TASK_ARCHIVE="${TASK_ARCHIVE:-$SWARM_DIR/archived-tasks.json}"
WORKTREE_BASE="${WORKTREE_BASE:-$SWARM_DIR/worktrees}"
LOG_DIR="${LOG_DIR:-$SWARM_DIR/logs}"

# concurrency limit -- safe default for B4ms (4 vCPU, 16GB)
MAX_CONCURRENT="${MAX_CONCURRENT:-2}"

# max hours before a task is considered stale and killed
MAX_TASK_AGE_HOURS="${MAX_TASK_AGE_HOURS:-24}"

# notification targets (set in ~/.openclaw/.env or environment)
SLACK_CHANNEL="${SWARM_SLACK_CHANNEL:-}"
WHATSAPP_TARGET="${SWARM_WHATSAPP_TARGET:-}"

# minimum free memory (KB) required to spawn a new agent
MIN_FREE_MEMORY_KB="${MIN_FREE_MEMORY_KB:-1048576}"  # 1GB

# cleanup thresholds
ARCHIVE_AFTER_HOURS="${ARCHIVE_AFTER_HOURS:-48}"
LOG_RETAIN_DAYS="${LOG_RETAIN_DAYS:-7}"
