#!/usr/bin/env bash
# heimdall-statusline-panel-floor.test.sh — the LEFT CONTENT PANEL is the fixed-cost
# anchor; the TEAM WALL is the elastic one.
#
# THE BUG THIS EXISTS TO PREVENT, found in a screenshot of a ~200-col terminal with nine
# teammates on the wall:
#
#   team_zone_alloc reserved the team zone FIRST from the right edge and handed the panel
#   whatever was left. Nine 15-cell columns is 9*15 + 8*2 = 151 cells, so on a 200-col
#   terminal the panel got inner(191) - 151 - 4 = 36 cells. At 36 cells the Row4
#   rate-limit gauges no longer fit (they need 44), so micro_row's `avail` self-downgrade
#   fired and Row4 rendered as PLAIN TEXT — `5h 1% ·5h │ 7d 22%` — on the widest terminal
#   the user owns. The Row3 gate row dropped its details for the same reason.
#
# A wider terminal MUST NOT degrade the panel. Two changes, coupled through the one width
# budget and therefore gated together here:
#
#   FIX 1  the panel's TIER PROMISE is reserved BEFORE the team zone. The team then gets
#          the leftover and folds whole members into `+N` (it never slices a sigil).
#   FIX 2  each teammate costs 10 cells instead of 15 (a 4-cell eye_strip_mini + an 8-cell
#          label, right-aligned), so nine of them cost 106 cells instead of 151 — which is
#          where FIX 1's headroom comes from.
#
# Measured, so the coupling is on the record rather than assumed: the two carry DIFFERENT
# halves of the outcome. The FLOOR is what keeps Row4's bars at 100–160c (10c columns alone
# still render TEXT at every one of those widths); the MINI STRIP is what keeps teammates
# out of `+N` (at 200c the floor alone still folds one of nine away). Neither alone is the
# fix, which is why they ship together and are gated together.
#
# THE `avail` SELF-DOWNGRADE IS NOT DELETED. It is the correct last resort on a genuinely
# narrow terminal, and section 5 proves it still fires there. What must stop is it firing
# at 200 columns.
#
#   --prove-red   MUTATION harness: restore the team-first order and the 15-cell column and
#                 prove each property flips RED. A gate that cannot fail is a false green.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"

MODE=render
case "${1:-}" in
  "") ;;
  --prove-red) MODE=prove-red;;
  *) echo "usage: $0 [--prove-red]"; exit 2;;
esac

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

# ── a hermetic 9-teammate workspace: the WALL cache is the only roster source that is
# not capped at 3, which is why RJ's screenshot had nine columns. ──
WS="$(mktemp -d)"; HOMED="$(mktemp -d)"; TMPD="$(mktemp -d)"; HMDH="$(mktemp -d)"
trap 'rm -rf "$WS" "$HOMED" "$TMPD" "$HMDH"' EXIT
mkdir -p "$WS/.heimdall" "$HMDH/ledger"
printf '%s\n' '{"handle":"rj","seed":"rj","created":0}' > "$WS/.heimdall/identity.json"
printf '%s\n' '[
 {"handle":"akshat","haid":"haid:akshat.m1-a1b2","tier":"online","branch":"feat/checkout","last_seen_ts":1785869495},
 {"handle":"priyadharshan","haid":"haid:priya.m1-c3d4","tier":"online","branch":"fix/webhook","last_seen_ts":1785869490},
 {"handle":"ravikiran2904","haid":"","tier":"away","last_seen_ts":1785860000,"last_branch":"fix/mdr"},
 {"handle":"ravikiranuo","haid":"","tier":"contributed","last_commit_ts":1785700000,"last_branch":"main"},
 {"handle":"tejashwini","haid":"","tier":"contributed","last_commit_ts":1785600000},
 {"handle":"viveksuperpe","haid":"","tier":"member"},
 {"handle":"harshal","haid":"","tier":"member"},
 {"handle":"madhavan","haid":"","tier":"member"},
 {"handle":"chsaikrishna123","haid":"","tier":"member"}
]' > "$WS/.heimdall/.wall-cache.json"
printf '%s\n' '{"session_id":"wall9","gates":[
 {"id":"secrets","state":"pass","detail":""},
 {"id":"tests","state":"pass","detail":"41/41"},
 {"id":"designmatch","state":"pass","detail":".91"}
],"team":[],"team_overflow":0}' > "$HMDH/ledger/status.json"

STDIN_JSON="$(printf '{"workspace":{"current_dir":"%s","repo":{"name":"heimdall","branch":"statusline-v1"}},"model":{"display_name":"Opus 4.8"},"context_window":{"used_percentage":58,"total_input_tokens":128000},"session_id":"wall9","cost":{"total_cost_usd":1.25,"total_duration_ms":3840000},"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1785887500},"seven_day":{"used_percentage":22}}}' "$WS")"

render() {   # render() <cols> — the real script, real wall, real ledger
  printf '%s' "$STDIN_JSON" | env -i PATH="$PATH" HOME="$HOMED" \
      HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID=rj HMD_NOW=1785869500 \
      HEIMDALL_HOME="$HMDH" HEIMDALL_CP_URL="http://127.0.0.1:1" \
      COLUMNS="$1" LANG=en_US.UTF-8 HMD_STATUSLINE_TMP="$TMPD" \
      HMD_STATUSLINE_RESERVE=0 HEIMDALL_STATUSLINE_MODE=truecolor python3 "$SL"
}

PY="$(mktemp -t panelfloor.XXXXXX.py)"
trap 'rm -rf "$WS" "$HOMED" "$TMPD" "$HMDH" "$PY"' EXIT
cat > "$PY" <<'PYEOF'
import importlib.util, sys, os, re
SLP, MODE = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.dirname(SLP))
os.environ.setdefault("HEIMDALL_STATUSLINE_MODE", "truecolor")
os.environ.setdefault("COLUMNS", "200")
spec = importlib.util.spec_from_file_location("sl", SLP)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
L, G = m.LAYOUT, m.GAUGE
import hmd_sigil as SIG

ANSI = re.compile(r"\033\[[0-9;]*m")
FILL, TRACK = "▓", "░"
NOW = 1785869500
DATA = {"rate_limits": {"five_hour": {"used_percentage": 1, "resets_at": 1785887500},
                        "seven_day": {"used_percentage": 22}}}
GATES = [{"id": "secrets", "state": "pass", "detail": ""},
         {"id": "tests", "state": "pass", "detail": "41/41"},
         {"id": "designmatch", "state": "pass", "detail": ".91"}]
P = [0]; F = [0]
def ok(s): P[0] += 1; print("  ok   " + s)
def bad(s): F[0] += 1; print("  FAIL " + s)

def budgets(cols, n=9, member_w=None, floor=None):
    """The allocation main() makes at `cols` for `n` teammates, plus what each row NEEDS."""
    tier = L.width_tier(cols)
    inner = cols - 9
    gauge_max, bar_w = m._gauge_max_for(tier), m._bar_w_for(tier)
    want = m.panel_floor(tier, DATA, NOW, GATES, "s", 3840000) if floor is None else floor
    kw = {"rows_gap": m.TEAM_COL_GAP, "content_floor": want}
    if member_w is not None:
        kw["member_w"] = member_w
    if tier in ("full", "mid"):
        cb, tw, shown, of, _g = L.team_zone_alloc(cols, n, 0, **kw)
    else:
        cb, tw, shown, of = inner, 0, 0, n
    r4_need = m.vis(m.micro_row(DATA, NOW, bar_w, "s", 3840000, avail=None))
    r4_got = m.micro_row(DATA, NOW, bar_w, "s", 3840000, avail=cb)
    r3_need = m.vis(m.gate_labels(GATES, None, colored=True))
    r3_got = m.gate_labels(GATES, cb, colored=True)
    return dict(tier=tier, inner=inner, floor=want, cb=cb, tw=tw, shown=shown, of=of,
                gauge_w=max(0, min(gauge_max, cb)), gauge_max=gauge_max,
                r4_need=r4_need, r4_bars=FILL in r4_got or TRACK in r4_got,
                r3_need=r3_need, r3_full=r3_got == m.gate_labels(GATES, None, colored=True))

if MODE == "prove-red":
    print("== --prove-red: each known-bad MUST flip its property RED ==")
    # The two fixes carry DIFFERENT halves of the outcome, measured not assumed:
    #   the FLOOR is what keeps Row4's bars at 100–160c (the widths real terminals sit at);
    #   the MINI STRIP is what keeps teammates out of `+N`.
    # Neither alone covers both, which is why they ship coupled — and why the known-bads
    # below plant them separately and name exactly which property each one flips.
    #
    # KNOWN-BAD 1 — the shipped order: reserve the team FIRST, panel takes the leftover
    # (content_floor == the bare gauge minimum). Note 200c is NOT in this list: with 10c
    # columns nine members leave 81c there even without the floor, so claiming the floor
    # flips 200 would be asserting something false to make a gate look stronger.
    for cols in (160, 130, 100):
        b = budgets(cols, floor=L.GAUGE_MIN_W)
        (ok if not b["r4_bars"] else bad)(
            "prove-red FLOOR@%d: team-first alloc leaves the panel %dc (needs %dc) → Row4 is TEXT (RED)"
            % (cols, b["cb"], b["r4_need"]))
    # KNOWN-BAD 2 — the 15-cell column: nine members eat 151 cells again.
    old = 9 * 15 + 8 * L.TEAM_MEMBER_GAP
    (ok if old > 9 * L.TEAM_MEMBER_W + 8 * L.TEAM_MEMBER_GAP else bad)(
        "prove-red WIDTH: the 15c column costs %dc for 9 members vs the real %dc (RED)"
        % (old, 9 * L.TEAM_MEMBER_W + 8 * L.TEAM_MEMBER_GAP))
    b = budgets(200, member_w=15, floor=L.GAUGE_MIN_W)
    (ok if not b["r3_full"] else bad)(
        "prove-red GATES@200: the 15c column + team-first leaves %dc (needs %dc) → details DROP (RED)"
        % (b["cb"], b["r3_need"]))
    # KNOWN-BAD 3 — the 15c column costs a VISIBLE TEAMMATE even once the floor is in:
    # the wall folds one into `+N` at 200c that the 10c column shows. This is the half of
    # the outcome the floor cannot buy, so it needs its own known-bad.
    wide, real = budgets(200, member_w=15), budgets(200)
    (ok if wide["shown"] < real["shown"] == 9 else bad)(
        "prove-red COUNT@200: the 15c column shows only %d of 9 (+%d) where the real 10c shows %d (RED)"
        % (wide["shown"], wide["of"], real["shown"]))
    # KNOWN-BAD 3 — an 8-cell strip in a 10-cell column overruns the column grid.
    (ok if 8 > L.TEAM_MEMBER_W - L.TEAM_LABEL_W + L.TEAM_STRIP_W else bad)(
        "prove-red GRID: an 8c strip does not fit the %dc column beside a %dc label (RED)"
        % (L.TEAM_MEMBER_W, L.TEAM_LABEL_W))
    print("\n  %d passed, %d failed" % (P[0], F[0]))
    sys.exit(0 if F[0] == 0 else 1)

# ── 1) GEOMETRY: the column is the smallest that fits the label AND the strip ────
(ok if L.TEAM_STRIP_W == SIG.EYE_STRIP_MINI_W == 4 else bad)(
    "GEOMETRY: TEAM_STRIP_W(%d) == EYE_STRIP_MINI_W(%d) == 4"
    % (L.TEAM_STRIP_W, SIG.EYE_STRIP_MINI_W))
(ok if L.TEAM_LABEL_W == 8 else bad)(
    "GEOMETRY: the name/branch slot keeps its 8 cells (TEAM_LABEL_W=%d) — no new truncation"
    % L.TEAM_LABEL_W)
# The derivation: adjacent LABELS must stay separated by at least a strip width, or the
# columns run together. (member_w - label_w) + member_gap >= strip_w  →  member_w >= 10.
sep = (L.TEAM_MEMBER_W - L.TEAM_LABEL_W) + L.TEAM_MEMBER_GAP
sep_1 = (L.TEAM_MEMBER_W - 1 - L.TEAM_LABEL_W) + L.TEAM_MEMBER_GAP
(ok if sep >= L.TEAM_STRIP_W and sep_1 < L.TEAM_STRIP_W else bad)(
    "GEOMETRY: TEAM_MEMBER_W=%d is TIGHT — label separation %dc >= strip %dc, and %dc would not be"
    % (L.TEAM_MEMBER_W, sep, L.TEAM_STRIP_W, L.TEAM_MEMBER_W - 1))
nine = 9 * L.TEAM_MEMBER_W + 8 * L.TEAM_MEMBER_GAP
(ok if nine == 106 else bad)("GEOMETRY: 9 members cost 9*%d + 8*%d = %dc (was 151c)"
                             % (L.TEAM_MEMBER_W, L.TEAM_MEMBER_GAP, nine))

# ── 2) THE MINI STRIP IS WHAT THE WALL RENDERS ───────────────────────────────────
# ONLINE deliberately: an absent teammate's strip is DESATURATED by _drain_hue, so only a
# present one can be compared against eye_strip_mini's raw bytes.
members = [{"user": "akshat", "haid": "haid:akshat.m1-a1b2", "sigil": "", "branch": "",
            "last_branch": "", "state": "working", "ts": NOW - 10, "online": True,
            "tier": "online"}]
r1, r2, r3, r4 = m.team_columns(members, L.TEAM_MEMBER_W, 0, NOW)
lead = L.TEAM_MEMBER_W - L.TEAM_STRIP_W
plain1 = ANSI.sub("", r1)
(ok if all(m.vis(r) == L.TEAM_MEMBER_W for r in (r1, r2, r3, r4)) else bad)(
    "MINI: every team row is exactly one %dc column" % L.TEAM_MEMBER_W)
(ok if plain1[:lead] == " " * lead and plain1[lead:].strip() else bad)(
    "MINI: the %dc strip rides the RIGHT of the column behind a %dc pad" % (L.TEAM_STRIP_W, lead))
mini = SIG.eye_strip_mini("haid:akshat.m1-a1b2", m.CAPS)
(ok if m.vis(mini[0]) == L.TEAM_STRIP_W and mini[0] in r1 else bad)(
    "MINI: team_columns emits eye_strip_mini verbatim (not the 8-cell eye_strip)")
(ok if SIG.eye_strip("haid:akshat.m1-a1b2", m.CAPS)[0] not in r1 else bad)(
    "MINI: the 8-cell eye_strip is NOT on the wall any more")

# ── 3) THE HEADLINE: a wide terminal keeps the WHOLE panel ───────────────────────
for cols in (160, 200):
    b = budgets(cols)
    (ok if b["r4_bars"] else bad)(
        "PANEL@%d: Row4 renders BAR micro-gauges — panel %dc >= the %dc the bars need"
        % (cols, b["cb"], b["r4_need"]))
    (ok if b["r3_full"] else bad)(
        "PANEL@%d: Row3 keeps its gate DETAILS — panel %dc >= the %dc they need"
        % (cols, b["cb"], b["r3_need"]))
    (ok if b["gauge_w"] == b["gauge_max"] else bad)(
        "PANEL@%d: Row2 gauge is the full %dc (got %dc)" % (cols, b["gauge_max"], b["gauge_w"]))
    (ok if b["shown"] + b["of"] == 9 else bad)(
        "PANEL@%d: all 9 teammates accounted for — %d shown + %d in +N"
        % (cols, b["shown"], b["of"]))
b200 = budgets(200)
(ok if b200["shown"] == 9 and b200["of"] == 0 else bad)(
    "PANEL@200: all 9 columns fit (%d shown, +%d) in %dc of team zone"
    % (b200["shown"], b200["of"], b200["tw"]))

# ── 4) THE FLOOR NEVER EATS THE WHOLE WALL ───────────────────────────────────────
# A pathological gate row must not be able to starve the team zone: the panel may claim
# its tier promise, but never more than half the line.
fat = [{"id": "gate-with-a-very-long-identifier-%d" % i, "state": "pass",
        "detail": "a-detail-segment-that-runs-on-and-on-%d" % i} for i in range(8)]
fat_floor = m.panel_floor("full", DATA, NOW, fat, "s", 3840000)
cb, tw, shown, of, _g = L.team_zone_alloc(200, 9, 0, rows_gap=m.TEAM_COL_GAP,
                                          content_floor=fat_floor)
(ok if shown >= 4 else bad)(
    "BOUNDED: an 8-gate row wants %dc of floor, yet %d teammates still render (+%d)"
    % (fat_floor, shown, of))
(ok if cb >= L.GAUGE_MIN_W else bad)(
    "BOUNDED: the panel still keeps at least GAUGE_MIN_W (%dc) — got %dc" % (L.GAUGE_MIN_W, cb))

# ── 5) THE `avail` SELF-DOWNGRADE IS STILL THERE (last resort, narrow terminals) ──
narrow = m.micro_row(DATA, NOW, 12, "s", 3840000, avail=20)
(ok if FILL not in narrow and TRACK not in narrow else bad)(
    "LAST-RESORT: micro_row still self-downgrades to text when the bars genuinely overflow")
b60 = budgets(60)
(ok if not b60["r4_bars"] else bad)(
    "LAST-RESORT@60: a 60-col terminal legitimately falls back to text (panel %dc, bars need %dc)"
    % (b60["cb"], b60["r4_need"]))

# Hand section 6 the team-zone width per terminal size so its clip check can scope itself
# to the PANEL. A wall LABEL legitimately truncates a long handle (`priyadh…`, the exact
# behaviour wall-label-collision.test.sh gates); the PANEL never may.
def real_zone(cols):
    """The team zone main() actually reserves at `cols` for this 9-member wall: the mid tier
    caps the wall to 2 columns + `+N` before allocating, narrow/tiny have no zone at all."""
    tier = L.width_tier(cols)
    if tier not in ("full", "mid"):
        return 0
    n, ov = (9, 0) if tier == "full" else (2, 7)
    _cb, tw, _s, _o, _g = L.team_zone_alloc(
        cols, n, ov, rows_gap=m.TEAM_COL_GAP,
        content_floor=m.panel_floor(tier, DATA, NOW, GATES, "s", 3840000))
    return tw

zones = os.environ.get("PANEL_ZONES")
if zones:
    with open(zones, "w", encoding="utf-8") as f:
        for c in (200, 160, 120, 90, 60, 40):
            f.write("%d %d\n" % (c, real_zone(c)))
print("\n  DERIVED panel_floor@full = %dc (gauge %dc / Row4 bars %dc / Row3 gates %dc)"
      % (m.panel_floor("full", DATA, NOW, GATES, "s", 3840000), m._gauge_max_for("full"),
         m.vis(m.micro_row(DATA, NOW, m._bar_w_for("full"), "s", 3840000, avail=None)),
         m.vis(m.gate_labels(GATES, None, colored=True))))
print("  %d passed, %d failed" % (P[0], F[0]))
sys.exit(0 if F[0] == 0 else 1)
PYEOF

ZONES="$TMPD/zones"
CHK="$TMPD/chk.py"
cat > "$CHK" <<'CHKEOF'
# Measure a render: the visible cell width of every row, and whether the PANEL carries a
# `…`. Scoped deliberately — a wall LABEL truncating a long handle (`ravi…nuo`) is correct
# and gated by wall-label-collision.test.sh; a clipped PANEL is the defect.
#
# The panel's right edge is found EMPIRICALLY, not modelled: main() LEFT-PACKS the team so
# it hugs the content (compose() = sigil + col1_w + gutter + team, tail-padded), so the zone
# does NOT start at cols-team_w and any arithmetic guess reads wall labels as panel clips.
# Row 1's team cells are eye-strip `▄` half-blocks and its panel cells never are (text, `⛭`,
# `◦`), so the first `▄` at or after the 9-cell sigil zone IS the boundary.
import sys, re
A = re.compile(r"\033\[[0-9;]*m")
cols, expect_team, first_row = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
SIGIL_ZONE = 9
def cells(line):
    """[(char, start_cell)] for one rendered row, ANSI stripped, wide glyphs counted as 2."""
    out, n = [], 0
    for ch in A.sub("", line):
        o = ord(ch)
        w = 0 if (o in (0x200B, 0x200D, 0xFE0F) or 0x0300 <= o <= 0x036F) else (
            2 if (o == 0x26A1 or 0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0xA4CF
                  or 0xAC00 <= o <= 0xD7A3 or 0x1F000 <= o <= 0x1FAFF) else 1)
        out.append((ch, n))
        n += w
    return out, n

rows = [l for l in sys.stdin.read().split("\n") if l != ""]
grids = [cells(l) for l in rows]
print("widths=%s" % ",".join(str(x) for x in sorted({n for _g, n in grids})))
panel_end = cols
if grids:
    marks = [start for ch, start in grids[0][0] if ch == "▄" and start >= SIGIL_ZONE]
    if marks:
        panel_end = marks[0]
print("panelend=%d" % panel_end)
# A vacuous check is a failure, never a pass: if a team zone is expected, its boundary must
# actually have been located, or the clip check below is inspecting the whole row for free.
print("teamfound=%s" % ("yes" if panel_end < cols else "no"))
print("teamexpected=%s" % ("yes" if expect_team else "no"))
clipped = ["".join(ch for ch, start in g if start < panel_end)
           for g, _n in grids[first_row - 1:]]
clipped = [p for p in clipped if "…" in p]
print("panelclip=%s" % ("yes" if clipped else "no"))
if clipped:
    print("clip=%r" % clipped[0])
CHKEOF

FAIL=0
PANEL_ZONES="$ZONES" python3 "$PY" "$SL" "$MODE" || FAIL=1
[ "$MODE" = prove-red ] && { [ "$FAIL" -eq 0 ] || exit 1; exit 0; }

# ── 6) END-TO-END: the real script, every width, exact rows, panel never clipped ──
echo "== 6) end-to-end render: exact row widths, panel unclipped, 9 teammates =="
E_PASS=0; E_FAIL=0
[ -s "$ZONES" ] || { echo "  FATAL: the harness wrote no team-zone widths — cannot scope the panel"; exit 2; }
for c in 200 160 120 90 60 40; do
  tw="$(awk -v c="$c" '$1==c{print $2}' "$ZONES")"
  [ -n "$tw" ] || { echo "  FATAL: no team-zone width recorded for $c cols"; exit 2; }
  expect=0; [ "$tw" -gt 0 ] && expect=1
  # ROW1 EXCEPTION at the narrow tier: 40 cols has NO team zone, so the panel-floor
  # mechanism is not involved there, and its Row1 identity run (`⛭ HEIMDA…`) is clipped
  # IDENTICALLY on the pre-change baseline — a pre-existing narrow-tier row1_left issue,
  # not this change's. Rows 2–4 are still held to the no-clip bar at 40.
  first=1; [ "$c" -lt 60 ] && first=2
  got="$(render "$c" | python3 "$CHK" "$c" "$expect" "$first")"
  case "$got" in
    *"widths=$c"$'\n'*) E_PASS=$((E_PASS+1)); printf '  ok   ROW-EXACT@%s: every row %s cells\n' "$c" "$c";;
    *) E_FAIL=$((E_FAIL+1)); printf '  FAIL ROW-EXACT@%s: %s\n' "$c" "$(printf '%s' "$got" | head -1)";;
  esac
  # The boundary must be LOCATED before the clip check means anything.
  tf="$(printf '%s' "$got" | sed -n 's/^teamfound=//p')"
  te="$(printf '%s' "$got" | sed -n 's/^teamexpected=//p')"
  if [ "$tf" = "$te" ]; then
    E_PASS=$((E_PASS+1)); printf '  ok   ZONE-FOUND@%s: team zone %s, boundary agrees\n' "$c" "$te"
  else
    E_FAIL=$((E_FAIL+1)); printf '  FAIL ZONE-FOUND@%s: expected team=%s but located=%s — the clip check would be vacuous\n' "$c" "$te" "$tf"
  fi
  pe="$(printf '%s' "$got" | sed -n 's/^panelend=//p')"
  case "$got" in
    *"panelclip=no"*) E_PASS=$((E_PASS+1)); printf '  ok   PANEL-WHOLE@%s: the panel (%sc, rows %s-4) carries no `…` clip\n' "$c" "$pe" "$first";;
    *) E_FAIL=$((E_FAIL+1)); printf '  FAIL PANEL-WHOLE@%s: the panel is `…`-clipped — %s\n' "$c" "$(printf '%s' "$got" | tail -1)";;
  esac
done

# The headline, observed on the REAL emitted bytes rather than on the budget math.
out200="$(render 200)"
if printf '%s' "$out200" | grep -q '▓'; then
  E_PASS=$((E_PASS+1)); printf '  ok   BARS@200: Row4 emits real ▓ micro-gauge bars\n'
else E_FAIL=$((E_FAIL+1)); printf '  FAIL BARS@200: Row4 emitted no ▓ — the bars downgraded to text\n'; fi
if printf '%s' "$out200" | grep -q '41/41'; then
  E_PASS=$((E_PASS+1)); printf '  ok   GATES@200: Row3 keeps its gate details\n'
else E_FAIL=$((E_FAIL+1)); printf '  FAIL GATES@200: Row3 dropped the gate details\n'; fi

printf '\n  %d passed, %d failed\n' "$E_PASS" "$E_FAIL"
[ "$FAIL" -eq 0 ] && [ "$E_FAIL" -eq 0 ]
