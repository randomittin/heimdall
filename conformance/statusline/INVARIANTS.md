# INVARIANTS — HMD Statusline v1 "Full-bleed Gauge" (4-row: 8×8 sigil anchor)

**Artifact type:** independent correctness reference (invariant ledger).
**Authored:** Wave-0, SEPARATELY from the implementation. The falsifier
(`test/heimdall-statusline-fullbleed.test.sh`) MUST derive its assertions from
THIS document, not from impl-authored goldens. If the impl and this ledger
disagree, this ledger is the correctness authority — the impl is wrong until
the ledger is proven wrong on its own math.

**Subject under test (SUT):** the 4-row statusline render
(`sentinels/hmd-statusline.py` + siblings `hmd_gauge.py`, `hmd_layout.py`,
`hmd_ledger.py`), driven by CC statusLine stdin JSON and
`.heimdall/{status,statusline}.json` ledger state.

**Layout (4 rows: the hero sigil is a perfect 8×8 = 4 half-block rows, so the four content
rows lay out to the RIGHT of sigil rows 1–4 — the full untrimmed sigil shows):**
- **Row1** — identity / model / repo (left) + team sigil-TOPS (right rail).
- **Row2** — the CLEAN usage gauge (per-cell `48;2` bg ramp, NO inside labels), CAPPED to
  reserve a right-side teammate zone (sigil-BOTTOMS); it is NOT full-bleed of the content span.
- **Row3** — gate verdict / live subagent count (left) + teammate NAMES (right rail).
  Permission-mode is DESCOPED (CC renders the bypass footer natively; no statusLine signal).
- **Row4** — the metrics line: left `CTX <pct>% · ↓<tokens>`, right `ctx% · 5h% · 7d% · $cost
  · <reset>` (the numbers moved OFF the Row2 gauge onto their own row), gated by width tier.

**Measurement conventions used throughout:**
- `COLUMNS` = the terminal width the SUT resolves (`resolve_cols`, 80-col
  conservative floor). Falsifier drives it via the `COLUMNS` env var.
- `vis(s)` = printable-cell width of `s` AFTER stripping ANSI SGR sequences
  (regex `\x1b\[[0-9;]*m`) and counting East-Asian-wide glyphs as 2. This is
  the ONLY width that counts; raw `len()` is never the measure.
- `strip(s)` = `s` with all `\x1b\[[0-9;]*m` removed.
- A "row" is one `\n`-delimited output line.
- "warm run" = a render whose 5s session cache is primed (second invocation
  with the same `session_id` inside the TTL window).

---

## INVARIANT LEDGER

Each invariant: **ID** · falsifiable one-line assertion · **Measure** (the exact
mechanical check) · **Known-bad RED** (the mutation that MUST flip it red, so the
check is proven non-tautological).

### ROW-EXACT — every row is exactly COLUMNS printable cells
- **Assertion:** for each emitted row `r`, `vis(r) == COLUMNS`, verified at
  `COLUMNS ∈ {40, 80, 120, 200}` and across all multi-row tiers. The multi-row tiers
  emit 4 rows (the untrimmed 8×8 sigil anchor); the 4th (blank content) row is
  space-padded to COLUMNS and obeys `vis == COLUMNS` like every other row.
- **Measure:** pipe a canned stdin through the SUT under
  `COLUMNS=<w> python3 sentinels/hmd-statusline.py --color`; for every output
  line assert `len(strip(line)) == <w>` (wide-glyph-adjusted). Run for
  `w ∈ {40,80,120,200}`. At `w<40` see WIDTH-TIERS (single line still obeys
  `vis == COLUMNS`).
- **Known-bad RED:** disable `full_bleed_pad` (return the row unpadded) → some
  row `vis != COLUMNS` → RED. Off-by-one the pad (`cols-1`) → RED.

### GAUGE-FILL — Row2 filled width equals rounded percentage of the CAPPED span
- **Assertion:** Row2 filled-cell count `== round(used_percentage/100 × gauge_span)`, where
  `gauge_span` is the CAPPED allotment (NOT `COLUMNS`, NOT the full content span `gw`): the
  gauge reserves a right-side teammate zone. Solo (no team) `gauge_span = min(gw, max(24,
  int(gw × 0.66)))` with `gw = COLUMNS − 10`.
- **Measure:** (a) re-derive `gauge_span` from the SUT's OWN render — the count of Row2 cells
  carrying an active `48;2` bg minus the 8 sigil-anchor cells — and assert it equals the capped
  formula AND `gw − gauge_span > 0` (a reserved right zone). (b) feed
  `context_window.used_percentage = p`; count the leading run of filled (ramp `48;2`) cells vs
  the dim empty track and assert `count == round(p/100 × gauge_span)` for
  `p ∈ {0, 1, 50, 69, 70, 89, 90, 100}` at each `COLUMNS`. Round-half-up per the spec `round()`,
  NOT floor.
- **Known-bad RED:** replace `round()` with `int()`/floor → fractional cases diverge (e.g.
  `p=1, gauge_span=72` → round 1 vs floor 0) → RED. Remove the cap (gauge full-bleed = `gw`) →
  the SUT's real-render span `≠` the capped formula and `gw − gauge_span = 0` → RED.

### GAUGE-RAMP — base ramp fills the whole bar + TIP-ONLY danger + empty track
- **Assertion:** the BASE ramp `#1E2F73 → #4264FF → #5AD7E6` (default) — or
  `dark → accent → bright` derived from the user's OWN sigil VIVID accent
  (`sigil_accent_color`) — fills the WHOLE filled region, so the FIRST filled cell is the
  dark ramp start (`#1E2F73` for the default) for EVERY pct band. The gold/red danger
  does NOT remap the whole ramp: it tints ONLY the last `TIP_CELLS` (~3) filled cells
  toward gold (`pct ≥ 70`) / red (`pct ≥ 90`) as a per-cell blend that is FULL danger at
  the very tip and fades to the base ramp inward — so the bar reads mostly in its identity
  hue with a small danger tip (e.g. batsy at 81% = mostly BLUE, small GOLD tip). The
  unfilled remainder renders a dim empty-track stripe (present, never blank/space-collapsed).
- **Measure:** parse Row2 `48;2;R;G;B` codes. (a) first filled cell ≈ `#1E2F73` (the base
  ramp start) for ALL of `pct ∈ {50, 70, 90}` — the whole-ramp remap is GONE, so `pct=70`
  no longer starts at blue. (b) tip cell bg is gold-class iff `70 ≤ pct < 90`, red-class
  iff `pct ≥ 90`, ramp-bright otherwise (at the very tip the blend is 1.0 → exactly
  gold/red). (c) at `pct < 100` at least one trailing cell carries the dim empty-track bg
  (distinct from ramp + from terminal default). Check `pct ∈ {50, 70, 90}`.
- **Known-bad RED:** swap the 70/90 thresholds → gold appears at `pct=90` instead of red
  → RED. Remap the WHOLE ramp on danger (the old behavior) → `pct=70` first cell is blue,
  not dark → RED. Drop the empty-track fill → trailing cells go bare → RED.

### GAUGE-LABELS — the gauge is CLEAN; the metric labels live on Row4, gated by width
- **Assertion:** the Row2 gauge carries NO text at ANY tier (a clean `48;2` bg bar — the
  numbers moved OFF it). The metric labels live on **Row4**: left `CTX <pct>% · ↓<tokens>` and
  right `ctx% · 5h% · 7d% · $<cost> · <reset>`. The right cluster shows at `full` only; at
  `mid`/`narrow` Row4 is the LEFT `CTX`/tokens only. `tiny` (<40) has no Row4 (one line).
- **Measure:** feed a fixed stdin with known tokens/cost/dur. On Row2 `strip()` and assert it
  contains neither `CTX` nor `$` (clean bar) at `w ∈ {48, 80, 120}`. On Row4 `strip()`:
  `full`(120) → contains `CTX` AND the right `$` cluster; `mid`(80) & `narrow`(48) → contains
  `CTX`, does NOT contain the right `$` cluster.
- **Known-bad RED:** always-draw the right cluster → `$` present on Row4 at `w=80` → RED.
  Splice a label onto the gauge → `CTX`/`$` appears on Row2 → RED. Never-draw `CTX` at `w=120`
  → RED.

### NULL-SAFE — absent/null fields render NOTHING, never a fabricated zero
- **Assertion:** (a) `used_percentage` null/absent → gauge treats it as `0`
  (empty bar), NOT a crash; (b) `rate_limits` absent → the limit segment(s) are
  OMITTED entirely (the Row4 `5h`/`7d` readouts vanish — no `0%`, no placeholder);
  (c) `workspace.repo` absent → Row1 shows the `current_dir` basename with NO branch/`:worktree`
  suffix. No field is ever fabricated from a missing source.
- **Measure:** three canned inputs. (a) stdin with `context_window` lacking
  `used_percentage` → SUT exits 0, Row2 fill `== 0`. (b) stdin with no
  `rate_limits` key → Row4 contains neither a `5h` nor a `7d` token (the limit readouts moved
  OFF Row1 onto the Row4 metrics rail; no fabricated `0%`).
  (c) stdin with `workspace.current_dir` set but no `repo` → Row1 contains
  `basename(current_dir)` and does NOT contain a branch glyph/`:` worktree join.
- **Known-bad RED:** default a missing `rate_limits` to `0%` → the `0%` token
  appears → RED. Emit a branch for a repo-less dir → RED.

### WIDTH-TIERS — four tiers select content density
- **Assertion:** `width_tier(COLUMNS)` = `full` (≥100) · `mid` (60–99) ·
  `narrow` (40–59) · `tiny` (<40), and the render obeys:
  - `full` — all four rows, all segments (incl. the Row4 right `$` cluster + the team rail).
  - `mid` — team sigil rail kept; Row4 drops to the LEFT `CTX`/tokens only (no right `$`).
  - `narrow` — drop the Row1/Row3 team rail; Row4 = LEFT `CTX`/tokens only (no right `$`).
  - `tiny` — ONE line, exactly `HMD <pct>% <gates>`.
- **Measure:** for representative widths `{120, 80, 48, 30}` assert the row
  count (`wc -l`) is `4, 4, 4, 1` respectively (the multi-row tiers emit the full
  untrimmed 8×8 sigil = 4 rows); and per-tier content greps:
  `mid`(80) → Row4 has `CTX` but not the right `$` cluster; `narrow`(48) → Row4 still has
  `CTX` (left-only) and no right `$`; `tiny`(30) → single line matching
  `^HMD [0-9]+% ` (and still `vis == COLUMNS`, see ROW-EXACT).
- **Known-bad RED:** shift a boundary (e.g. `≥90` for full) → `w=95` renders the
  full rail → RED. Emit 3 rows at `w=30` → `wc -l != 1` → RED.

### ANSI-BUDGET — bounded color changes per row
- **Assertion:** the count of distinct `48;2` (bg) SGR emissions on Row2 is
  `≤ ceil(COLUMNS/40) + 2` — the ramp quantizes, emitting a new bg only every
  `ceil(COLUMNS/40)` cells (plus the ≤2 tip/track boundary changes); i.e.
  `≤ ~40 color changes/row` at the widest supported widths.
- **Measure:** on Row2, count `48;2;` occurrences; assert
  `count ≤ ceil(COLUMNS/40) + 2` for `COLUMNS ∈ {40,80,120,200}`. (At 120 →
  `ceil(3)+2 = 5` distinct bg segments max.)
- **Known-bad RED:** recolor every cell (per-cell `48;2`) → count ≈ COLUMNS ≫
  budget → RED.

### FALLBACK — degrade without crashing
- **Assertion:** (a) empty OR malformed stdin → the SUT prints the
  `⛭ HEIMDALL` fallback line and exits 0; (b) ledger file
  (`.heimdall/status.json` and legacy `statusline.json`) missing → Row3 renders
  offline/neutral gate state with NO crash and NO stack trace.
- **Measure:** (a) `printf '' | python3 sentinels/hmd-statusline.py; echo $?`
  → output contains `HEIMDALL`, exit `0`; `printf '{bad json' | … ; echo $?`
  → same. (b) run in a cwd with no `.heimdall/` → exit 0, Row3 present, stderr
  empty (see EXIT).
- **Known-bad RED:** let `json.loads` raise uncaught → malformed stdin exits
  non-zero / prints a traceback → RED.

### PERF — warm render under budget
- **Assertion:** a warm render (cache primed for the same `session_id`) completes
  in `< 50 ms` wall; cold `< 80 ms`.
- **Measure:** prime the cache (one render with `session_id=t`), then time a
  second render with the same `session_id`; assert median-of-N wall `< 50 ms`.
  Cold: fresh `session_id`, assert `< 80 ms`.
- **Known-bad RED:** disable the 5s session cache → the warm path re-does the
  full render/forks → median exceeds 50 ms → RED (on a machine where the cold
  path is already near budget).

### EXIT — always exit 0, clean stderr
- **Assertion:** for EVERY input (valid, empty, malformed, missing-ledger,
  every width) the process exits `0` and writes NOTHING to stderr.
- **Measure:** across the full input matrix,
  `… python3 sentinels/hmd-statusline.py 2>err; echo $?` → `0` AND
  `test ! -s err` (stderr empty). A statusline that exits non-zero or prints to
  stderr corrupts the CC status bar.
- **Known-bad RED:** any uncaught exception, or a stray
  `print(..., file=sys.stderr)` / debug log → RED.

### SIGIL-KEEP — the hero sigil stays as the left anchor (RJ override of spec §8)
- **Assertion:** the user's OWN hero sigil — the current 58-hero `▄` 8×8 render
  (`hmd_sigil.py`) — REMAINS the left anchor of the statusline. It is NOT retired
  and NOT replaced by the `▟█▙` brand glyph. TEAMMATES render as the compressed
  1-row micro mark. The content lays out to the RIGHT of the sigil; Row2's
  gauge fills its CAPPED allotment to the right of the sigil (it reserves a right-side
  teammate zone — it is NOT full-bleed of `COLUMNS − sigil_width`; see GAUGE-FILL), and
  ROW-EXACT proves the anchor + gauge + reserved zone together fill the line exactly).
- **Rationale:** RJ override of spec §8, which proposed retiring the 4-row hero
  block in favor of `▟█▙`. The hero sigil is the user's identity mark and stays;
  only teammates compress to the micro mark. The `hmd_sigil.py` 58-hero system
  and its 9 goldens (`conformance/statusline/goldens/sigil/*`) are byte-untouched
  by this work.
- **Measure:** (a) SELF render contains the multi-cell hero sigil block as the
  left anchor (the `▄`/8×8 render, NOT a lone `▟█▙`); the sigil goldens diff
  clean: `git diff --quiet conformance/statusline/goldens/sigil/`. (b) a teammate
  entry renders the 1-row micro mark, not the full hero block. (c) Row2's ramped
  span begins after the sigil anchor and is CAPPED (a right teammate zone reserved), and
  `vis(Row2) == COLUMNS` still holds (anchor + capped gauge + zone + pad fill the line).
- **Known-bad RED:** replace the self anchor with `▟█▙` → the hero sigil block is
  absent from the SELF render → RED. Any modification to `hmd_sigil.py` that
  dirties the sigil goldens → `git diff --quiet …/sigil/` fails → RED.

---

## COVERAGE MAP — spec §2–§8 → invariant IDs

Maps each spec section to the invariant(s) that make it falsifiable. Gaps and
overrides are called out so a reviewer sees what is/ isn't enforced.

| Spec § | Topic | Invariant IDs | Notes |
|---|---|---|---|
| §2 | Row1 identity / team / rate-limit | ROW-EXACT · NULL-SAFE · WIDTH-TIERS · SIGIL-KEEP | team names drop at `narrow`; the rate-limit readout moved to the Row4 metrics rail; sigil is the left anchor. |
| §3 | Row2 gauge (fill / ramp / tips / budget) + Row4 metric labels | GAUGE-FILL · GAUGE-RAMP · GAUGE-LABELS · ANSI-BUDGET · ROW-EXACT | the gauge is CAPPED (reserves a right teammate zone, NOT full-bleed); metric labels moved OFF the bar onto Row4. |
| §4 | Row3 gate verdict / permission-mode / subagent count | ROW-EXACT · FALLBACK · WIDTH-TIERS | permission-mode is DESCOPED (no CC stdin signal) — expected-red / omitted, not covered by a green invariant. |
| §5 | Width tiers (≥100 / 60–99 / 40–59 / <40) | WIDTH-TIERS · ROW-EXACT · GAUGE-LABELS | tier boundaries + the `<40` single-line `HMD <pct>% <gates>`. |
| §6 | Null / absent-field handling | NULL-SAFE · FALLBACK · EXIT | never fabricate a `0%`/`$0`; degrade, don't crash. |
| §7 | Robustness / perf / exit discipline | FALLBACK · PERF · EXIT · ANSI-BUDGET | warm `<50ms`, always exit 0, clean stderr, bounded SGR. |
| §8 | Sigil anchor | **SIGIL-KEEP** | RJ OVERRIDE of §8: hero sigil KEPT as left anchor (NOT retired, NOT `▟█▙`-replaced); teammates use the micro mark. |

**Uncovered-by-design:** permission-mode (§4) — no signal from CC statusLine
stdin; descoped to expected-red until a research spike finds a source. `daemon`
liveness — literal `false` (no daemon exists); informational only.
