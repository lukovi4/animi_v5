# Create Animi Plan Output Order

Use the canonical templates in `../../../Docs/agents/`.

## Contract Pass

Create:

```text
task-contract.md
followups.md
artifacts/
```

Use:

- `../../../Docs/agents/task-folder-template.md`
- `../../../Docs/agents/task-contract-template.md`

## Approval

Only after explicit user approval, update:

```text
task-contract.md
```

Set `Status: Approved` and record the user approval statement.

## Pre-Implementation Review

After Claude writes `claude-plan.md`, create:

```text
codex-plan-review.md
```

Use:

- `../../../Docs/agents/codex-plan-review-template.md`
