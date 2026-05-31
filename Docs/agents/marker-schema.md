# Active Implementation Marker

The active implementation marker is a scoped permission token:

```text
.codex-local/active-implementation.json
```

It is not source of truth. Source of truth remains the task folder artifacts.

Codex creates the marker only after:

- `plan.approved.md` has `Status: APPROVED`;
- `claude-task.md` exists;
- `claude-plan.md` exists;
- `codex-plan-review.md` has `Status: APPROVED`;
- the user explicitly approves implementation.

Codex must not create a normal implementation marker while any eternal-deny path is dirty. This includes `.claude/**`, `.agents/**`, `AGENTS.md`, `CLAUDE.md`, `Docs/agents/**`, hook files, settings, and the marker itself. Those changes must be completed through a separate infrastructure task before normal product implementation begins.

Claude must never create, edit, rename, or delete the marker.

The marker authorizes implementation only. It does not authorize planning, direct skill expansion, or infrastructure changes.

## Schema v1

```json
{
  "schema_version": 1,
  "status": "IMPLEMENTATION_APPROVED",
  "task_id": "2026-05-29-active-scene-tap-noop",
  "task_folder": ".codex-local/tasks/2026-05-29-active-scene-tap-noop",
  "approved_paths": [
    "AnimiApp/Sources/Editor/Store/EditorReducer.swift",
    "AnimiApp/Tests/EditorReducerPlayheadSelectionTests.swift"
  ],
  "baseline_dirty_paths": [
    ".gitignore",
    "findings.md",
    "logs.md"
  ],
  "allowed_bash_exact": [
    "ANIMIAPP_DERIVED_DATA_PATH=/tmp/active_scene_tap_noop bash Scripts/run_animiapp_tests.sh"
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

- `approved_paths` is exact only in v1. Prefix mode is not supported.
- `approved_paths` covers production/test/docs files that are part of the approved implementation scope.
- Claude task artifacts are derived from `task_folder`: implementation may write `claude-summary.md` and files under `artifacts/` only after the marker validates.
- `approved_paths` must never include `.claude/**`, `.agents/**`, `AGENTS.md`, `CLAUDE.md`, `Docs/agents/**`, or `.codex-local/active-implementation.json`.
- `allowed_bash_exact` must match the full trimmed command exactly.
- `allowed_bash_exact` is for verification/build/test commands assigned by Codex. Safe read-only inspection Bash is controlled by the hook and does not need marker entries.
- Allowed Bash strings must not contain shell composition or redirection such as `;`, `&&`, `||`, `|`, `>`, `<`, `$(`, backticks, heredoc, `tee`, `eval`, `bash -c`, or `sh -c`.
- `expires_at` should be short, usually one to two hours.
- `codex-plan-review.md` is frozen during implementation. If its SHA256 changes, the marker is invalid.
- `baseline_dirty_paths` avoids false positives in post-tool audit. It does not grant write permission.
- `baseline_dirty_paths` must not be used to ignore dirty eternal-deny paths for normal implementation markers. If an eternal-deny path is dirty, the marker should not be issued.
