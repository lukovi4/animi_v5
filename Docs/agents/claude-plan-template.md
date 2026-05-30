# Claude Plan Template

Use this for `claude-plan.md`.

```markdown
# Claude Plan

Status: Proposed | Blocked

## Understanding

<briefly restate the approved task>

## Approved Scope Check

- Approved plan read: yes/no
- Claude task read: yes/no
- Implementation started: no
- Scope changes proposed: no/yes

## Execution Steps

1. <step>
2. <step>

## Files Expected To Change

- `<path>`: <why>

## Tests / Verification Planned

- `<command>`: <why>

## Risks

- <risk Codex should know>

## Blockers Or Questions

- <question, or "None">
```

Rules:

- Do not introduce new product behavior.
- Do not expand the approved scope.
- Do not begin implementation if this plan is blocked.
- Stop after writing `claude-plan.md`.
- Do not edit production code, tests, project files, build scripts, or dependencies during the Planning Pass.
- Implementation requires `codex-plan-review.md` with `Status: APPROVED`, explicit user approval, and a valid `.codex-local/active-implementation.json` marker.
