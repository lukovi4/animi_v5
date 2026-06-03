# Claude Plan Template

Use this for `claude-plan.md`.

```markdown
# Claude Plan

Status: Proposed | Blocked

## Understanding

<briefly restate the approved task contract>

## Task Contract Check

- Task contract read: yes/no
- Task contract status: Approved/not approved
- Codex analysis read: yes/no/not present
- Implementation started: no
- Scope changes proposed: no/yes

## Execution Steps

1. <step>
2. <step>

## Files Expected To Change

- `<path>`: <why>

## Edge Cases / Regression Checks

- <edge case or adjacent behavior from the task contract>

## Tests / Verification Planned

- `<command>`: <why>

## Manual QA

- Required by task contract: yes/no
- Claude notes for Codex: <anything Codex should verify manually, or "None">

## Risks

- <risk Codex should know>

## Blockers Or Questions

- <question, or "None">
```

Rules:

- Keep this plan inside `task-contract.md`.
- Do not introduce new product behavior or scope.
- Stop after writing `claude-plan.md`.
- Do not edit production code, tests, project files, build scripts, or dependencies during the Planning Pass.
