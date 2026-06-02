# Animi AI Workflow

This document is the stable workflow contract for Codex and Claude Code.

## Roles

- User: owns product decisions, manual QA acceptance, and final commit approval.
- Codex: technical lead, product-question gate, planner, reviewer, and quality gate.
- Claude: implementation engineer working only from an approved task contract.

## Communication

Default to compressed technical communication: status, finding, next action. Avoid repeated contract text.

Expand only for architecture decisions, product tradeoffs, security/hook risks, destructive actions, or when the user asks for detail.

## Task Tracks

Use the lightest track that covers the risk.

| Track | Use When | Required Artifacts |
|---|---|---|
| Quick fix | Narrow bug, test, docs, or config task | `task-contract.md`, `claude-summary.md`, `codex-review.md` |
| Feature / behavior | User-visible app behavior may change | Quick fix files plus approved product decisions in `task-contract.md` |
| Architecture / media pipeline | Cross-cutting rendering, media, persistence, export, timeline, or architecture work | Feature files plus expanded readiness, verification, manual QA, and possible follow-up |

Any Claude production-code change still requires `claude-plan.md`, `codex-plan-review.md`, and a valid implementation marker.

## Task Folder

Default local task folder:

```text
.codex-local/tasks/YYYY-MM-DD-short-slug/
```

Standard files:

```text
task-contract.md
claude-plan.md
codex-plan-review.md
claude-summary.md
codex-review.md
followups.md
artifacts/
```

Use [task-folder-template.md](task-folder-template.md) and [task-contract-template.md](task-contract-template.md) when creating a task folder.

## Project Skills

- Codex workflow skills live under `.agents/skills/`.
- Claude workflow skills live under `.claude/skills/`.
- Gate skills that should only run by explicit user command must use `disable-model-invocation: true`.
- Manual Claude gate skills must be invoked by the user as slash commands. Do not hand Claude prose prompts like "use the Planning Pass workflow"; provide the exact slash command.

## Knowledge Maps

Use these files as routing hints before expensive repository exploration:

- [domain.md](domain.md): stable glossary and product/architecture terms.
- [code-map.md](code-map.md): high-level code ownership map and likely entry points.
- [regression-map.md](regression-map.md): risk areas and focused verification seams.

Knowledge maps are not source of truth. Codex and Claude must still verify relevant current code before planning, implementation, or review. Update maps only when a task reveals stable reusable knowledge.

## Artifact Ownership

Codex owns:

- task folder creation;
- `task-contract.md`;
- `codex-plan-review.md`;
- `codex-review.md`;
- `followups.md`;
- `.codex-local/active-implementation.json`.

Claude owns only:

- `claude-plan.md` during Planning Pass;
- normal implementation code/test/project files after marker validation;
- `claude-summary.md` after implementation;
- files under `artifacts/` when logs or generated evidence are bulky;
- `claude-findings.md` only for explicitly requested read-only investigation.

Claude must not create task folders, edit `task-contract.md`, edit Codex reviews, or edit the marker.

## Status Vocabulary

Status values are file-specific:

- `task-contract.md`: `Status: Pending User Approval | Approved | In Progress | In Review | Manual QA Pending | Closed | Blocked`
- `claude-plan.md`: `Status: Proposed | Blocked`
- `codex-plan-review.md`: `Status: APPROVED | CHANGES_REQUESTED | BLOCKED`
- `claude-summary.md`: `Status: Done | Done With Concerns | Blocked`
- `codex-review.md`: `Status: Approved | Changes Requested | Blocked | Needs User Decision | Manual QA Pending`

Claude proposes implementation plans in `claude-plan.md`. Codex approval lives only in `codex-plan-review.md`.

## Lifecycle

1. User gives a task.
2. Codex classifies the task track.
3. Codex reads relevant knowledge-map sections, then verifies current code directly.
4. Codex performs pre-contract investigation: entry points, state/data flow, dependencies, test seams, and likely regression surfaces.
5. Codex lists edge cases, product semantics, consequences of likely fixes, and the task decision tree.
6. Codex runs the grill loop before writing the contract: resolve relevant decision-tree branches one by one, ask only product/UX/scope/risk questions that can change the contract, include Codex's recommended answer and impact, wait for the user's answer, and investigate code instead of asking when code can answer.
7. Codex writes `task-contract.md` with `Status: Pending User Approval` and writes `followups.md` when useful.
8. User approves or rejects the task contract.
9. After approval, Codex updates the same `task-contract.md` to `Status: Approved` and records the user approval statement.
10. Codex gives the user the exact Claude slash command: `/animi-planning-pass <task-folder>`.
11. The user invokes that slash command in Claude.
12. Claude reads `task-contract.md`, analyzes real code, writes only `claude-plan.md`, and stops.
13. Codex reviews `claude-plan.md` against `task-contract.md` and writes `codex-plan-review.md`.
14. If `codex-plan-review.md` is `APPROVED`, Codex creates `.codex-local/active-implementation.json`. No second user approval is required.
15. Codex gives the exact Claude slash command: `/animi-implement-task <task-folder>`.
16. The user invokes that slash command in Claude.
17. Claude implements inside the approved task scope and hook guardrails.
18. Claude writes `claude-summary.md`.
19. Codex reviews implementation and writes `codex-review.md`.
20. If review finds same-scope defects, Codex keeps the same task open, writes explicit repair instructions in `codex-review.md`, refreshes the marker when needed, and sends Claude back through `/animi-implement-task <task-folder>`. Do not create a new task for same-scope repairs.
21. Codex decides whether manual QA is required. If required, Codex gives the user exact device steps and expected results.
22. Codex performs closure review: verification evidence, manual QA result, code cleanliness, obsolete/legacy cleanup, docs/map updates, marker cleanup, commit-ready files, and unrelated dirty files.
23. The task closes only after evidence-based verification and required manual QA pass, unless the user explicitly accepts remaining risk.
24. If the task is approved and commit-ready, Codex asks the user to write `commit`; Codex stages and commits only listed commit-ready files after that explicit command.

## Approval Gates

### Product Gate

Codex must ask the user before approving any user-visible behavior, UX, default, timing, export/rendering behavior, persistence semantics, compatibility, migration, or visible error handling.

Ask only questions whose answer can change approved behavior, scope, architecture boundary, regression risk, verification, or manual QA. Do not ask questions already answered by the user request, proven by current code, or internal to Claude's implementation inside approved scope.

`task-contract.md` must not contain unresolved relevant product decisions. Its Product Decisions section may contain only approved decisions, rejected options, and explicitly deferred non-blocking decisions.

### Task Contract Gate

Claude can implement only from `task-contract.md` with `Status: Approved`.

`task-contract.md` must include:

- user approval statement;
- goal and expected outcome;
- approved product decisions;
- scope and non-goals;
- pre-contract investigation evidence;
- product semantics and edge cases;
- dependency/regression impact scan;
- implementation guidance for Claude;
- verification requirements;
- manual QA requirement;
- stop conditions;
- dangerous/protected action boundaries.

### Claude Planning Pass Gate

For production code changes, Claude must write `claude-plan.md` before editing code. The plan must stay inside `task-contract.md`. Any conflict or missing decision stops implementation.

The Animi gate is not Claude's built-in Plan Mode. Claude must use the project Planning Pass skill, write only `claude-plan.md`, and stop. Production files, tests, project files, build scripts, and dependencies must not be edited during the Planning Pass.

Because the Planning Pass skill is manual-only, Claude must not call it through `Skill(...)` or emulate it from prose instructions. The user must invoke `/animi-planning-pass <task-folder>` directly.

### Codex Plan Review Gate

Codex must review `claude-plan.md` before implementation and write `codex-plan-review.md`.

`codex-plan-review.md` status must be one of:

- `APPROVED`;
- `CHANGES_REQUESTED`;
- `BLOCKED`.

Claude may implement only when the status is `APPROVED` and a valid marker exists.

Codex asks the user only when Claude's plan requires a new product decision, scope expansion, dangerous/protected action, or architecture decision not already approved in `task-contract.md`.

### Implementation Marker Gate

After Codex approves Claude's plan, Codex creates `.codex-local/active-implementation.json`.

The marker is a scoped task authorization token, not source of truth. It must name the task, expiry, baseline dirty paths, and the SHA256 of `codex-plan-review.md`.

Claude must not create, edit, rename, or delete the marker.

### Hook Gate

The hook gate is the technical enforcement layer for writes, Bash, marker validation, settings changes, and post-tool repository audit.

`UserPromptExpansion` validates direct slash-command arguments. `PreToolUse` allows normal development work and blocks critical dangerous actions plus protected infrastructure writes. If deterministic slash provenance becomes required, implement it in the hook before documenting it as fully enforced.

See [marker-schema.md](marker-schema.md) and [hook-write-gate.md](hook-write-gate.md).

Claude must not offer bypassing, ignoring, or overriding the contract as an option. A request to bypass the contract is a workflow-change request, not implementation authorization.

Claude must not suggest that the user manually create, rename, or edit `task-contract.md`, `codex-plan-review.md`, `codex-review.md`, or `.codex-local/active-implementation.json`.

## Verification

Verification must be evidence-based.

Claude reports exact commands and outcomes in `claude-summary.md`.

Codex decides whether heavy checks must be re-run based on:

- risk of changed files;
- completeness of Claude summary;
- whether tests are relevant and fresh;
- review findings;
- architecture/media/persistence/export impact.

Codex must also decide whether manual QA is required. Manual QA is required when automated tests cannot fully prove user-visible behavior, animation/player timing, gesture flow, export output, device-only issue, or visual result. When required, Codex must provide exact steps and expected results.

## Review

Codex review order:

1. task contract compliance;
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

Codex writes `codex-review.md` with `Status: Changes Requested` and an explicit `Repair Instructions For Claude` section. Claude then reruns `/animi-implement-task <task-folder>` and fixes only those reviewed issues.

Do not rerun Planning Pass for same-scope repairs.

Create a new task only when the fix needs a new product decision, new architecture decision, unrelated scope, dependency/tooling change, protected infrastructure change, dangerous action, or a materially different implementation path.

## Closure Criteria

A task can close only when:

- `task-contract.md` was followed;
- `codex-plan-review.md` approved Claude's plan before implementation;
- Claude summary is complete;
- required verification passed or skipped checks are explicitly accepted risks;
- required manual QA passed or is explicitly accepted as not run;
- Codex review has no blocking findings;
- obsolete code/files introduced by the task are removed or explicitly retained;
- required docs or knowledge-map updates are completed or explicitly unnecessary;
- the active implementation marker is removed or expired;
- follow-ups are documented separately;
- commit-ready files and unrelated dirty files are listed;
- git commit is created only after the user writes `commit`, and only listed commit-ready files are staged.
