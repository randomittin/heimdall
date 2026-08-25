# Can hmd detect 529/overload events from its own session transcripts?

Date: 2026-08-25
Task: DELTA BRIEF `brief-1787625854-46016`
Scope: read-only investigation + (conditional) build of `bin/heimdall-529-scan`

## The claim under test

`bin/lib/pressure_control.py` documents an honest ceiling: hmd cannot see the
harness's live HTTP responses, so it only ever learns of a 529/connection-reset
via `record_event()` being called by some external observer — an agent
noticing its own death, a wrapper script noticing a failed call. That's true
for in-process Agent-tool spawns. This doc answers a narrower question: can
Claude Code's own **session transcripts** (`~/.claude/projects/<slug>/*.jsonl`)
serve as that external observer instead? Three gating sub-questions, per the
brief:

1. Do overload/rate-limit events appear in transcripts at all, with a knowable
   record shape?
2. Are they identifiable by a **stable field** (type/boolean), or only by
   fragile regex over prose?
3. Are they attributable to a **timestamp**, supporting a since-marker design?

All three are answered with commands actually run against this repo's real
corpus at `~/.claude/projects/-Users-rj-Downloads-heimdall/`. No count or
example below is invented.

## Corpus measured

```
$ ls ~/.claude/projects/-Users-rj-Downloads-heimdall/*.jsonl | wc -l
119
$ du -sh ~/.claude/projects/-Users-rj-Downloads-heimdall/
510M
```

## Finding 1 — yes, a stable structured marker exists

Claude Code writes a synthetic (`model:"<synthetic>"`) assistant-role JSONL
record into the transcript the moment an API call fails, carrying three
top-level fields: `isApiErrorMessage` (bool), `apiErrorStatus` (int or null),
and `error` (a closed string enum). Full corpus breakdown:

```
$ jq -c 'select(.isApiErrorMessage==true) | {error, apiErrorStatus}' \
    ~/.claude/projects/-Users-rj-Downloads-heimdall/*.jsonl 2>/dev/null \
    | sort | uniq -c | sort -rn
  52 {"error":"rate_limit","apiErrorStatus":429}
  12 {"error":"server_error","apiErrorStatus":null}
   5 {"error":"oauth_org_not_allowed","apiErrorStatus":403}
   2 {"error":"server_error","apiErrorStatus":529}
   1 {"error":"server_error","apiErrorStatus":502}
```

72 structured records total (52+12+5+2+1), cross-checked:

```
$ jq -c 'select(.isApiErrorMessage==true)' \
    ~/.claude/projects/-Users-rj-Downloads-heimdall/*.jsonl 2>/dev/null | wc -l
72
```

One full real 529 record (this repo's own history — nothing redacted beyond
what's shown; no secrets present in the record itself beyond a local loopback
address):

```json
{"parentUuid":"23a40943-23f7-4eb5-9b51-f97b2557560c","isSidechain":false,"type":"assistant","uuid":"507c3874-8764-4fcd-b9bf-4b3646839463","timestamp":"2026-08-24T05:34:02.808Z","message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","type":"message","content":[{"type":"text","text":"API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (127.0.0.1:8787)."}]},"requestId":"req_011CeM2FL1UdMH6NL1JxmXrT","error":"server_error","isApiErrorMessage":true,"apiErrorStatus":529,"sessionId":"01313446-ae34-4e0c-9f91-4ef0bd66593c","cwd":"/Users/rj/Downloads/heimdall","version":"2.1.241"}
```

The other 529 (same session, `requestId":"req_011CeM7sT7hMzENfYSdsPdWu"`,
`timestamp":"2026-08-24T06:48:04.720Z"`) has the identical shape.

**This is a stable field, not prose to regex over.** `isApiErrorMessage`,
`error`, and `apiErrorStatus` are structural JSON keys Claude Code itself
writes — the human-readable sentence in `message.content[0].text` is
incidental; nothing here depends on parsing that sentence.

## Finding 2 — naive text search over the same corpus is worthless

Proof, not assertion. A raw text search for the literal string
`"overloaded_error"` (the exact `pressure_control.PRESSURE_KINDS` value one
might naively `grep` for) across the same corpus:

```
$ grep -o "overloaded_error" ~/.claude/projects/-Users-rj-Downloads-heimdall/*.jsonl 2>/dev/null | wc -l
162
$ grep -l "overloaded_error" ~/.claude/projects/-Users-rj-Downloads-heimdall/*.jsonl 2>/dev/null | wc -l
7
```

162 raw hits across 7 files. Inspecting one file's matches with context:

```
$ grep -o '.\{0,40\}overloaded_error.\{0,40\}' \
    ~/.claude/projects/-Users-rj-Downloads-heimdall/2769353c-a61c-4120-b2f3-280718c7cfca.jsonl
2}\" ]; then\n+      echo \"Overloaded (overloaded_error, 529) · Retrying in 5s\" >&2; exit 1\n+
```

That match is a **shell-script diff embedded in a `cat`/tool-result blob from
an earlier session that was building the retry-wrapper feature itself** — not
a real API error. Confirming the same file has zero structured records:

```
$ jq -c 'select(.isApiErrorMessage==true)' \
    ~/.claude/projects/-Users-rj-Downloads-heimdall/2769353c-a61c-4120-b2f3-280718c7cfca.jsonl | wc -l
0
```

And the other direction: the 3 real `apiErrorStatus>=500` records in this
corpus (2×529 + 1×502) do **not** contain the literal string
`"overloaded_error"` anywhere in their own JSON — they carry
`"error":"server_error"` plus a numeric `apiErrorStatus`, nothing else. So a
regex keyed on that literal string would have produced 162 false positives
**and** missed all 3 real events it was meant to find. Any naive-text-search
design is disqualified by measurement, not by suspicion.

## Finding 3 — timestamps are reliable and support a since-marker design

```
$ jq -c 'select(.isApiErrorMessage==true) | .timestamp' \
    ~/.claude/projects/-Users-rj-Downloads-heimdall/*.jsonl 2>/dev/null | sort | sed -n '1p;$p'
"2026-07-24T00:27:38.343Z"
"2026-08-24T14:08:51.980Z"
```

ISO-8601, millisecond precision, `Z`-suffixed, present on every record
measured — a month-long span. Per-day distribution of all 72 records shows
real burst clustering (consistent with genuine platform-load incidents, not
noise spread evenly through time):

```
$ jq -r 'select(.isApiErrorMessage==true) | .timestamp[0:10]' \
    ~/.claude/projects/-Users-rj-Downloads-heimdall/*.jsonl 2>/dev/null | sort | uniq -c
   1 2026-07-24     1 2026-07-25     1 2026-07-28     2 2026-08-02
   1 2026-08-03     1 2026-08-05     2 2026-08-06     4 2026-08-07
   2 2026-08-08     4 2026-08-10    14 2026-08-11    10 2026-08-18
   3 2026-08-19    10 2026-08-20     3 2026-08-21     8 2026-08-22
   1 2026-08-23     4 2026-08-24
```

A time-window (`--window-secs`, default 300s) or absolute (`--since`) cutoff
is sufficient to bound work without needing a persistent cursor file.

## Decision: BUILD

All three gating sub-questions are yes. `bin/heimdall-529-scan` was built.

### Classification (Claude Code's error taxonomy → `pressure_control.PRESSURE_KINDS`)

| `isApiErrorMessage` | `error`                 | `apiErrorStatus` | → kind              |
|----------------------|--------------------------|-------------------|----------------------|
| not `true`           | —                        | —                 | ignored              |
| `true`                | `rate_limit`             | 429               | ignored (not capacity) |
| `true`                | `oauth_org_not_allowed`  | 403               | ignored (not capacity) |
| `true`                | `server_error`           | `null`            | `connection_reset`  |
| `true`                | `server_error`           | ≥500              | `overloaded_error`  |

`rate_limit` and `oauth_org_not_allowed` are deliberately excluded: neither
reflects backend capacity pressure, and counting them would corrupt the AIMD
controller's signal (a 429 means "you personally are asking too fast," a 403
means "your org isn't entitled to this," neither means "the fleet is
overloaded"). Applying this mapping to the corpus above: 3 `overloaded_error`
(2×529 + 1×502) + 12 `connection_reset` = **15 real pressure events** the tool
can see, out of 72 total API-error records, correctly excluding the other 57
(52 rate_limit + 5 oauth).

### What was built

- `bin/heimdall-529-scan` — read-only, idempotent CLI (`scan`, `where`
  subcommands). Never calls `heimdall-pressure record` itself (stated in its
  own header) — wiring the two together is a decision left to a future
  caller, not made here. Bounded work via `--since`/`--window-secs` (default
  300s, env `HMD_529_SCAN_WINDOW_SECS`) plus a per-file mtime pre-filter that
  skips a stale file without opening it. Never-fails contract matching
  `bin/heimdall-pressure`/`bin/heimdall-metric`: missing directory,
  unreadable file, or malformed JSON line all degrade to "skip and keep
  going" at exit 0, never a crash, unless `--strict` is passed.
- `test/heimdall-529-scan.test.sh` — 13 cases, fixture-only (hand-built
  `.jsonl` files under a throwaway `mktemp -d`, never real transcripts).
  Verified: `13 passed, 0 failed`, exit 0.

### Found but intentionally not fixed / not in scope

- The 162 false-positive text hits above point at an actual, mildly wasteful
  pattern in how prior sessions worked (pasting large source diffs into tool
  results that then live forever in the transcript) — not a bug, not this
  task's scope, and not something this read-only scanner should touch.
- This tool does not itself feed `heimdall-agent-resume` or `agent-pool`;
  those files were explicitly out of scope for this task (owned by other
  agents in this wave). If a future caller wants transcript-derived pressure
  events flowing into the AIMD controller, the natural seam is
  `heimdall-529-scan scan --json | ...` piped into per-event
  `heimdall-pressure record --kind <event.kind>` calls — deliberately left
  as a follow-up, not built here, per the brief's explicit non-goal.
- `resolve_dir()`'s slug reconstruction of Claude Code's own
  `~/.claude/projects/<slug>` naming is a best-effort guess at an
  undocumented internal convention (verified only against this one repo's
  own directory), not a stable contract — `bin/heimdall-529-scan`'s own
  header flags this, and `--dir` exists specifically to bypass it.
