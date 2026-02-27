# agent swarm end-to-end workflow

## overview

the agent swarm pattern uses openclaw as an orchestrator that spawns isolated claude code agents. each agent works in its own git worktree, makes commits, pushes, and creates a PR. the system then automatically reviews the PR and notifies you when it's ready to merge.

## flow

```
user request (via slack/whatsapp)
  |
  v
openclaw orchestrator (decides: spawn agent or answer directly)
  |
  v
spawn-agent.sh
  - validates repo, checks concurrency
  - creates git worktree + branch
  - registers task in JSON registry
  - launches claude code with nohup
  |
  v
claude code agent (runs autonomously in worktree)
  - reads CLAUDE.md, understands codebase
  - makes changes, commits
  - pushes branch, creates PR via gh
  - exits
  |
  v
check-agents.sh (cron, every 10 min)
  - detects agent exit (kill -0 PID)
  - finds PR via gh pr list
  - marks task completed
  |
  v
review-pr.sh (triggered by check-agents)
  - gets PR diff and description
  - pipes to claude for code review
  - posts review as PR comment
  - marks task as ready
  |
  v
notify.sh
  - sends "PR ready for review" to slack/whatsapp
  |
  v
human reviews and merges
  |
  v
cleanup-agents.sh (daily cron, 3am)
  - removes worktrees for merged/closed/failed tasks
  - deletes remote branches
  - archives tasks from registry
  - rotates old logs
```

## components

### spawn-agent.sh

entry point for creating new agent tasks. handles:
- concurrency limits (queues if at max)
- worktree creation
- registry bookkeeping
- agent process launch

### check-agents.sh

monitoring daemon (cron). handles:
- detecting dead agents (PID check)
- finding PRs created by agents
- triggering code reviews
- killing stale agents (>24h)
- spawning queued tasks when slots open
- memory-aware scheduling (linux only)

also supports `--status` flag for on-demand status checks.

### review-pr.sh

automated code review. handles:
- fetching PR diff and description
- claude-powered review focusing on correctness, security, performance
- posting review as PR comment

### notify.sh

notification dispatch. handles:
- slack via openclaw message send
- whatsapp via openclaw message send
- fallback to stderr if send fails

### cleanup-agents.sh

daily maintenance. handles:
- archiving old tasks (>48h in terminal state)
- removing worktrees
- deleting merged/closed remote branches
- pruning git worktree state
- rotating logs (>7 days)

## configuration

all settings are environment variables with sensible defaults:

| variable | default | description |
|---|---|---|
| SWARM_DIR | ~/.clawdbot | base directory for runtime state |
| MAX_CONCURRENT | 2 | max simultaneous agents |
| MAX_TASK_AGE_HOURS | 24 | kill agents older than this |
| SWARM_SLACK_CHANNEL | (none) | slack channel for notifications |
| SWARM_WHATSAPP_TARGET | (none) | whatsapp number for notifications |
| MIN_FREE_MEMORY_KB | 1048576 | minimum free memory to spawn (1GB) |
| ARCHIVE_AFTER_HOURS | 48 | archive tasks after this many hours |
| LOG_RETAIN_DAYS | 7 | delete logs older than this |

## edge cases

- **concurrent modification**: registry writes use temp file + mv for atomicity
- **agent crash**: detected by check-agents via PID check, marked failed
- **no PR created**: agent may have errored out. check log at ~/.clawdbot/logs/<id>.log
- **CI failure**: notified but not auto-fixed. human decides next steps
- **low memory**: check-agents skips spawning queued tasks when free memory < 1GB
- **stale agents**: killed after MAX_TASK_AGE_HOURS, marked failed with notification
