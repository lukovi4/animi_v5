# Task Folder Template

Create local task folders under:

```text
.codex-local/tasks/YYYY-MM-DD-short-slug/
```

## Standard Files

```text
task-contract.md
claude-plan.md
codex-plan-review.md
claude-summary.md
codex-review.md
followups.md
artifacts/
```

Artifact ownership and workflow gates are defined in `workflow.md`. This template only defines task-folder shape.

## `task-contract.md`

Use [task-contract-template.md](task-contract-template.md).

## `followups.md`

```markdown
# Follow-ups

## Required Before Close

- <blocking follow-up, or "None">

## Later

- <non-blocking follow-up, or "None">
```

## `artifacts/`

Use for bulky logs, focused diffs, screenshots, generated reports, or test output. Prefer short summaries in task files and full output in artifacts.
