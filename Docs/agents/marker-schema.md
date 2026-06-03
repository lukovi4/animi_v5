# Active Implementation Marker

The active implementation marker is a scoped task authorization token:

```text
.codex-local/active-implementation.json
```

It is not source of truth. Source of truth remains the task folder artifacts.

The marker authorizes Claude to work on one approved implementation task. It does not micromanage every file path or Bash command.

Codex creates the marker only after:

- `task-contract.md` has `Status: Approved`;
- `claude-plan.md` exists;
- `codex-plan-review.md` has `Status: APPROVED`;
- no unresolved blocking product, scope, architecture, deletion/cleanup/rollback, or task-boundary decision remains.

The user's approval of `task-contract.md` authorizes implementation. A second approval is required only when Claude or Codex discovers a new decision outside that contract.

Claude must never create, edit, rename, or delete the marker.

The marker authorizes implementation only. It does not authorize planning, direct skill expansion, Codex-owned gate artifact edits, deletion, destructive cleanup, git rollback cleanup, or workflow bypass.

## Schema v1

```json
{
  "schema_version": 1,
  "status": "IMPLEMENTATION_APPROVED",
  "task_id": "2026-05-29-active-scene-tap-noop",
  "task_folder": ".codex-local/tasks/2026-05-29-active-scene-tap-noop",
  "baseline_dirty_paths": [
    ".gitignore",
    "findings.md",
    "logs.md"
  ],
  "codex_plan_review_sha256": "<sha256-of-codex-plan-review.md>",
  "approved_by": "user",
  "issued_by": "Codex",
  "issued_at": "2026-05-30T10:00:00+02:00",
  "expires_at": "2026-05-30T12:00:00+02:00",
  "marker_id": "<random-id-for-audit>"
}
```

## Rules

- `expires_at` should be short, usually one to two hours.
- `codex-plan-review.md` is frozen during implementation. If its SHA256 changes, the marker is invalid.
- `baseline_dirty_paths` records pre-existing dirty state for Codex review and commit hygiene. It is not a path allow-list and is not used by the hook to approve or deny writes.
- `baseline_dirty_paths` must never be interpreted as permission to delete tracked files.
- Normal implementation may edit repository code/test/project files as needed inside the approved task.
- Deletion, destructive cleanup, and git rollback cleanup are blocked by `hook-write-gate.md`, not by marker command allow-lists.
