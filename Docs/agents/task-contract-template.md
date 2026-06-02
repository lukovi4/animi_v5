# Task Contract Template

Use this for `task-contract.md`.

```markdown
# Task Contract: <title>

Status: Pending User Approval | Approved | In Progress | In Review | Manual QA Pending | Closed | Blocked
Track: Quick fix | Feature / behavior | Architecture / media pipeline
User Approval: <pending, or approved by user at date/context>

## User Request

<verbatim or summarized request>

## Goal

<one observable outcome>

## Expected User-Visible Outcome

<what changes for the user, or "No user-visible behavior change">

## Product Decisions

Approved:

- <decision, approver, and date/context>

Rejected:

- <option rejected and reason>

Deferred Non-Blocking:

- <decision deliberately deferred; must not block implementation or change approved behavior>

## Scope

In scope:

- <item>

Out of scope:

- <item>

## Pre-Contract Investigation

- Relevant knowledge maps checked: <domain/code-map/regression-map sections or "none">
- Code entry points verified: `<path>`: <what was checked>
- State/data flow verified: <short trace>
- Existing tests/seams verified: `<path>`: <what they cover>

## Product Semantics And Edge Cases

- Terms/semantics fixed by user approval: <definition>
- Edge cases considered:
  - <edge case>: <expected behavior or stop condition>

## Dependency / Regression Impact Scan

- Direct dependencies touched: <files/modules>
- Adjacent behavior that could regress: <behavior>
- Regression checks selected: <why these checks are enough>

## Implementation Guidance For Claude

1. <step>
2. <step>

## Files / Areas Likely Touched

- `<path>`: <why it may change>

## Verification

| Check | Command | Required | Notes |
|---|---|---:|---|
| Focused tests | `<command>` | yes/no | <why> |
| Lint/build/gate | `<command>` | yes/no | <why> |

## Manual QA

- Required: yes/no
- Steps: <exact device/simulator steps, or "n/a">
- Expected result: <observable expected result, or "n/a">

## Stop Conditions

- <when Claude must stop and ask>
- Any product/UX/behavior decision-tree branch that was not approved, proven by code/docs, or explicitly out of scope.

## Dangerous / Protected Actions

- Git commit/stage/push/tag/remote: not approved for Claude.
- Destructive git/delete/dependency/network/secrets/signing actions: not approved for Claude.
- Protected infrastructure paths: not approved for Claude in normal implementation.
- If the task truly needs any item above, stop for Codex/user handling outside the normal Claude implementation pass.

## Repair Loop Rules

- Same-scope defects stay in this task.
- Claude fixes same-scope defects only from `codex-review.md` repair instructions.
- Do not rerun Planning Pass for same-scope repair.

## Closure Criteria

- Verification evidence complete.
- Required manual QA passed or accepted as not run.
- No blocking Codex review findings.
- Marker removed or expired.
- Commit-ready files listed separately from unrelated dirty files.
```
