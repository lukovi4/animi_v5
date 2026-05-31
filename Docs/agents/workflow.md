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
- Manual Claude gate skills must be invoked by the user as slash commands. Do not hand Claude a prose prompt like "use the Planning Pass workflow"; provide the exact slash command.

## Knowledge Maps

Use these files as routing hints before expensive repository exploration:

- [domain.md](domain.md): stable glossary and product/architecture terms.
- [code-map.md](code-map.md): high-level code ownership map and likely entry points.
- [regression-map.md](regression-map.md): risk areas and focused verification seams.

Knowledge maps are not source of truth. Codex and Claude must still verify relevant current code before planning, implementation, or review. Update maps only when a task reveals stable reusable knowledge; do not add temporary assumptions or task-specific scratch notes.

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

- `task.md`: `Status: Draft | Approved | In Progress | In Review | Manual QA Pending | Closed | Blocked`
- `plan.draft.md`: `Status: DRAFT`
- `plan.approved.md`: `Status: APPROVED`
- `claude-plan.md`: `Status: Proposed | Blocked`
- `codex-plan-review.md`: `Status: APPROVED | CHANGES_REQUESTED | BLOCKED`
- `claude-summary.md`: `Status: Done | Done With Concerns | Blocked`
- `codex-review.md`: `Status: Approved | Changes Requested | Blocked | Needs User Decision | Manual QA Pending`

Claude proposes implementation plans in `claude-plan.md`. Codex approval lives only in `codex-plan-review.md`.

## Lifecycle

1. User gives a task.
2. Codex creates a task folder.
3. Codex classifies the task track.
4. Codex reads only the relevant knowledge-map sections, then verifies current code directly.
5. Codex performs a pre-plan investigation: entry points, state/data flow, dependencies, test seams, and likely regression surfaces.
6. Codex lists edge cases, product semantics, and consequences of likely fixes.
7. Codex asks the user every required product/UX/behavior question. Do not write the draft plan until required answers are clear.
8. Codex writes `task.md`, `product-decisions.md`, `plan.draft.md`, and `followups.md`.
9. User approves or rejects the draft plan.
10. Codex writes `plan.approved.md` with `Status: APPROVED`.
11. Codex writes `claude-task.md`.
12. Codex gives the user the exact Claude slash command: `/animi-planning-pass <task-folder>`.
13. The user invokes that slash command in Claude.
14. Claude reads `plan.approved.md` and `claude-task.md`.
15. Claude runs the Planning Pass skill, analyzes real code, writes only `claude-plan.md`, and stops.
16. Codex reviews `claude-plan.md` against `plan.approved.md` and writes `codex-plan-review.md`.
17. The user explicitly approves implementation.
18. Codex creates `.codex-local/active-implementation.json` as a scoped implementation marker.
19. Codex gives the user the exact Claude slash command: `/animi-implement-approved-plan <task-folder>`.
20. The user invokes that slash command in Claude.
21. Claude runs the implementation skill and changes only marker-approved paths.
22. Claude writes `claude-summary.md`.
23. Codex reviews implementation and writes `codex-review.md`.
24. If review finds issues that are within the same approved task, Codex keeps the same task open and sends Claude back through the same implementation skill after updating the review/marker as needed. Do not create a new task for same-scope repairs.
25. Codex decides whether manual QA is required. If required, Codex gives the user exact device steps and expected results.
26. Codex performs closure review: code cleanliness, obsolete/legacy cleanup, docs/map updates, marker cleanup, and commit readiness.
27. The task closes only after evidence-based verification and required manual QA pass, unless the user explicitly accepts the remaining risk.

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
- pre-plan investigation evidence;
- approved product decisions;
- product semantics and edge cases;
- dependency/regression impact scan;
- likely files/areas;
- implementation steps;
- verification commands;
- manual QA requirement;
- stop conditions;
- allowed sensitive actions.

### Claude Planning Pass Gate

For production code changes, Claude must write `claude-plan.md` before editing code. The plan must stay inside approved scope. Any conflict or missing decision stops implementation.

The Animi gate is not Claude's built-in Plan Mode. Claude must use the project Planning Pass skill, write only `claude-plan.md`, and stop. Production files, tests, project files, build scripts, and dependencies must not be edited during the Planning Pass.

Because the Planning Pass skill is manual-only, Claude must not call it through `Skill(...)` or emulate it from prose instructions. The user must invoke `/animi-planning-pass <task-folder>` directly.

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

The hook gate is the technical enforcement layer for writes, Bash, marker validation, settings changes, and post-tool repository audit.

`UserPromptExpansion` validates direct slash-command arguments. `PreToolUse` enforces allowed write/Bash shape. If deterministic slash provenance becomes required, implement it in the hook before documenting it as fully enforced.

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

Codex must also decide whether manual QA is required. Manual QA is required when automated tests cannot fully prove the user-visible behavior, animation/player timing, gesture flow, export output, device-only issue, or visual result. When required, Codex must provide exact steps and expected results, not a vague "test on device" instruction.

## Review

Codex review order:

1. plan compliance;
2. tests first;
3. correctness;
4. architecture invariants;
5. edge cases and regressions;
6. performance/security when relevant;
7. verification evidence;
8. manual QA need and result;
9. scope creep;
10. code cleanliness and obsolete/legacy cleanup;
11. docs/map update need;
12. closure, same-task repair, or follow-up.

Use [review-template.md](review-template.md).

## Same-Task Repair Loop

Use the same task folder when Claude's implementation has defects inside the already approved product scope.

Codex writes `codex-review.md` with `Status: Changes Requested`, lists exact findings, and keeps the marker active or issues a refreshed marker for the same task. Claude then reruns `/animi-implement-approved-plan <task-folder>` and fixes only the reviewed issues.

Create a new task only when the fix needs a new product decision, new architecture decision, unrelated scope, dependency/tooling change, or a materially different implementation path.

## Closure Criteria

A task can close only when:

- `plan.approved.md` was followed;
- `codex-plan-review.md` approved Claude's plan before implementation;
- Claude summary is complete;
- required verification passed or skipped checks are explicitly accepted risks;
- required manual QA passed or is explicitly accepted as not run;
- Codex review has no blocking findings;
- obsolete code/files introduced by the task are removed or explicitly retained;
- required docs or knowledge-map updates are completed or explicitly unnecessary;
- the active implementation marker is removed or expired;
- follow-ups are documented separately;
- git commit is created only after the user approves committing the reviewed final state.
