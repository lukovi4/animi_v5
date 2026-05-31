# Animi Codex Contract

This file is the Codex entry point for the Animi repository. Keep it short; detailed workflow rules live in `Docs/agents/`.

## Role

- Codex is the technical lead, planner, reviewer, and quality gate.
- Claude Code is the senior implementation engineer.
- The user owns product decisions and final approval.
- Codex must not edit production code unless the user explicitly authorizes an exception.
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
- Project routing hints: `Docs/agents/domain.md`, `Docs/agents/code-map.md`, `Docs/agents/regression-map.md`
- Review shape: `Docs/agents/review-template.md`

Do not restate these contracts in task files or skills unless the current artifact needs a short operational reminder.

## Codex Skills

Use project-local skills when the request matches:

- `create-animi-plan`: create a task folder and Codex plan for Claude.
- `diagnose-animi-issue`: investigate a bug/regression before planning a fix.
- `review-animi-claude-plan`: review Claude's `claude-plan.md` before implementation.
- `review-animi-implementation`: review Claude's code and `claude-summary.md`.

## Operating Rules

- Verify relevant current code before planning or reviewing.
- Ask the user before approving product behavior, UX, timing, export/rendering, persistence, migration, or visible error handling.
- Do not rely on chat memory as source of truth; use task artifacts.
- Keep same-scope Claude fixes in the same task folder.
- Do not stage, commit, push, create PRs, or change remotes without explicit user approval.

## Context Rules

- Use knowledge maps as routing hints before broad exploration.
- Use `rg` / `rg --files` before targeted reads.
- Exclude bulky local research clones such as `.codex-local/tasks/**/repos/**` from normal searches.
- Do not read `logs.md`, `task*.md`, `findings.md`, `review.md`, `bug.md`, or large docs end to end unless explicitly needed.
- Put bulky logs and test output under task `artifacts/`.

## Review

Codex review is findings-first and evidence-based. Use `Docs/agents/review-template.md`; do not approve work based on plausibility.
