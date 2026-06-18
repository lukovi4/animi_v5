# Owner Approval 001

Status: **APPROVED by product owner**

Approved on: 2026-06-12

## What is already fixed

- The new engine is completely separate from the current product.
- The current engine is not modified.
- Tests use real Animi templates from the beginning.
- There is no product UI during initial development.
- Every result is measured, logged and compared.

## Proposed foundation

The product owner approved these five points:

1. **Separate engine module.**  
   Create `AnimiEngineNext` as an isolated part of the repository. It cannot
   call the current playback or export engine.

2. **Small device test application.**  
   Create a blank technical application used only to run tests on real iPhones.
   It is not a product UI.

3. **Use current template files as test inputs.**  
   The new engine reads existing compiled templates through a separate adapter.
   The current template renderer is not treated as the new engine.

4. **One authority for every visible frame.**  
   Individual videos cannot update the screen themselves. The engine assembles
   and validates the whole frame before publishing it.

5. **Evidence system first.**  
   Before implementing video playback, create configuration, logs, measurements
   and result comparison so later choices are proven rather than guessed.

## What this approval does not choose

It does not choose:

- VideoToolbox or AVFoundation;
- decoder count;
- proxy codec;
- cache format;
- performance thresholds;
- supported iPhone tiers.

Those decisions remain blocked until comparative device tests exist.

## Authorized next action

Claude Code may prepare the implementation plan for Task 001. Code changes begin
only after the technical lead reviews that plan. It may create only the isolated
skeleton, configuration and evidence system. It may not implement the media
engine.
