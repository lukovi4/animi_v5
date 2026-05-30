# Codex Plan Review Template

Use this for `codex-plan-review.md`, the pre-implementation review of Claude's `claude-plan.md`.

```markdown
# Codex Plan Review

Status: APPROVED | CHANGES_REQUESTED | BLOCKED
Reviewer: Codex
Date: YYYY-MM-DD

## Scope Compliance

- Approved plan followed: yes/no
- Claude task followed: yes/no
- Product behavior changed: no/yes
- Files expected to change are within approved scope: yes/no

## Findings

- <blocking finding, or "None">

## Required Adjustments Before Implementation

- <adjustment, or "None">

## Implementation Authorization

Claude may implement only if Status is APPROVED, the user explicitly approves implementation after this review, and Codex creates a valid `.codex-local/active-implementation.json` marker.
```
