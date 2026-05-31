# Animi Agent Domain Notes

This file is a glossary for AI agents. It is not a product spec, task plan, or scratchpad.

## Purpose

Use this file to keep Codex and Claude consistent when discussing Animi concepts.

Add terms only when they reduce ambiguity across tasks.

## Current Terms

| Term | Meaning |
|---|---|
| Preview | The in-app rendering path the user sees while editing or playing a scene. |
| Export | The rendering path that produces final output. Preview and export must stay behaviorally aligned when timing/rendering changes. |
| Timeline mode | Editing/preview path focused on timeline behavior. Check with scene-edit mode when shared rendering or timing code changes. |
| Scene-edit mode | Editing path for scene/block-level changes. Check with timeline mode when shared behavior can diverge. |
| Active scene | In timeline behavior, the scene currently selected and resolved at the playhead. Exact selection semantics must be verified in current code before changing focus/playhead behavior. |
| UserMedia | User-provided media assets and services used by the editor/player. |
| Trim / playback window | Media timing bounds that affect still extraction and playback behavior. |
| TVECore runtime | Runtime playback/rendering layer that must stay independent from compiler and source parsing code. |

## Rules

- Do not put task requirements here.
- Do not put implementation plans here.
- Do not record temporary assumptions here.
- Use ADRs later for hard-to-reverse architecture decisions.
