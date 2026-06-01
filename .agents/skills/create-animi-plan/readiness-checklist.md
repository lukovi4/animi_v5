# Animi Plan Readiness Checklist

Run before asking for approval.

## Required

- [ ] Task track is selected.
- [ ] Relevant knowledge-map sections were checked or intentionally skipped.
- [ ] Real code investigation traced entry point, state/data flow, dependencies, and test seams.
- [ ] Adjacent behavior and regression surfaces are named.
- [ ] Edge cases are listed with expected behavior or stop conditions.
- [ ] Grill loop completed before drafting: relevant decision-tree branches were resolved or explicitly out of scope.
- [ ] Necessary user questions were asked one at a time with recommended answer and impact.
- [ ] No question was asked when code/docs or the user request already answered it.
- [ ] Product behavior decisions are approved or explicitly deferred as non-blocking.
- [ ] No unresolved relevant product/UX/behavior decisions remain in `product-decisions.md` or `plan.draft.md`.
- [ ] Recommended answers are clearly marked as recommendations, not decisions.
- [ ] Scope and non-goals are explicit.
- [ ] Likely files/areas are named.
- [ ] Existing dirty worktree risks are noted when relevant.
- [ ] Architecture constraints are named.
- [ ] Claude implementation steps are concrete.
- [ ] Verification commands are exact.
- [ ] Manual QA is marked required/not required; required manual QA has exact steps and expected result.
- [ ] Stop conditions are explicit.
- [ ] Sensitive actions are disallowed unless explicitly approved.
- [ ] No `plan.approved.md` exists before user approval.
- [ ] No `claude-task.md` exists before user approval.

## Approval Wording

Ask the user to approve the draft in plain language:

```text
Evidence: <3-6 concrete file/symbol bullets>.
Approved product decisions: <short list>.
Если план ок, напиши approve. После этого я создам plan.approved.md и claude-task.md для Claude.
```
