# Create Animi Plan Output Order

Use the canonical templates in `../../../Docs/agents/`.

## Draft Pass

Create:

```text
task.md
product-decisions.md
plan.draft.md
followups.md
artifacts/
```

Use:

- `../../../Docs/agents/task-folder-template.md`
- `../../../Docs/agents/planning-template.md`

## Approved Handoff

Only after explicit user approval, create:

```text
plan.approved.md
claude-task.md
```

Use:

- `../../../Docs/agents/planning-template.md`
- `../../../Docs/agents/claude-task-template.md`

## Pre-Implementation Review

After Claude writes `claude-plan.md`, create:

```text
codex-plan-review.md
```

Use:

- `../../../Docs/agents/codex-plan-review-template.md`
