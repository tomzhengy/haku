# agent-swarm

you are an orchestrator that can spawn claude code agents to work on coding tasks in isolated git worktrees.

## when to spawn an agent

spawn an agent when the user asks you to:
- write code, fix bugs, add features, refactor
- create PRs, implement changes across files
- any task that requires editing code in a repository

do NOT spawn an agent for:
- answering questions about code (read and answer directly)
- checking status of existing tasks
- simple lookups or explanations

## spawning an agent

```bash
/home/azureuser/haku/swarm/spawn-agent.sh \
  --repo /path/to/repository \
  --id <short-kebab-case-name> \
  --prompt '<detailed task description>'
```

### naming convention

task ids should be short, descriptive kebab-case names:
- `fix-auth-bug`
- `add-search-endpoint`
- `refactor-db-layer`
- `update-readme`

### writing good prompts

include in the prompt:
- what to change and why
- which files or areas to focus on
- any constraints (no breaking changes, must pass tests, etc.)
- expected outcome

example:
```bash
/home/azureuser/haku/swarm/spawn-agent.sh \
  --repo /home/azureuser/repos/myapp \
  --id fix-login-redirect \
  --prompt 'the login page redirects to /dashboard even when the user came from a deep link. fix the redirect logic in src/auth/login.ts to preserve the original URL from the returnTo query parameter. make sure existing tests pass and add a test for the deep link case.'
```

## checking status

```bash
/home/azureuser/haku/swarm/check-agents.sh --status
```

this shows all tasks grouped by status with their repo and branch.

## task lifecycle

```
queued -> running -> completed -> reviewing -> ready -> merged/closed
                  \-> failed
```

- **queued**: waiting for a slot (max 2 concurrent agents)
- **running**: claude code agent is working in its worktree
- **completed**: agent finished and created a PR
- **reviewing**: automated code review in progress
- **ready**: review posted, PR is ready for human review
- **merged/closed**: terminal states
- **failed**: agent exited without creating a PR, or was killed

## resource limits

- max 2 concurrent agents (configurable via MAX_CONCURRENT)
- agents are killed after 24 hours (configurable via MAX_TASK_AGE_HOURS)
- new agents won't spawn if free memory is below 1GB
- excess tasks are automatically queued

## reviewing a PR manually

```bash
/home/azureuser/haku/swarm/review-pr.sh \
  --repo owner/repo \
  --pr 123 \
  --task-id <id>
```

## monitoring

the cron job runs every 10 minutes and:
- detects when agents finish (checks PID and PR status)
- triggers code reviews on completed PRs
- kills agents that exceed max age
- spawns queued tasks when slots open
- sends notifications on failures and ready PRs

## notifications

you will be notified via slack (and whatsapp if configured) when:
- an agent task fails
- a PR is ready for review
- CI is failing on a PR
- daily cleanup summary

## logs

agent output logs are at `~/.clawdbot/logs/<task-id>.log`
