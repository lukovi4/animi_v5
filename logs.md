# Current Log Handoff

Raw log dumps were moved out of this tracked, IDE-open file because Codex Desktop
injects active editor context into user prompts when `IDE context` is enabled.

Local archive:

- `.codex-local/logs-archive-2026-05-28.local.md`

Working rule:

- Keep this file short.
- Put large raw logs under `.codex-local/` as `*.local.log` or `*.local.md`.
- Analyze large logs with `rg`, `sed`, and summarized command output.
- Do not paste or keep full raw logs in open IDE tabs while asking Codex to work.

Confirmed cause from saved Codex session:

- Thread `Izuchi novye logi` stored initial user input of about 187 KB.
- A later input grew to about 226 KB.
- Both inputs started with IDE context headers and then embedded raw `[MEM-EVENT]`
  lines from `logs.md`.
