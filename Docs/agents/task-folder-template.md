# Task Folder Template

Create local task folders under:

```text
.codex-local/tasks/YYYY-MM-DD-short-slug/
```

## Standard Files

```text
task-contract.md
codex-analysis.md
claude-plan.md
codex-plan-review.md
claude-summary.md
codex-review-packet.md
codex-review.md
followups.md
artifacts/
```

Artifact ownership and workflow gates are defined in `workflow.md`. This template only defines task-folder shape.

## `task-contract.md`

Use [task-contract-template.md](task-contract-template.md).

## `codex-analysis.md`

Use [codex-analysis-template.md](codex-analysis-template.md).

Codex writes this when a task requires real code investigation. It captures reusable architecture trace, root-cause trace, risk areas, verification seams, and map-update candidates. It is a routing and audit artifact, not source of truth.

## `codex-review-packet.md`

Use [codex-review-packet-template.md](codex-review-packet-template.md).

Claude writes this after implementation or same-task repair. It gives Codex curated review evidence and focused spot-check targets without pasting full logs or broad diffs.

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

Noisy test/build commands must write raw output here through `Scripts/animi_quiet_xcodebuild.sh`. Task files should reference the log path and compact summary, not paste raw output.
