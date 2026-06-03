# Codex Review Packet Template

Use this for `codex-review-packet.md`.

`codex-review-packet.md` is Claude-owned and written after implementation or same-task repair. It is a curated evidence packet for Codex review. It must summarize evidence and point to exact risky hunks; it must not paste full logs or broad diffs.

```markdown
# Codex Review Packet

## Scope Snapshot

- Task id: `<task-id>`
- Implementation pass: initial | same-task repair
- Codex plan review status: APPROVED
- Task contract followed: yes/no
- Scope changes: none/<list>

## Changed Files

| File | Change | Contract reason |
|---|---|---|
| `<path>` | <short description> | <task-contract or repair instruction reference> |

## Contract Coverage

- <contract requirement>: <implemented by path/symbol/test>
- <edge case>: <covered by path/symbol/test or not covered>

## Risk Hotspots For Codex

1. `<path>`: <symbol or tight line-range target> - <why this is risky>
2. `<path>`: <symbol or tight line-range target> - <why this is risky>

Prefer focused review targets over full-file references.

## Verification Evidence

| Command | Result | What it proves | Full log |
|---|---|---|---|
| `<command>` | passed/failed/not run | <behavior or gate proven> | `artifacts/<file>` or n/a |

## Not Verified / Accepted Risk

- <check not run>: <why, risk, and whether Codex/user must decide>

## Claude Self-Review

- Spec/contract compliance concerns: <none or list>
- Code quality concerns: <none or list>
- Test concerns: <none or list>

## Suggested Codex Spot Checks

1. `<path>`: <specific symbol/range> - <reason>
2. `<path>`: <specific symbol/range> - <reason>

## Map / Follow-up Suggestions

- Stable knowledge-map update suggested: <yes/no and detail>
- Follow-up outside approved scope: <none or list>
```
