# Animi Reproduction Template

Use this for diagnosis notes or `claude-findings.md`.

```markdown
# Diagnosis: <issue title>

## Symptom

<what the user/test observes>

## Expected Behavior

<approved or existing expected behavior>

## Reproduction

Steps:

1. <step>
2. <step>

Reliability:

- deterministic / flaky / not reproduced yet
- reproduction rate if flaky

## Feedback Loop

| Loop | Command / Action | Signal | Speed |
|---|---|---|---|
| <test/script/manual> | `<command>` | <pass/fail signal> | <time> |

## Evidence

- <error, log, screenshot, failing test, focused diff>

## Hypotheses

1. <hypothesis and falsifiable prediction>
2. <hypothesis and falsifiable prediction>
3. <hypothesis and falsifiable prediction>

## Test Seam

- Correct seam exists: yes/no
- Proposed failing test: <file/test>
- If no seam exists: <architecture finding>

## Recommended Next Step

<diagnosis action or Codex plan step>
```

