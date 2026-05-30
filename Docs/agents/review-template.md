# Codex Review Template

Use this for `codex-review.md`.

```markdown
# Codex Review

Status: Approved | Changes Requested | Blocked | Needs User Decision

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

## Architecture / Invariants

- <preview/export, TVECore boundary, media timing, persistence, etc.>

## Remaining Risks

- <risk or "None">

## Verdict

<approve, request fixes, or ask user for decision>
```

Review order:

1. Check `plan.approved.md`.
2. Check `codex-plan-review.md` approved `claude-plan.md` before implementation.
3. Check whether the implementation stayed within marker-approved paths.
4. Review tests before implementation details.
5. Check correctness and regressions.
6. Check architecture invariants.
7. Check verification evidence.
8. Decide whether heavy checks need rerun.
