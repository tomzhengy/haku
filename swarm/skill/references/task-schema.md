# task registry JSON schema

the task registry is stored at `~/.clawdbot/active-tasks.json`.

## top-level structure

```json
{
  "version": 1,
  "config": {
    "maxConcurrent": 2,
    "maxTaskAgeHours": 24
  },
  "tasks": [...]
}
```

## task object

| field        | type        | description                                                                  |
| ------------ | ----------- | ---------------------------------------------------------------------------- |
| id           | string      | unique task identifier (kebab-case)                                          |
| status       | string      | one of: queued, running, completed, reviewing, ready, merged, closed, failed |
| repo         | string      | absolute path to the git repository                                          |
| branch       | string      | git branch name (e.g., claude/fix-auth-bug)                                  |
| worktreePath | string      | absolute path to the git worktree                                            |
| prompt       | string      | the task prompt given to the agent                                           |
| agent        | string      | always "claude" for now                                                      |
| pid          | number/null | process id of the running agent                                              |
| prNumber     | number/null | github PR number once created                                                |
| prUrl        | string/null | github PR URL                                                                |
| ciStatus     | string/null | "passing", "failing", or null                                                |
| reviewPosted | boolean     | whether automated review has been posted                                     |
| createdAt    | string      | ISO 8601 timestamp                                                           |
| updatedAt    | string      | ISO 8601 timestamp                                                           |
| completedAt  | string/null | ISO 8601 timestamp when task reached terminal state                          |
| error        | string/null | error message if failed                                                      |
| notified     | boolean     | whether notification has been sent for current state                         |
| retryCount   | number      | number of times this task has been retried                                   |

## status transitions

```
queued ----spawn----> running
running ---PR ok----> completed
running ---no PR----> failed
running ---timeout--> failed
completed -CI ok----> reviewing
completed -CI fail--> (stays completed, notifies)
reviewing -done-----> ready
ready ----merge-----> merged
ready ----close-----> closed
```

## archive file

completed tasks are archived to `~/.clawdbot/archived-tasks.json` after 48 hours.
same structure as the main registry, but only contains the tasks array.

```json
{
  "version": 1,
  "tasks": [...]
}
```
