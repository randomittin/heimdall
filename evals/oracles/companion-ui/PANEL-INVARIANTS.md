# Job-panel invariants — `hmd ui` Wave 4 (PLAN-companion-ui.md, Decision 6)

Checkable statements transcribed from Decision 6. Each line is something a test
can assert against `bin/lib/companion_ui_panels.py` (the ONE module both the
`hmd ui panel` CLI and `sentinels/hmd-ui.py` import) and against a running
`hmd ui` server. Where a statement names a constant, the constant's name and
value are both normative.

## Location and schema

- P1. A panel is one file: `<repo>/.heimdall/ui/panels/<id>.json`. One writer per
  file; the `id` names its owner (e.g. `<task-id>-progress`).
- P2. Schema: `{"id": str, "title": str, "type": str, "data": object,
  "refresh_s": int?, "updated_at": number}`. `updated_at` is a unix epoch and is
  REQUIRED. Unknown top-level keys other than `source` are tolerated; `source` is
  not (P6).
- P3. `id` MUST match `ID_RE = ^[A-Za-z0-9_-]{1,64}$` (filename-safe; no path
  traversal through the id). The `id` inside the file MUST equal the filename stem.

## Closed type set

- P4. `PANEL_TYPES` is exactly `kv|table|number|timeseries|bars|markdown|log-tail`.
- P5. An unrecognised `type` is REFUSED — the whole panel, nothing written, nothing
  served. A job cannot add an eighth rendering mode.

## `source` is rejected, permanently

- P6. A `source` key (a job-supplied shell command the server would run on refresh)
  anywhere at the top level, or inside `data`, is a HARD validation failure: the
  WHOLE panel is rejected, nothing partial is honoured, nothing is written. Reason
  (RCE): whoever can write a file under `.heimdall/ui/panels/` — any coding agent
  with repo access — would otherwise gain unattended, timer-driven code execution
  as the operator's own user. A job that wants "graph my database" runs its own
  query and publishes the numbers. This is a permanent regression guard, not a
  deferral.

## Per-type `data` shape

- P7. `kv` — `{"rows": [[label:str, value:str|num|bool|null], ...]}`, order-preserving.
- P8. `table` — `{"columns": [str, ...], "rows": [[cell, ...], ...]}`; every row has
  exactly `len(columns)` cells; cells are plain text, never markdown-substituted.
- P9. `number` — `{"value": num|str, "delta": num?, "format": "count"|"duration_s"|"bytes"|"percent"?}`.
- P10. `timeseries` — `{"x": [...], "y": [num, ...]}` or `{"series": [{"name", "x", "y"}, ...]}`;
  `len(x) == len(y)`; y values are finite numbers; at most `MAX_SERIES = 6` series.
- P11. `bars` — `{"labels": [str, ...], "values": [num, ...]}` or the same
  multi-series shape as P10; same `MAX_SERIES = 6` cap.
- P12. `markdown` — `{"text": str}`; rendered by escape-first-then-substitute with
  EXACTLY four substitutions: `**bold**`, `` `code` ``, a leading `- ` line to a
  list item, newline to a line break. No link syntax (`[text](url)` is NOT
  substituted); no raw HTML survives. A literal `<script>` in `data.text` never
  appears unescaped in the DOM.
- P13. `log-tail` — `{"lines": [str, ...]}`, plain text in a `<pre>`, at most
  `MAX_LIST_ITEMS = 200` lines.
- P14. Unknown keys inside `data` are rejected (the per-type shape is closed).

## Size caps (enforced server-side AND at publish time, never trusted from the file)

- P15. `MAX_FILE_BYTES = 65536` per panel file (checked before read and before write).
- P16. `MAX_TITLE_CHARS = 120` (mirrors `bin/heimdall-activity`'s `SCRUB_MAX=120`).
- P17. `MAX_STRING_CHARS = 500` per string leaf inside `data`. One exception, the phone
  app's own (hmdapp `guards.ts` `MAX_CHAT_LINE_CHARS`): each line of the `chat`
  log-tail panel — whole messages, not labels — may carry `MAX_CHAT_LINE_CHARS = 8000`
  characters, its `HH:MM role ` head included. The cap is by panel id: every other
  log-tail, the `hmd-question` text and every title keep 500.
- P18. `MAX_LIST_ITEMS = 200` per list (kv rows, table rows, points per series,
  log-tail lines) — the `bin/lib/watch_data.read_feed(limit=200)` precedent.
- P19. `MAX_SERIES = 6` (dataviz: categorical hues in fixed order, never a generated 7th).
- P20. A panel exceeding any cap is REFUSED whole; nothing is truncated.

## Staleness (flagged, never deleted)

- P21. Every served panel carries `stale: bool` where
  `stale = (now - updated_at) > max(refresh_s * 3, 30)` seconds; a missing
  `refresh_s` counts as 0 (threshold 30s).
- P22. `refresh_s` is advisory: it never alters the server's fixed 2s poll cadence.
- P23. A stale panel is still served and visibly marked; staleness alone never removes it.

## TTL cleanup

- P24. `PANEL_TTL_SECONDS = 86400`: a panel whose `updated_at` age exceeds 24h is
  deleted by the server on its next read (`read_panels`) — a crashed job's tile
  never lingers.
- P25. `hmd ui panel rm <id>` is the clean removal path; the next `/api/state`
  poll no longer lists the id.

## Atomic write, one writer per file

- P26. `write_panel` writes `<id>.json.<pid>.tmp` then `os.replace`s it into
  `<id>.json` — the `bin/heimdall-presence` `.roster-cache.json.<pid>.tmp`
  convention. A reader never observes a half-written file.
- P27. Orphaned `<id>.json.<pid>.tmp` files (age >= 120s, or dead pid) are reaped;
  the live `<id>.json` is never touched by the reaper. Strict filename shape only.

## Secret scrub (reuse, not reinvent)

- P28. Before a panel is written or served, the `title` and EVERY string leaf inside
  `data` (table cells, kv values, markdown text, log-tail lines, series/bar labels,
  string x values — never numeric x/y values) is checked with `secret_shaped()`,
  `bin/heimdall-activity:167-179`'s own pattern family (`secret_shaped` /
  `reject_if_secret`) ported regex-for-regex: assigned-credential shape
  (`token|secret|password|passwd|pwd|api[_-]?key|apikey|access[_-]?key|auth|bearer|credential|private[_-]?key` `=`/`:` opaque RHS of 16+),
  GitHub PAT / other GitHub tokens, AWS access key id, Stripe secret key,
  Slack token, PEM private-key header, JWT.
- P29. A hit REFUSES the whole panel (fail-closed): the CLI exits nonzero and writes
  nothing; the server drops the file from `panels` and logs the field name to
  stderr — never the value.

## Serving contract

- P30. `GET /api/state` and every SSE frame carry a top-level `panels` array of
  `{id, title, type, data, refresh_s, updated_at, stale}`, sorted by id, provenance
  `companion_ui_panels.read_panels()` — never a raw directory listing. `panels` is
  ADDITIVE: the 13 Wave 1 keys are unchanged.
- P31. A missing `.heimdall/ui/panels/` directory yields `panels: []`, never an error.
- P32. The SSE digest covers `panels`: a `hmd ui panel set` produces a frame within
  one poll (2s).
- P33. Only regular files are read from the panels dir; a symlink there is refused
  (it can never make the server read `team.json`, a key, or anything outside).
- P34. `hmd ui --print-sources` lists `<repo>/.heimdall/ui/panels/` among the files
  the server reads; no deny-listed path (team.json, *.key, *.seed, key.pem,
  ~/.omniroute, .env*, settings.json) is ever read to build `panels`.
- P35. The browser renders every type from inline `data` only, by DOM construction
  (`textContent`, `createElement`, SVG built from `Number()`-coerced values); no
  panel-supplied string is ever assigned to `innerHTML`. An unknown type renders as
  "unsupported type" — never blank, never executed.

## Self-published panel

- P36. `hmd ui` itself publishes `hmd-live-users` (`type: number`, `title: "hmd — live
  users"`, `data.value = len(roster)`) from the poll loop, in-process, through the
  same `write_panel` an agent uses — never re-reading `team.json`, never a new
  presence call. It is rewritten when the value changes or its age nears the stale
  threshold, so the SSE stream stays quiet when nothing changes.

## Publish API

- P37. `hmd ui panel set <id> --type <t> --title <s> --data-json <file|-> [--refresh-s N]`
  (`-` reads stdin), `hmd ui panel rm <id>`, `hmd ui panel ls [--json]` — subcommands of
  `bin/heimdall-ui`, dispatched before its server flag parser, exec'ing
  `bin/lib/companion_ui_panels.py` through the same `hmd_python` resolution.
- P38. `set` exits 0 and prints the written path on success; exits 2 with a stderr
  line naming the offending FIELD (never the value) on any rejection, and no file
  is written.

## Serve-side log-tail bound (additive; does not weaken P13/P17/P18/P20 at publish time)

- P39. `write_panel` (the `hmd ui panel set` CLI, P37/P38) is UNCHANGED: a
  log-tail panel whose `data.lines` exceeds `MAX_LIST_ITEMS`, whose file
  exceeds `MAX_FILE_BYTES`, or any of whose lines exceeds its panel's line cap
  (`MAX_STRING_CHARS`; `MAX_CHAT_LINE_CHARS` for `chat`, P17),
  is still REFUSED WHOLE at publish time, exactly as P17/P18/P20 state.
  Nothing below changes what a producer may write through the blessed CLI in
  one shot.
- P40. `read_panels` (the server's own read path — `/api/state`, every SSE
  frame, and the relay state frames, all three sourced from it, P30) applies
  an ADDITIONAL, wider, log-tail-only bound BEFORE validating a file already
  on disk — content that reached disk by some route other than `panel set`
  (P1 says one writer per file; it does not say that writer must be this
  CLI) is no longer required to already fit inside the publish-time caps to
  be served at all: `HMD_UI_LOG_TAIL_LINES` (default 200), `HMD_UI_LOG_TAIL_BYTES`
  (default 65536), `HMD_UI_LOG_LINE_MAX` (default 2000 chars/line, and never
  narrower than the panel's own write-time cap, so a `chat` line of 8000 is
  served whole), each read
  fresh from the environment on every read. A line longer than the char limit
  is cut to exactly that many characters, the last being an ellipsis; the
  list is then trimmed from the OLD end (line 0 first), on whole-line
  boundaries only, until both the line-count and UTF-8-byte-total budgets
  hold. Rationale: a good-faith log that outgrows limits sized for short
  structured job-progress lines, not prose-heavy chat transcripts, should
  degrade to "newest slice, visibly marked", never to nothing.
- P41. When a read-path trim actually drops at least one line, the served
  `data` gains `truncated: true` and `dropped_lines: <n>`; an untouched log
  (nothing dropped) carries neither key, and its `data.lines` is
  byte-identical to what was on disk. Both keys are optional and validated
  the same as any other `data` field (`truncated` a bool, `dropped_lines` a
  non-negative int); an invalid value for either is still a hard rejection.
- P42. The read-path trim runs BEFORE the secret scrub (P28/P29) and BEFORE
  public-mode redaction (`_redact_public`): a secret-shaped string surviving
  inside the KEPT (newest) slice still refuses the WHOLE panel, exactly as
  before; content the trim already dropped from the OLD end is never scanned
  or served, so it can neither leak nor be redacted. Fixed order: trim, then
  scrub, then (if `--allow-host`/public mode) redact.
