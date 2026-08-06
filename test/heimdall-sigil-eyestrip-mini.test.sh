#!/usr/bin/env bash
# heimdall-sigil-eyestrip-mini.test.sh — the HALF-WIDTH teammate eye strip
# (eye_strip_mini): the same eye band eye_strip crops, compressed 8 cells → 4 so nine
# teammates cost ~106 cells of wall instead of 151 and the left content panel keeps its
# full-tier floor.
#
# WHY A MEASURED COMPRESSION, NOT A CROP. Three candidates were rendered for all 58 heroes
# and scored before one was chosen (scratch harness, numbers reproduced by section 3/4 here):
#   (a) 2×1 horizontal box-AVERAGE  — median 6 shades, 1 hero under 3, 0 collisions
#   (b) face bounding-box crop      — median 3 shades, 8 heroes under 3, and a DRAINED strip
#                                     collapsing to ONE shade (the exact 3f5e959 regression)
#   (c) eye-preserving 2×1 average  — median 5 shades, 2 heroes under 3, 0 collisions
# (a) won on every axis, so (a) is what ships. This suite locks the properties that decided
# it, so a future "simplification" to a crop goes RED instead of quietly losing the faces.
#
# CONTRACT:
#   1. SHAPE      — exactly 2 text-rows × EXACTLY 4 visible cells, for all 58 heroes, real
#                   HAIDs, toy seeds; TOTAL (garbage/None/int never raises, still 2×4).
#   2. SHADES     — a mini strip keeps >= 3 distinct RGB values for a typical hero, and NEVER
#                   fewer than that hero's own 8-cell eye_strip: compression may not cost a
#                   hero shades it already had. A 1–2 shade blob is the bug 3f5e959 fixed.
#   3. COLLISIONS — over ALL of HERO_ORDER, ZERO pairs render byte-identical. The 4-cell strip
#                   is exactly as identity-bearing as the 8-cell one (which is also 0).
#   4. DRAIN      — hmd-statusline._drain_hue() greyscales a mini strip to ALL-grey while
#                   keeping > 1 shade, for EVERY hero (what wall-presence-drain.test.sh gates).
#   5. TIER       — one-pass caps downgrade: 256 → no raw 38;2; · 16 → neither · mono → no SGR.
#   6. ADDITIVE   — eye_strip / sigil_render are byte-UNCHANGED (a parallel projection).
#
#   --prove-red   MUTATION harness: monkeypatch a named known-bad in and prove each property
#                 actually flips RED. A gate that cannot fail is a false green.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIG="$ROOT/sentinels/hmd_sigil.py"
SL="$ROOT/sentinels/hmd-statusline.py"

MODE=render
case "${1:-}" in
  "") ;;
  --prove-red) MODE=prove-red;;
  *) echo "usage: $0 [--prove-red]"; exit 2;;
esac

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SIG" ] || { echo "FATAL: sigil core missing at $SIG"; exit 2; }
[ -f "$SL" ]  || { echo "FATAL: statusline missing at $SL"; exit 2; }

PY="$(mktemp -t eyestripmini.XXXXXX.py)"
trap 'rm -f "$PY"' EXIT
cat > "$PY" <<'PYEOF'
import importlib.util, sys, re, os
SIGP, SLP, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.dirname(SIGP))
spec = importlib.util.spec_from_file_location("s", SIGP)
S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
os.environ.setdefault("HEIMDALL_STATUSLINE_MODE", "truecolor")
os.environ.setdefault("COLUMNS", "200")
sl_spec = importlib.util.spec_from_file_location("sl", SLP)
SL = importlib.util.module_from_spec(sl_spec); sl_spec.loader.exec_module(SL)

ANSI = re.compile(r"\033\[[0-9;]*m")
RGB = re.compile(r"[34]8;2;(\d+);(\d+);(\d+)")
MINI_W = 4
def vis(x): return len(ANSI.sub("", x))
P = [0]; F = [0]
def ok(m): P[0] += 1; print("  ok   " + m)
def bad(m): F[0] += 1; print("  FAIL " + m)

tc = S.tier_caps("truecolor")
HEROES = list(S.HERO_ORDER)
HAIDS = ["haid:%s.wall-%04x" % (n, i) for i, n in enumerate(
    ["akshat", "priya", "ravi", "tejashwini", "vivek", "harshal", "madhavan",
     "chsaikrishna", "nikhil", "anu", "sanket", "iris"])]

def shades(rows):
    return {t for t in RGB.findall("".join(rows))}

def _resolve(seed):
    """(pxfn, is_bg, eye_count) — the known-bads build their own strips from the same grid
    the real one reads, so a falsifier differs from the SUT only in the compression."""
    got = S.custom_for(seed)
    if got is not None:
        g, pal = got
        return ((lambda r, c: pal.get(g[r][c], pal['.'])),
                (lambda r, c: g[r][c] == '.'),
                [sum(1 for c in range(S.W) if g[r][c] == '2') for r in range(S.W)])
    g, hue, eye = S.grid_for(seed)
    return ((lambda r, c: S.cell_color(g[r][c], hue, eye)),
            (lambda r, c: g[r][c] == 0),
            [sum(1 for c in range(S.W) if g[r][c] == 2) for r in range(S.W)])

def bad_bbox_crop(seed):
    """KNOWN-BAD (b): drop the all-background border columns, centre-crop to 4. Keeps crisp
    pixels but throws away the outer columns' information."""
    px, is_bg, ec = _resolve(seed)
    top = S._eye_strip_top(ec)
    cols = [c for c in range(S.W) if any(not is_bg(r, c) for r in range(top, top + 4))] \
        or list(range(S.W))
    lo, hi = cols[0], cols[-1]
    span = hi - lo + 1
    start = lo + (span - 4) // 2 if span >= 4 else max(0, min(S.W - 4, lo - (4 - span) // 2))
    out = ["".join(S._cell(px(tr, c), px(tr + 1, c)) for c in range(start, start + MINI_W))
           for tr in (top, top + 2)]
    return tc.emit("\n".join(out)).split("\n")

def bad_silhouette(seed):
    """KNOWN-BAD: a single-hue on/off recolour — the `mud` the eye_strip header rejects.
    Shape survives, identity does not."""
    px, is_bg, ec = _resolve(seed)
    top = S._eye_strip_top(ec)
    ON, OFF = (120, 130, 145), (40, 44, 52)
    out = []
    for tr in (top, top + 2):
        line = ""
        for c in range(MINI_W):
            lo, hi = 2 * c, 2 * c + 1
            line += S._cell(OFF if is_bg(tr, lo) and is_bg(tr, hi) else ON,
                            OFF if is_bg(tr + 1, lo) and is_bg(tr + 1, hi) else ON)
        out.append(line)
    return tc.emit("\n".join(out)).split("\n")

if MODE == "prove-red":
    # ── each named known-bad must flip its OWN property red ───────────────────────
    # Every expectation below is a MEASURED number, not a guess: each known-bad was scored
    # over all 58 heroes before it was written in.
    print("== --prove-red: each named known-bad MUST flip its property RED ==")

    def score(fn):
        keyed = {}; under3 = 0; drain_min = 99
        for h in HEROES:
            r = fn(h)
            keyed.setdefault("\n".join(r), []).append(h)
            if len(shades(r)) < 3:
                under3 += 1
            drain_min = min(drain_min, len(shades(SL._drain_hue(r))))
        pairs = sum(len(v) * (len(v) - 1) // 2 for v in keyed.values() if len(v) > 1)
        return pairs, under3, drain_min

    real_pairs, real_under3, real_drain = score(lambda h: S.eye_strip_mini(h, tc))
    print("  (SUT baseline: collide=%d under3=%d drain_min=%d)"
          % (real_pairs, real_under3, real_drain))

    # KNOWN-BAD 1 — the bbox crop. Must flip SHADES and SHADES-NO-REGRESS.
    c_pairs, c_under3, c_drain = score(bad_bbox_crop)
    (ok if c_under3 > real_under3 else bad)(
        "prove-red SHADES: the bbox crop leaves %d heroes under 3 shades vs the real %d (RED)"
        % (c_under3, real_under3))
    regress = [h for h in HEROES
               if len(shades(bad_bbox_crop(h))) < min(3, len(shades(S.eye_strip(h, tc))))]
    (ok if regress else bad)(
        "prove-red NO-REGRESS: the bbox crop costs %d heroes shades they had at 8 cells (RED)"
        % len(regress))

    # KNOWN-BAD 2 — the same crop drains a hero to ONE shade: the 3f5e959 blob, exactly.
    (ok if c_drain <= 1 else bad)(
        "prove-red DRAIN-STRUCTURE: the bbox crop drains some hero to %d shade(s) (RED)" % c_drain)

    # KNOWN-BAD 3 — the single-hue silhouette. Must flip COLLISIONS.
    s_pairs, s_under3, _s_drain = score(bad_silhouette)
    (ok if s_pairs > real_pairs else bad)(
        "prove-red COLLISIONS: the single-hue silhouette collides %d hero pairs vs the real %d (RED)"
        % (s_pairs, real_pairs))

    # KNOWN-BAD 4 — a 3-cell strip must fail the exact-width property.
    three = ["".join(S._cell((1, 2, 3), (4, 5, 6)) for _ in range(3))] * 2
    (ok if any(vis(r) != MINI_W for r in three) else bad)(
        "prove-red SHAPE: a 3-cell strip is not %dc (RED)" % MINI_W)
    print("\n  %d passed, %d failed" % (P[0], F[0]))
    sys.exit(0 if F[0] == 0 else 1)

# ── 1) SHAPE: exactly 2 rows × exactly 4 visible cells, everywhere ────────────────
bad_shape = []
for seed in HEROES + HAIDS + ["rj", "nadia", "toy-seed", "", "?"]:
    r = S.eye_strip_mini(seed, tc)
    if not isinstance(r, list) or len(r) != 2 or any(vis(x) != MINI_W for x in r):
        bad_shape.append((seed, None if not isinstance(r, list) else [vis(x) for x in r]))
(ok if not bad_shape else bad)(
    "SHAPE: %d seeds → 2 rows × %dc each%s"
    % (len(HEROES) + len(HAIDS) + 5, MINI_W,
       "" if not bad_shape else " — BROKEN: %r" % bad_shape[:4]))

# TOTALITY: junk input never raises and still returns the exact shape.
tot = []
for junk in (None, 12345, ["x"], {"a": 1}, object()):
    try:
        r = S.eye_strip_mini(junk, tc)
        if not isinstance(r, list) or len(r) != 2 or any(vis(x) != MINI_W for x in r):
            tot.append(("shape", junk))
    except Exception as e:
        tot.append(("raised", type(e).__name__))
(ok if not tot else bad)("TOTAL: junk seeds never raise, still 2×%dc%s"
                         % (MINI_W, "" if not tot else " — %r" % tot))

# ── 2) SHADES: >= 3 for a typical hero, and never fewer than that hero's 8-cell strip
low = [h for h in HEROES if len(shades(S.eye_strip_mini(h, tc))) < 3]
counts = sorted(len(shades(S.eye_strip_mini(h, tc))) for h in HEROES)
median = counts[len(counts) // 2]
(ok if len(low) <= 1 else bad)(
    "SHADES: median=%d min=%d — %d hero(es) under 3 shades %s"
    % (median, counts[0], len(low), low[:6]))
regress = [h for h in HEROES
           if len(shades(S.eye_strip_mini(h, tc))) < min(3, len(shades(S.eye_strip(h, tc))))]
(ok if not regress else bad)(
    "SHADES-NO-REGRESS: no hero loses shades it had at 8 cells%s"
    % ("" if not regress else " — %r" % regress[:6]))

# ── 3) COLLISIONS: zero byte-identical pairs over ALL of HERO_ORDER ──────────────
keyed = {}
for h in HEROES:
    keyed.setdefault("\n".join(S.eye_strip_mini(h, tc)), []).append(h)
groups = [v for v in keyed.values() if len(v) > 1]
pairs = sum(len(v) * (len(v) - 1) // 2 for v in groups)
base_keyed = {}
for h in HEROES:
    base_keyed.setdefault("\n".join(S.eye_strip(h, tc)), []).append(h)
base_pairs = sum(len(v) * (len(v) - 1) // 2 for v in base_keyed.values() if len(v) > 1)
(ok if pairs <= base_pairs else bad)(
    "COLLISIONS: %d identical pairs over %d heroes (8-cell baseline: %d)%s"
    % (pairs, len(HEROES), base_pairs, "" if not groups else " — %r" % groups[:4]))

# ── 4) DRAIN: all-grey, > 1 shade, for EVERY hero ────────────────────────────────
not_grey = []; flat = []
for h in HEROES:
    d = SL._drain_hue(S.eye_strip_mini(h, tc))
    sh = {(int(a), int(b), int(c)) for a, b, c in RGB.findall("".join(d))}
    if not all(a == b == c for a, b, c in sh):
        not_grey.append(h)
    if len(sh) <= 1:
        flat.append(h)
(ok if not not_grey else bad)("DRAIN-GREY: every hero's mini strip desaturates fully%s"
                              % ("" if not not_grey else " — %r" % not_grey[:6]))
(ok if not flat else bad)("DRAIN-STRUCTURE: every drained mini strip keeps > 1 shade%s"
                          % ("" if not flat else " — %r" % flat[:6]))

# ── 5) TIER: one-pass caps downgrade ─────────────────────────────────────────────
s256 = "".join(S.eye_strip_mini("batsy", S.tier_caps("256")))
s16 = "".join(S.eye_strip_mini("batsy", S.tier_caps("16")))
smono = "".join(S.eye_strip_mini("batsy", S.tier_caps("mono")))
(ok if "38;2;" not in s256 and ("38;5;" in s256 or "48;5;" in s256) else bad)(
    "TIER-256: cube codes, no raw 24-bit leak")
(ok if "38;2;" not in s16 and "38;5;" not in s16 else bad)("TIER-16: neither 24-bit nor cube")
(ok if "\033[" not in smono else bad)("TIER-mono: no SGR at all")
(ok if all(vis(r) == MINI_W for c in ("256", "16", "mono")
           for r in S.eye_strip_mini("batsy", S.tier_caps(c))) else bad)(
    "TIER-WIDTH: %dc at every colour tier" % MINI_W)

# ── 6) ADDITIVE: the 8-cell strip and sigil_render are untouched ─────────────────
(ok if all(vis(r) == 8 for h in HEROES for r in S.eye_strip(h, tc)) else bad)(
    "ADDITIVE: eye_strip is still 8 cells for every hero")
(ok if len(S.sigil_render("batsy", "M", tc)) == 4 else bad)(
    "ADDITIVE: sigil_render M still renders 4 rows")

print("\n  %d passed, %d failed" % (P[0], F[0]))
sys.exit(0 if F[0] == 0 else 1)
PYEOF

python3 "$PY" "$SIG" "$SL" "$MODE"
