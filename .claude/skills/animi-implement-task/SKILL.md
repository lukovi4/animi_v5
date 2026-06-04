---
name: Animi Implement Task
description: Implement an Animi task only after all gates are approved. Manual gate skill for executing task-contract.md and claude-plan.md when codex-plan-review.md is APPROVED and active-implementation.json authorizes the task.
disable-model-invocation: true
argument-hint: <task-folder>
arguments: task_folder
---

# Animi Implement Task

Use this skill only when the user explicitly invokes `/animi-implement-task <task-folder>` after Codex plan review and marker creation.

## Required Gates

Before editing anything, verify `$task_folder` contains:

- `task-contract.md` with `Status: Approved`;
- `claude-plan.md`;
- `codex-plan-review.md` with `Status: APPROVED`.

Also verify `.codex-local/active-implementation.json` exists and names this task. If any gate is missing, expired, blocked, or ambiguous, stop. Do not create or edit gate files.

## Implementation Rules

- Edit normal repository code/test/project files needed for the task contract.
- If a needed change expands product scope or architecture beyond the approved task contract, stop and ask for Codex review.
- Dependency, tooling, infrastructure, hook, signing, and git-state changes are allowed only when explicitly inside the approved task contract. If they are needed and not contracted, stop and ask for Codex review.
- Do not change product behavior beyond `task-contract.md`.
- Do not edit Codex-owned gate artifacts.
- Do not edit `codex-analysis.md`; it is Codex-owned. Read it only as context when present.
- Use normal development Bash when needed: search/read, shell composition, pipes, redirects, focused tests, builds, verification, repo-local scripts, dependency commands, network commands, and normal git commands.
- Do not run raw `xcodebuild test` or raw `Scripts/run_animiapp_tests.sh` as verification. Use `Scripts/animi_quiet_xcodebuild.sh` with full logs under `$task_folder/artifacts/`.
- Do not run deletion, destructive cleanup, or git rollback cleanup commands. The hook hard-blocks forms such as `rm`, `find -delete`, dangerous `find -exec`, `git reset`, `git clean`, `git restore`, `git checkout`, `git rm`, and branch/tag deletion.
- Do not weaken tests.
- Preserve unrelated dirty worktree changes.
- If `codex-review.md` has `Status: Changes Requested`, treat it as a same-task repair pass and fix only the `Repair Instructions For Claude` section.

## Workflow

1. Read `task-contract.md`, `codex-analysis.md` if present, `claude-plan.md`, `codex-plan-review.md`, the active marker, and `codex-review.md` if present.
2. Confirm planned changes are still inside contracted scope.
3. Implement the smallest safe change that satisfies the task contract or same-task repair instructions.
4. Run the narrowest meaningful verification for the approved task through quiet wrappers when output may be noisy. Search/read commands are not verification evidence unless they directly support the summary.
5. Write `$task_folder/codex-review-packet.md` using `Docs/agents/codex-review-packet-template.md`.
6. Write `$task_folder/claude-summary.md` using `Docs/agents/claude-summary-template.md`.

## Summary Requirements

`claude-summary.md` must include:

- task id;
- marker id;
- marker status and expiry;
- marker snapshot fields required by `Docs/agents/claude-summary-template.md`;
- Codex plan review status;
- files changed;
- whether `codex-review-packet.md` was written;
- task contract compliance;
- exact verification commands and results;
- checks not run and why;
- manual QA notes from the task contract;
- deviations from the task contract, if any;
- known risks or follow-ups for Codex.

`codex-review-packet.md` must include:

- changed files with contract reason;
- contract coverage and edge-case coverage;
- focused risk hotspots for Codex review;
- exact verification commands, results, and full-log artifact paths;
- compact quiet-wrapper summaries for noisy verification;
- checks not run and risk;
- Claude self-review concerns;
- suggested Codex spot checks.

Keep the packet curated. Do not paste full logs, broad diffs, or large command output into it; put bulky evidence in `artifacts/`.

## Stop Rule

Stop immediately if scope changes, a new product decision is needed, deletion/cleanup/rollback is needed, an uncontracted infrastructure/dependency/tooling/git-state change is needed, or the marker is invalid.

If a Codex-owned gate artifact is missing, stop and direct the user back to the Codex workflow.
