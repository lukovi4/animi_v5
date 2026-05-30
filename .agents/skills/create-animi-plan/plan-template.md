# Create Animi Plan Template

Use this compact task plan shape. For full details, see `../../../Docs/agents/planning-template.md`.

## Draft Output Files

```text
task.md
product-decisions.md
plan.draft.md
followups.md
artifacts/
```

## Approved Handoff Files

Create only after explicit user approval:

```text
plan.approved.md
claude-task.md
```

## Pre-Implementation Review Files

Created after Claude writes `claude-plan.md`:

```text
codex-plan-review.md
```

## `task.md` Minimum

- title;
- date;
- status;
- track;
- user request;
- goal;
- non-goals;
- targeted context;
- links.

## `product-decisions.md` Minimum

- approved user decisions;
- open product decisions;
- recommended answer and impact for each open decision;
- out-of-scope behavior.

## `plan.draft.md` Minimum

- `Status: DRAFT`;
- goal;
- expected user-visible outcome;
- non-goals;
- approved product decisions;
- assumptions;
- likely files/areas;
- architecture constraints;
- implementation plan for Claude;
- verification commands;
- stop conditions;
- explicit permissions.

## `claude-task.md` Minimum

- source of truth: `plan.approved.md`;
- required Planning Pass output: `claude-plan.md`;
- stop after `claude-plan.md`;
- implementation requires `codex-plan-review.md` with `Status: APPROVED`, explicit user approval, and a valid `.codex-local/active-implementation.json` marker;
- scope/non-goals;
- files to read first;
- implementation constraints;
- required verification;
- stop-and-ask conditions.
