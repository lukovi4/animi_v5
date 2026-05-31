# Claude Summary Template

Use this for `claude-summary.md`.

```markdown
# Claude Summary

Status: Done | Done With Concerns | Blocked

## 1. Gate Context

- Task id: `<task-id>`
- Marker id: `<marker_id or n/a>`
- Marker status: valid/invalid/not used
- Marker expires at: `<timestamp or n/a>`
- Codex plan review status: APPROVED/CHANGES_REQUESTED/BLOCKED/not present

## 2. Plan Compliance

- Approved plan followed: yes/no
- Deviations: <none or list>
- Scope changes: <none or list>

## 3. Files Changed

| File | Change | Reason |
|---|---|---|
| `<path>` | <short description> | <plan step or reason> |

## 4. Verification

| Command | Result | Key Output | Full Log |
|---|---|---|---|
| `<command>` | passed/failed/not run | <key lines> | `artifacts/<file>` or n/a |

Skipped checks:

- `<command>`: <why skipped and risk>

## 5. Tests Added / Changed

- `<test file>`: <behavior covered>
- Red/green observed: yes/no/not applicable

## 6. Risk Areas For Codex

- <area that deserves targeted review>

## 7. Manual QA Notes

- Required by approved plan: yes/no
- Claude result: not run by Claude / n/a
- Suggested focus for Codex/user: <manual area, or "None">

## 8. Known Issues / Follow-ups

- <issue or "None">

## 9. Questions For Codex

- <question or "None">
```

Requirements:

- Use exact commands.
- Do not write "should pass" as evidence.
- Keep summaries short; put bulky logs in `artifacts/`.
- Mark skipped verification as risk, not success.
