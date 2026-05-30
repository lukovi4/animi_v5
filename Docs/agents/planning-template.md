# Planning Template

Use this for `plan.draft.md` and `plan.approved.md`.

```markdown
# <Task Title> Plan

Status: DRAFT | APPROVED
User Approval: <required for APPROVED; include date/context>

## Goal

<one observable outcome>

## Expected User-Visible Outcome

<what changes for the user, or "No user-visible behavior change">

## Non-goals

- <out of scope>

## Approved Product Decisions

- <decision and approval source>

## Assumptions

- <technical assumption that does not decide product behavior>

## Likely Files / Areas

- `<path>`: <why it may change>

## Architecture Constraints

- <relevant invariant>

## Implementation Plan For Claude

1. <step>
2. <step>

## Verification

| Check | Command | Required | Notes |
|---|---|---:|---|
| Focused tests | `<command>` | yes/no | <why> |
| Lint/build/gate | `<command>` | yes/no | <why> |

## Stop Conditions

- <when Claude must stop and ask>

## Explicit Permissions

- Git: none unless approved.
- Dependencies/tools: none unless approved.
- CI/hooks/project files: none unless approved.
- Docs: <allowed/not allowed>

## Expected Claude Outputs

- `claude-plan.md`
- `claude-summary.md`
- artifacts under `artifacts/` when logs are bulky
```

Claude must write `claude-plan.md` during the Planning Pass and stop. Implementation starts only after Codex writes `codex-plan-review.md` with `Status: APPROVED`, the user explicitly approves implementation, and Codex creates `.codex-local/active-implementation.json`.

## Readiness Checklist

Before marking a plan approved:

- [ ] Product behavior decisions are approved or out of scope.
- [ ] Scope and non-goals are clear.
- [ ] Likely files/areas are named.
- [ ] Verification commands are specific.
- [ ] Stop conditions are explicit.
- [ ] Sensitive actions are explicitly allowed or disallowed.
- [ ] No placeholders remain.
