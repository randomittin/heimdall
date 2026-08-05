#!/usr/bin/env bash
# wall-label-collision — two DISTINCT people must never render as the same column.
#
# The bug this exists to prevent, found by a visual audit of the launch screenshot:
# rally at COLUMNS=200 showed `ravikir…` TWICE, adjacent. The two rows are
# `ravikiran2904` and `ravikiranuo` — two people the roster CORRECTLY refuses to
# merge, because a wrong merge hides a human. The wall then undid that correctness
# at the very last step: an 8-cell name slot cut both at 7 chars + `…`, and the two
# became one indistinguishable label. A stranger reads that as the wall rendering
# the same person twice.
#
# The truncation RULE was never the defect — a real `…`, applied consistently, reads
# as deliberate. What was missing is COLLISION HANDLING behind it. So this asserts the
# observable property the rule must now carry:
#
#     no two visible columns may share a rendered label.
#
# It drives the real team_columns() and slices the real Row3 by the real column
# geometry, so any future rewrite of the truncation is held to the same property
# however it is written.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

probe="$(python3 - "$REPO" <<'PY' 2>&1
import sys, re, json, os, importlib.util as u
repo = sys.argv[1]
sys.path.insert(0, repo + "/sentinels")
spec = u.spec_from_file_location("sl", repo + "/sentinels/hmd-statusline.py")
m = u.module_from_spec(spec)
spec.loader.exec_module(m)
LAYOUT = m.LAYOUT

ANSI = re.compile(r"\x1b\[[0-9;]*m")
NOW = 1785869500
MW, GAP, SW = LAYOUT.TEAM_MEMBER_W, LAYOUT.TEAM_MEMBER_GAP, LAYOUT.TEAM_STRIP_W
PAD = MW - SW


def labels(names, tier="contributed"):
    """The REAL rendered Row3 labels, sliced out of team_columns() by column geometry."""
    members = [{"user": n, "haid": "", "sigil": "", "branch": "", "last_branch": "",
                "state": tier, "ts": NOW - 90000, "online": tier == "online",
                "tier": tier} for n in names]
    width = len(names) * MW + (len(names) - 1) * GAP
    row3 = ANSI.sub("", m.team_columns(members, width, 0, NOW)[2])
    out = []
    for i in range(len(names)):
        start = i * (MW + GAP) + PAD
        out.append(row3[start:start + SW])
    return out


# ── A. the exact pair from the audit ──────────────────────────────────────────
pair = ["ravikiran2904", "ravikiranuo"]
a = labels(pair)
print("A_labels=%s" % json.dumps(a))
print("A_distinct=%s" % ("yes" if len(set(a)) == len(a) else "no"))
print("A_width=%s" % ("ok" if all(len(x) == SW for x in a) else "bad"))

# ── B. the SECOND colliding pair in the same roster (found by this test) ──────
b = labels(["tejashwini", "tejashwini-cmd"])
print("B_labels=%s" % json.dumps(b))
print("B_distinct=%s" % ("yes" if len(set(b)) == len(b) else "no"))

# ── C. the whole real rally roster, whatever it holds today ───────────────────
cache = "/Users/rj/Downloads/code/rally/.heimdall/.wall-cache.json"
roster = []
if os.path.exists(cache):
    try:
        roster = [r["handle"] for r in json.load(open(cache)) if r.get("handle")]
    except Exception:
        roster = []
if not roster:
    # The suite must be hermetic: a machine without that checkout still exercises the
    # property, against the roster the audit actually recorded.
    roster = ["akshat", "anu", "madala", "madhavan", "priyadharshan", "ravikiran2904",
              "ravikiranuo", "ranjitha", "tejashwini", "viveksuperpe", "vaibhav",
              "harshal", "akhil", "Nikhil311234", "SuperKrishnaSingh", "SuperMadhavan",
              "chsaikrishna123", "iris594", "riteshsuperpe", "sanket-spe", "shreekta24",
              "tejashwini-cmd", "randomittin"]
c = labels(roster)
dupes = sorted({x for x in c if c.count(x) > 1})
print("C_n=%d" % len(roster))
print("C_distinct=%s" % ("yes" if not dupes else "no"))
print("C_dupes=%s" % json.dumps(dupes))


def readable(label):
    """What a reader actually takes off the column: the characters, plus whether the
    label is CUT at all.

    Two ELIDED labels carrying the same characters — `superpe…` beside `superp…e` — are
    set-distinct but read as one person, because the only thing separating them is where
    the `…` landed, and that position carries no identity. Between a cut label and a
    whole one (`priyadh…` beside `priyadh`) the ellipsis IS the signal, so that pair is
    honestly distinct. Distinctness therefore has to be measured on (characters, cut).
    """
    return (label.replace("…", "").strip(), "…" in label)


def weak_pairs(got):
    return [[a, b] for i, a in enumerate(got) for b in got[i + 1:]
            if readable(a) == readable(b)]


print("C_weak=%s" % json.dumps(weak_pairs(c)))

# ── D. a name that does NOT collide keeps the PLAIN rule (no gratuitous churn) ─
solo = labels(["priyadharshan", "chsaikrishna123"])
print("D_plain=%s" % ("yes" if solo == ["priyadh…", "chsaikr…"] else "no"))
print("D_got=%s" % json.dumps(solo))

# ── E. the ellipsis stays a REAL `…`, and short names are never marked ─────────
print("E_ellipsis=%s" % ("yes" if all("…" in x for x in a) else "no"))
short = labels(["anu", "akshat"])
print("E_short=%s" % ("yes" if short == ["anu     ", "akshat  "] else "no"))
print("E_short_got=%s" % json.dumps(short))

# ── F. TOTALITY — even two rows carrying the SAME handle cannot render as one
#      column. This is a roster-level anomaly, but the guarantee the renderer makes
#      must not depend on an upstream invariant it cannot see: the property is "no two
#      visible columns share a label", full stop.
same = labels(["akshat", "akshat"])
print("F_distinct=%s" % ("yes" if len(set(same)) == 2 else "no"))
print("F_weak=%s" % json.dumps(weak_pairs(same)))
print("F_got=%s" % json.dumps(same))
# `akshat` FITS in the slot, so nothing was elided. A label that answers the collision
# with `akshat…t` claims characters were dropped that never existed — a fabricated cut.
print("F_nofake=%s" % ("yes" if not any("…" in x for x in same) else "no"))

# ── G. names differing ONLY in the middle — neither head nor tail separates them,
#      so the ladder must still terminate in a pair that is distinct TO A READER
#      rather than one that merely shuffles the ellipsis.
mid = labels(["superpe-alpha-node", "superpe-omega-node"])
print("G_distinct=%s" % ("yes" if len(set(mid)) == 2 else "no"))
print("G_weak=%s" % json.dumps(weak_pairs(mid)))
print("G_got=%s" % json.dumps(mid))

# ── H. determinism — the same roster renders the same labels every time.
print("H_stable=%s" % ("yes" if labels(roster) == c else "no"))
PY
)"

case "$probe" in *Traceback*) bad "the probe crashed: $probe" ;; esac

# A — the audit's own pair
case "$probe" in
  *"A_distinct=yes"*) ok ;;
  *) bad "ravikiran2904 and ravikiranuo still render as the SAME column ($probe)" ;;
esac
case "$probe" in
  *"A_width=ok"*) ok ;;
  *) bad "a disambiguated label is not exactly TEAM_STRIP_W cells — the column grid breaks" ;;
esac

# B — the second pair in the same roster
case "$probe" in
  *"B_distinct=yes"*) ok ;;
  *) bad "tejashwini and tejashwini-cmd still render as the SAME column" ;;
esac

# C — the whole real roster
case "$probe" in
  *"C_distinct=yes"*) ok ;;
  *) bad "the real rally roster renders duplicate labels ($probe)" ;;
esac
case "$probe" in
  *'C_weak=[]'*) ok ;;
  *) bad "two roster columns differ only in where the … sits — they read as one person" ;;
esac

# D — no churn for names that never collided
case "$probe" in
  *"D_plain=yes"*) ok ;;
  *) bad "a NON-colliding name changed shape — collision handling must not rewrite the innocent" ;;
esac

# E — the truncation grammar is preserved
case "$probe" in
  *"E_ellipsis=yes"*) ok ;;
  *) bad "a truncated label lost its real … — the cut must stay legible as deliberate" ;;
esac
case "$probe" in
  *"E_short=yes"*) ok ;;
  *) bad "a name that FITS was marked as truncated" ;;
esac

# F/G — totality: the guarantee holds even where the data gives nothing to work with
case "$probe" in
  *"F_distinct=yes"*) ok ;;
  *) bad "two rows with the same handle collapsed into one indistinguishable column" ;;
esac
case "$probe" in
  *"F_nofake=yes"*) ok ;;
  *) bad "a name that FITS was given a fabricated … to break a tie — the cut claims dropped chars that never existed" ;;
esac
case "$probe" in
  *'F_weak=[]'*) ok ;;
  *) bad "two same-handle rows differ only in ellipsis placement — still one person to a reader" ;;
esac
case "$probe" in
  *"G_distinct=yes"*) ok ;;
  *) bad "names differing only in the MIDDLE collapsed — the ladder gave up" ;;
esac
case "$probe" in
  *'G_weak=[]'*) ok ;;
  *) bad "middle-differing names were separated only by moving the … — a reader sees one person" ;;
esac

# H — deterministic
case "$probe" in
  *"H_stable=yes"*) ok ;;
  *) bad "labels are not deterministic — the same roster rendered differently twice" ;;
esac

printf '\n  %s%d passed, %d failed\033[0m\n' \
  "$([ "$FAIL" -eq 0 ] && printf '\033[32m' || printf '\033[31m')" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
