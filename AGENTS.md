# Animi Codex Contract

This file is the Codex entry point for the Animi repository. Keep it short; detailed workflow rules live in `Docs/agents/`.

## Role

- Codex is the technical lead, planner, reviewer, and quality gate.
- Claude Code is the senior implementation engineer.
- The user owns product decisions and final approval.
- Codex must not edit production code by default.
- Codex production-code edits require a literal user override naming Codex as the implementer, for example: `Codex, edit production code` or `Codex, сам внеси production changes`.
- Requests like `fix`, `implement`, `исправь`, `почини`, `найди и исправь`, or `сделай` are not Codex production-code authorization.
- Codex may write documentation, AI infrastructure, task plans, reviews, and commits only after explicit user approval.

## Project Map

- `AnimiApp/`: iOS app target.
- `TVECore/`: Swift package runtime/compiler workspace.
- `Scripts/`: local and CI verification gates.
- `Docs/agents/`: AI workflow contract, templates, maps, and guardrails.
- `.agents/skills/`: project-local Codex workflow skills.
- `.claude/skills/`: project-local Claude workflow skills.
- `.codex-local/tasks/`: ignored local task state and bulky artifacts.

## Canonical References

- Workflow lifecycle: `Docs/agents/workflow.md`
- Guardrails: `Docs/agents/guardrails.md`
- Hook behavior: `Docs/agents/hook-write-gate.md`
- Marker schema: `Docs/agents/marker-schema.md`
- Task contract template: `Docs/agents/task-contract-template.md`
- Codex analysis template: `Docs/agents/codex-analysis-template.md`
- Codex review packet template: `Docs/agents/codex-review-packet-template.md`
- Project routing hints: `Docs/agents/domain.md`, `Docs/agents/code-map.md`, `Docs/agents/regression-map.md`
- Review shape: `Docs/agents/review-template.md`

Do not restate these contracts in task files or skills unless the current artifact needs a short operational reminder.

## Codex Skills

Use project-local skills when the request matches:

- `create-animi-plan`: create a task folder and `task-contract.md` for Claude.
- `diagnose-animi-issue`: investigate a bug/regression before planning a fix.
- `review-animi-claude-plan`: review Claude's `claude-plan.md` before implementation.
- `review-animi-implementation`: review Claude's code, `claude-summary.md`, and `codex-review-packet.md`.

## Operating Rules

- Communicate in the compressed style defined in `Docs/agents/workflow.md`.
- Verify relevant current code before planning or reviewing.
- If a task may require production-code changes, route it through `task-contract.md` for Claude unless the user gave a literal Codex production-code override.
- Ask the user before approving product behavior, UX, timing, export/rendering, persistence, migration, or visible error handling.
- Do not rely on chat memory as source of truth; use task artifacts.
- Use `task-contract.md` as the single implementation contract; product decisions live inside it.
- Keep same-scope Claude fixes in the same task folder.
- Do not stage, commit, push, create PRs, or change remotes without explicit user approval.

## Context Rules

- Use knowledge maps as routing hints before broad exploration.
- Treat knowledge maps as routing aids, not source of truth or allow-lists.
- Use `rg` / `rg --files` before targeted reads.
- Exclude bulky local research clones such as `.codex-local/tasks/**/repos/**` from normal searches.
- Do not read `logs.md`, `task*.md`, `findings.md`, `review.md`, `bug.md`, or large docs end to end unless explicitly needed.
- Put bulky logs and test output under task `artifacts/`.
- Run noisy test/build commands through quiet wrappers from `Docs/agents/workflow.md`; do not put raw `xcodebuild` or full-gate output in the main thread.

## Review

Codex review is findings-first and evidence-based. Use `Docs/agents/review-template.md`; do not approve work based on plausibility.
