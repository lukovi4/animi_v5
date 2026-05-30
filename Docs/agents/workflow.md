# Animi AI Workflow

This document is the stable workflow contract for Codex and Claude Code.

## Roles

- User: owns product decisions and final approval.
- Codex: technical lead, planner, reviewer, and quality gate.
- Claude: implementation engineer working only from an approved plan.

## Task Tracks

Use the lightest track that covers the risk.

| Track | Use When | Required Artifacts |
|---|---|---|
| Quick fix | Narrow bug, test, docs, or config task | `task.md`, `plan.approved.md`, `claude-summary.md`, `codex-review.md` |
| Feature / behavior | User-visible app behavior may change | Quick fix files plus `product-decisions.md` and acceptance criteria |
| Architecture / media pipeline | Cross-cutting or risky rendering, media, persistence, export, timeline, or architecture work | Feature files plus expanded readiness, verification, and possible ADR/follow-up |

The table describes task-document depth. It does not remove the mandatory implementation gates. Any Claude production-code change still requires `claude-plan.md`, `codex-plan-review.md`, explicit user implementation approval, and a valid implementation marker.

## Task Folder

Default local task folder:

```text
.codex-local/tasks/YYYY-MM-DD-short-slug/
```

Standard files:

```text
task.md
product-decisions.md
plan.draft.md
plan.approved.md
claude-task.md
claude-plan.md
codex-plan-review.md
claude-summary.md
codex-review.md
followups.md
artifacts/
```

Use [task-folder-template.md](task-folder-template.md) when creating a task folder.

## Project Skills

- Codex workflow skills live under `.agents/skills/`.
- Claude workflow skills live under `.claude/skills/`.
- Gate skills that should only run by explicit user command must use `disable-model-invocation: true`.

## Artifact Ownership

Codex owns:

- task folder creation;
- `task.md`;
- `product-decisions.md`;
- `plan.draft.md`;
- `plan.approved.md`;
- `claude-task.md`;
- `codex-plan-review.md`;
- `codex-review.md`;
- `followups.md`.

Claude owns only:

- `claude-plan.md` after receiving `plan.approved.md` and `claude-task.md`;
- `claude-summary.md` after implementation;
- `artifacts/` entries allowed by the approved plan;
- `claude-findings.md` only for explicitly requested read-only investigation.

Claude must not create task folders, `plan.approved.md`, or `claude-task.md`.

## Status Vocabulary

Status values are file-specific:

- `plan.draft.md`: `Status: DRAFT`
- `plan.approved.md`: `Status: APPROVED`
- `claude-plan.md`: `Status: Proposed | Blocked`
- `codex-plan-review.md`: `Status: APPROVED | CHANGES_REQUESTED | BLOCKED`
- `claude-summary.md`: `Status: Done | Done With Concerns | Blocked`
- `codex-review.md`: `Status: Approved | Changes Requested | Blocked | Needs User Decision`

Claude proposes implementation plans in `claude-plan.md`. Codex approval lives only in `codex-plan-review.md`.

## Lifecycle

1. User gives a task.
2. Codex creates a task folder.
3. Codex classifies the task track.
4. Codex gathers targeted context.
5. Codex asks for user approval on any product behavior decision.
6. Codex writes `plan.draft.md`.
7. User approves or rejects the draft plan.
8. Codex writes `plan.approved.md` with `Status: APPROVED`.
9. Codex writes `claude-task.md`.
10. Claude reads `plan.approved.md` and `claude-task.md`.
11. Claude runs the Planning Pass skill, analyzes real code, writes only `claude-plan.md`, and stops.
12. Codex reviews `claude-plan.md` against `plan.approved.md` and writes `codex-plan-review.md`.
13. The user explicitly approves implementation.
14. Codex creates `.codex-local/active-implementation.json` as a scoped implementation marker.
15. Claude runs the implementation skill and changes only marker-approved paths.
16. Claude writes `claude-summary.md`.
17. Codex reviews implementation and writes `codex-review.md`.
18. Codex closes/removes the marker, or lets it expire as a backstop.
19. If review finds blockers, Codex creates a follow-up task/plan.
20. The task closes only after evidence-based verification or explicit accepted risk.

## Approval Gates

### Product Gate

Codex must ask the user before approving any user-visible behavior, UX, default, timing, export/rendering behavior, persistence semantics, compatibility, migration, or visible error handling.

### Plan Gate

Claude can implement only from `plan.approved.md`.

`plan.approved.md` must include:

- `Status: APPROVED`;
- user approval statement;
- goal and expected outcome;
- scope and non-goals;
- approved product decisions;
- likely files/areas;
- implementation steps;
- verification commands;
- stop conditions;
- allowed sensitive actions.

### Claude Planning Pass Gate

For production code changes, Claude must write `claude-plan.md` before editing code. The plan must stay inside approved scope. Any conflict or missing decision stops implementation.

The Animi gate is not Claude's built-in Plan Mode. Claude must use the project Planning Pass skill, write only `claude-plan.md`, and stop. Production files, tests, project files, build scripts, and dependencies must not be edited during the Planning Pass.

### Codex Plan Review Gate

Codex must review `claude-plan.md` before implementation and write `codex-plan-review.md`.

`codex-plan-review.md` status must be one of:

- `APPROVED`;
- `CHANGES_REQUESTED`;
- `BLOCKED`.

Claude may implement only when the status is `APPROVED`.

### Implementation Marker Gate

After user implementation approval, Codex creates `.codex-local/active-implementation.json`.

The marker is a scoped permission token, not source of truth. It must name the task, exact approved paths, exact allowed Bash commands, expiry, baseline dirty paths, and the SHA256 of `codex-plan-review.md`.

Claude must not create, edit, rename, or delete the marker.

### Hook Gate

The hook gate is the deterministic layer. The intended design is:

- `UserPromptExpansion`: validate direct `/animi-planning-pass` and `/animi-implement-approved-plan` invocations;
- `PreToolUse`: block writes outside marker-approved paths and block Bash unless exact-allowed;
- `ConfigChange`: block unauthorized edits to Claude settings, hooks, skills, marker, and gate files;
- `PostToolBatch`: audit actual git changes after a tool batch and stop the session if a write bypass is detected.

See [marker-schema.md](marker-schema.md) and [hook-write-gate.md](hook-write-gate.md).

If no approved plan exists, Claude must stop and ask for the path to `plan.approved.md` or explicit permission for read-only investigation. Claude must not offer to create `claude-task.md`.

Claude must not offer bypassing, ignoring, or overriding the contract as an option. A request to bypass the contract is a workflow-change request, not implementation authorization.

Claude must not suggest that the user manually create, rename, or edit `plan.approved.md`, `claude-task.md`, `codex-plan-review.md`, or `.codex-local/active-implementation.json`. After user approval and Codex review, Codex owns approved handoff and gate artifact creation.

## Verification

Verification must be evidence-based.

Claude reports exact commands and outcomes in `claude-summary.md`.

Codex decides whether heavy checks must be re-run based on:

- risk of changed files;
- completeness of Claude summary;
- whether tests are relevant and fresh;
- review findings;
- architecture/media/persistence/export impact.

## Review

Codex review order:

1. plan compliance;
2. tests first;
3. correctness;
4. architecture invariants;
5. edge cases and regressions;
6. performance/security when relevant;
7. verification evidence;
8. scope creep;
9. closure or follow-up.

Use [review-template.md](review-template.md).

## Closure Criteria

A task can close only when:

- `plan.approved.md` was followed;
- `codex-plan-review.md` approved Claude's plan before implementation;
- Claude summary is complete;
- required verification passed or skipped checks are explicitly accepted risks;
- Codex review has no blocking findings;
- the active implementation marker is removed or expired;
- follow-ups are documented separately.
