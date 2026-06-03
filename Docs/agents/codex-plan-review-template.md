# Codex Plan Review Template

Use this for `codex-plan-review.md`, the pre-implementation review of Claude's `claude-plan.md`.

```markdown
# Codex Plan Review

Status: APPROVED | CHANGES_REQUESTED | BLOCKED
Reviewer: Codex
Date: YYYY-MM-DD

## Scope Compliance

- Task contract followed: yes/no
- Product behavior changed: no/yes
- Files expected to change are within contracted scope: yes/no
- Contracted edge cases and regression surfaces covered: yes/no
- Manual QA expectation preserved: yes/no

## Findings

- <blocking finding, or "None">

## Required Adjustments Before Implementation

- <adjustment, or "None">

## Implementation Authorization

Claude may implement only if Status is APPROVED and Codex creates a valid `.codex-local/active-implementation.json` marker. No second user approval is required unless this review identifies a new product, scope, architecture, deletion/cleanup/rollback, or uncontracted infrastructure/dependency/tooling/git-state decision that is not already approved in `task-contract.md`.
```
