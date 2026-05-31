# Animi Plan Readiness Checklist

Run before asking for approval.

## Required

- [ ] Task track is selected.
- [ ] Relevant knowledge-map sections were checked or intentionally skipped.
- [ ] Real code investigation traced entry point, state/data flow, dependencies, and test seams.
- [ ] Adjacent behavior and regression surfaces are named.
- [ ] Edge cases are listed with expected behavior or stop conditions.
- [ ] Product behavior decisions are approved or listed as open.
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
Если план ок, напиши approve. После этого я создам plan.approved.md и claude-task.md для Claude.
```
