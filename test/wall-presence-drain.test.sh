#!/usr/bin/env bash
# wall-presence-drain — an ABSENT teammate must not render like a PRESENT one.
#
# The bug this exists to prevent, which shipped and was found by a visual audit:
# `_MONO_CAPS = SIG.tier_caps(TC.MONO, CAPS.unicode_tier)` referenced an attribute
# that does not exist (`unicode_tier` is the PARAMETER name; the attribute is
# `unicode`). A bare `except Exception` swallowed the AttributeError, `_MONO_CAPS`
# stayed None, and the drain never ran — so online / contributed / away / member
# all emitted BYTE-IDENTICAL sigil colours. On a repo with nobody online the wall
# rendered nine fully-saturated faces.
#
# That is the worst failure available to this project: a wall implying presence it
# does not have, in the feature meant to demonstrate we do not overclaim. No unit
# test covered it because the code "worked" — it just silently did nothing.
#
# So this asserts the OBSERVABLE property, not the implementation: the colours an
# absent tier emits must differ from the colours the online tier emits. It drives
# the real team_columns() rather than inspecting internals, so any future refactor
# that reintroduces the collapse fails here regardless of how it is written.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

probe="$(python3 - "$REPO" <<'PY' 2>&1
import sys, re, importlib.util as u
repo = sys.argv[1]
sys.path.insert(0, repo + "/sentinels")
spec = u.spec_from_file_location("sl", repo + "/sentinels/hmd-statusline.py")
m = u.module_from_spec(spec)
spec.loader.exec_module(m)

# d3fd560 replaced the MONO render tier with hue DESATURATION (_drain_hue): the
# identity hue drains out while the glyph SHAPE survives, which a tier swap could
# not guarantee. This probe therefore asserts the DRAIN MECHANISM EXISTS AND IS
# CALLABLE, not that one particular implementation of it is present.
print("MONO=%s" % ("built" if callable(getattr(m, "_drain_hue", None)) else "none"))

NOW = 1785869500
def colours(tier):
    seen = NOW - 10 if tier == "online" else (NOW - 200000 if tier == "away" else None)
    row = [{"handle": "zed", "haid": "haid:zed.x-1", "tier": tier,
            "online": tier == "online", "last_seen_ts": seen,
            "last_commit_ts": NOW - 90000, "sources": ["git"]}]
    out = m.team_columns(row, 120, 0, NOW)
    s = out if isinstance(out, str) else "\n".join(map(str, out))
    return sorted(set(re.findall(r"38;2;[0-9;]+", s)))

on = colours("online")
for t in ("away", "contributed", "member"):
    print("%s=%s" % (t, "distinct" if colours(t) != on else "IDENTICAL"))
print("online_has_hue=%s" % ("yes" if len(on) > 1 else "no"))

# A drained sigil must still be a FACE. The first drain used the MONO tier, which removes
# colour outright, so an absent teammate rendered as blank `▄▄▄▄▄▄▄▄` bars — recognisable
# as nobody. Draining is DESATURATION: the hue goes, the structure stays.
import hmd_sigil as SIG
strip = SIG.eye_strip("haid:probe.x-1", m.CAPS)
drained = m._drain_hue(strip)
shades = sorted(set(re.findall(r"38;2;(\d+);(\d+);(\d+)", "".join(drained))))
print("drain_shades=%d" % len(shades))
print("drain_all_grey=%s" % ("yes" if all(a == b == c for a, b, c in shades) else "no"))
PY
)"

# 1. The mono tier must actually build. None means the drain is dead code.
case "$probe" in
  *"MONO=built"*) ok ;;
  *) bad "_MONO_CAPS is None — the presence drain cannot run at all ($probe)" ;;
esac

# 2. Every absent tier must be visually distinct from online. This is the property.
for t in away contributed member; do
  case "$probe" in
    *"$t=distinct"*) ok ;;
    *"$t=IDENTICAL"*) bad "$t renders IDENTICALLY to online — an absent person reads as present" ;;
    *) bad "could not determine the $t tier's colours — an unverifiable check is not a pass" ;;
  esac
done

# 3. The drained strip must retain STRUCTURE — more than one shade — or the face is gone.
case "$probe" in
  *"drain_shades=0"*|*"drain_shades=1"*) bad "a drained sigil collapsed to one shade — the face is gone, not drained" ;;
  *"drain_shades="*) ok ;;
  *) bad "could not measure the drained sigil's shades" ;;
esac
case "$probe" in
  *"drain_all_grey=yes"*) ok ;;
  *) bad "a drained sigil still carries a non-grey pixel — the identity hue did not drain" ;;
esac

# 4. Online must carry MORE than the faint hue, or "distinct" would be trivially
#    satisfied by draining everything, including the people who ARE here.
case "$probe" in
  *"online_has_hue=yes"*) ok ;;
  *) bad "the online tier carries no identity hue — presence is not signalled either" ;;
esac

printf '\n  %s%d passed, %d failed\033[0m\n' \
  "$([ "$FAIL" -eq 0 ] && printf '\033[32m' || printf '\033[31m')" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
