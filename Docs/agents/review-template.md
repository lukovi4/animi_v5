# Codex Review Template

Use this for `codex-review.md`.

```markdown
# Codex Review

Status: Approved | Changes Requested | Blocked | Needs User Decision | Manual QA Pending

## Findings

### P0 Blockers

- <file:line> <issue, impact, required fix>

### P1 High

- <file:line> <issue, impact, required fix>

### P2 Medium

- <file:line> <issue, impact, suggested fix>

### P3 Low

- <file:line> <issue, optional cleanup>

## Plan Compliance

- Approved plan followed: yes/no
- Scope creep found: yes/no
- Product decisions changed: yes/no

## Tests First

- Tests added/changed: <summary>
- Tests match risk: yes/no
- Missing tests: <none or list>

## Verification Evidence

| Check | Claude Result | Codex Verified | Notes |
|---|---|---|---|
| `<command>` | passed/failed/not run | yes/no/not rerun | <reason> |

## Manual QA

- Required: yes/no
- Steps for user: <exact steps, or n/a>
- Expected result: <observable expected result, or n/a>
- Result: passed/failed/not run/not required

## Architecture / Invariants

- <preview/export, TVECore boundary, media timing, persistence, etc.>

## Code Cleanliness

- Obsolete/legacy code removed: yes/no/n/a
- Unrelated churn found: yes/no
- Docs or knowledge maps updated: yes/no/n/a

## Commit Readiness

- Commit-ready files:
  - `<path>`
- Unrelated dirty files excluded:
  - `<path>`
- Commit gate: user must write `commit` before Codex stages or commits files.

## Same-Task Repair

- Fixes needed in same task: yes/no
- New task required: yes/no and why

## Remaining Risks

- <risk or "None">

## Verdict

<approve, request fixes, or ask user for decision>
```

Review process is defined in `workflow.md`. This file defines the `codex-review.md` shape.
