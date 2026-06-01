# Task Folder Template

Create local task folders under:

```text
.codex-local/tasks/YYYY-MM-DD-short-slug/
```

## Required Files

```text
task.md
product-decisions.md
plan.draft.md
plan.approved.md
claude-task.md
claude-plan.md
codex-plan-review.md
claude-summary.md
codex-review.md
followups.md
artifacts/
```

## Ownership

Artifact ownership is defined in `workflow.md`. This template only defines task-folder shape.

## `task.md`

```markdown
# Task: <short title>

Date: YYYY-MM-DD
Status: Draft | Approved | In Progress | In Review | Manual QA Pending | Closed | Blocked
Track: Quick fix | Feature / behavior | Architecture / media pipeline

## User Request

<verbatim or summarized request>

## Goal

<one observable outcome>

## Non-goals

- <what must not be changed>

## Context

- <targeted context only>
- Knowledge maps checked: <domain/code-map/regression-map sections or "none">
- Pre-plan investigation summary: <entry points, state/data flow, dependencies, test seams>
- Manual QA: <required/not required; exact steps live in plan/review when required>

## Links

- Approved plan: `plan.approved.md`
- Claude task: `claude-task.md`
- Claude plan review: `codex-plan-review.md`
- Claude summary: `claude-summary.md`
- Codex review: `codex-review.md`
```

## `product-decisions.md`

```markdown
# Product Decisions

## Approved Decisions

- <decision, approver, date>

## Rejected Options

- <option rejected, reason>

## Deferred Non-Blocking Decisions

- <decision deliberately deferred; must not block implementation or change approved behavior>

## Out Of Scope

- <behavior not being decided in this task>
```

## `followups.md`

```markdown
# Follow-ups

## Required Before Close

- <blocking follow-up>

## Later

- <non-blocking follow-up>
```

## `artifacts/`

Use for bulky logs, focused diffs, screenshots, generated reports, or test output. Prefer short summaries in task files and full output in artifacts.
