#!/usr/bin/env bash
# test/heimdall-dream-bundle.test.sh — acceptance for the hmd-dream signing identity.
#
# WHY THIS EXISTS. heimdall-dream-bundle builds a PRIVATE, ad-hoc-signed copy of bash
# under its own identifier (dev.runheimdall.hmd-dream), so a Full Disk Access grant can
# land on exactly one thing instead of on the shared system /bin/bash every script on the
# machine also runs through. This suite proves the artifact actually works, is
# reproducible (so an unrelated rebuild does not silently invalidate a grant), and that a
# GENUINE identity change is both recorded and detectable (so one silently CAN).
#
# FALSIFIABLE claims proven:
#   (1) build is REPRODUCIBLE: two builds into different directories, from the same
#       source interpreter, produce the BYTE-IDENTICAL CDHash.
#   (2) the built bundle actually RUNS (a bare unsigned copy of /bin/bash is SIGKILLed;
#       ad-hoc signing inside a bundle is what fixes that — this proves the fix holds).
#   (3) Info.plist resolves BOTH CFBundleName and CFBundleDisplayName to "hmd-dream" —
#       what Full Disk Access shows the operator, not a raw path.
#   (4) `identity` reports exists=false before a build and exists=true with a matching
#       cdhash after one — read live from disk, never a stale cache.
#   (5) a build persists dream-identity.json with the same cdhash `build --json` reports.
#   (6) REBUILDING FROM AN UNCHANGED SOURCE reports changed=false — drift detection does
#       not cry wolf on a routine reinstall that changed nothing.
#   (7) REBUILDING FROM A DIFFERENT SOURCE BINARY reports changed=true and records the
#       prior cdhash as previous_cdhash — this is what lets heimdall-dream-permission
#       notice a lapsed grant instead of assuming a past grant holds forever.
#   (8) usage errors (no command / unknown command) exit 2, matching the other dream-*
#       tools' contract.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUNDLE="$ROOT/bin/heimdall-dream-bundle"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -x "$BUNDLE" ] || { echo "FATAL: $BUNDLE not executable" >&2; exit 2; }
[ "$(uname -s)" = "Darwin" ] || { echo "FATAL: hmd-dream is a macOS-only artifact" >&2; exit 2; }
command -v codesign >/dev/null 2>&1 || { echo "FATAL: codesign not found" >&2; exit 2; }

WORK="$(mktemp -d -t "dream-bundle-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export HEIMDALL_HOME="$WORK/home"
mkdir -p "$HEIMDALL_HOME"

field() { # field <json-text> <key> — same shape as the tool's own read_field
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\(.*\)\"[[:space:]]*,\{0,1\}[[:space:]]*\$/\1/p" | head -1
}

echo "hmd-dream bundle acceptance"
echo "=========================="

# ---- (1) build is reproducible across different --out directories ----------------
D1="$WORK/out1"
D2="$WORK/out2"
mkdir -p "$D1" "$D2"

B1RC=0
B1JSON="$("$BUNDLE" build --out "$D1" --json 2>"$WORK/b1.err")" || B1RC=$?
B2RC=0
B2JSON="$("$BUNDLE" build --out "$D2" --json 2>"$WORK/b2.err")" || B2RC=$?

if [ "$B1RC" -eq 0 ] && [ "$B2RC" -eq 0 ]; then
  ok "(1) both builds exit 0"
else
  bad "(1) a build failed: rc1=$B1RC rc2=$B2RC $(cat "$WORK/b1.err" "$WORK/b2.err" 2>/dev/null)"
fi

CDHASH1="$(field "$B1JSON" cdhash)"
CDHASH2="$(field "$B2JSON" cdhash)"

if [ -n "$CDHASH1" ] && [ "$CDHASH1" = "$CDHASH2" ]; then
  ok "(1) identical CDHash across two different --out directories ($CDHASH1)"
else
  bad "(1) CDHash differs across directories: [$CDHASH1] vs [$CDHASH2]"
fi

# ---- (2) the built bundle actually runs, not SIGKILLed ---------------------------
EXEC1="$D1/hmd-dream.app/Contents/MacOS/hmd-dream"
RUN_RC=0
RUN_OUT="$("$EXEC1" -c 'echo alive' 2>&1)" || RUN_RC=$?

if [ "$RUN_RC" -eq 0 ] && [ "$RUN_OUT" = "alive" ]; then
  ok "(2) signed bundle executable runs (bare unsigned bash would be SIGKILLed)"
else
  bad "(2) signed bundle executable failed to run: rc=$RUN_RC out=$RUN_OUT"
fi

# ---- (3) Info.plist names it "hmd-dream" for both name keys ----------------------
PLIST1="$D1/hmd-dream.app/Contents/Info.plist"
DISPNAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST1" 2>/dev/null || true)"
BNAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST1" 2>/dev/null || true)"

if [ "$DISPNAME" = "hmd-dream" ] && [ "$BNAME" = "hmd-dream" ]; then
  ok "(3) CFBundleDisplayName and CFBundleName both read back as hmd-dream"
else
  bad "(3) display name wrong: CFBundleDisplayName=[$DISPNAME] CFBundleName=[$BNAME]"
fi

# ---- (4) identity: exists=false before a build, exists=true with matching cdhash after
D3="$WORK/out3"
mkdir -p "$D3"

I0RC=0
I0JSON="$("$BUNDLE" identity --out "$D3" --json 2>/dev/null)" || I0RC=$?

if [ "$I0RC" -ne 0 ] && printf '%s' "$I0JSON" | grep -q '"exists": "false"'; then
  ok "(4) identity on an unbuilt directory reports exists=false and a non-zero exit"
else
  bad "(4) identity on an unbuilt directory: rc=$I0RC json=$I0JSON"
fi

"$BUNDLE" build --out "$D3" >/dev/null

I1RC=0
I1JSON="$("$BUNDLE" identity --out "$D3" --json 2>/dev/null)" || I1RC=$?
ICDHASH="$(field "$I1JSON" cdhash)"

if [ "$I1RC" -eq 0 ] && printf '%s' "$I1JSON" | grep -q '"exists": "true"' && [ "$ICDHASH" = "$CDHASH1" ]; then
  ok "(4) identity on a built directory reports exists=true with the same cdhash build produced"
else
  bad "(4) identity after build: rc=$I1RC cdhash=[$ICDHASH] expected=[$CDHASH1]"
fi

# ---- (5) dream-identity.json is persisted under HEIMDALL_HOME --------------------
IDENT_FILE="$HEIMDALL_HOME/dream-identity.json"
if [ -f "$IDENT_FILE" ] \
   && grep -q '"identifier": "dev.runheimdall.hmd-dream"' "$IDENT_FILE" \
   && grep -q "\"cdhash\": \"$CDHASH1\"" "$IDENT_FILE"; then
  ok "(5) dream-identity.json persisted with the matching identifier and cdhash"
else
  bad "(5) dream-identity.json missing or mismatched: $(cat "$IDENT_FILE" 2>/dev/null || echo '<absent>')"
fi

# ---- (6) rebuilding from an UNCHANGED source reports changed=false ---------------
B1BRC=0
B1BJSON="$("$BUNDLE" build --out "$D1" --json 2>/dev/null)" || B1BRC=$?

if [ "$B1BRC" -eq 0 ] && printf '%s' "$B1BJSON" | grep -q '"changed": "false"'; then
  ok "(6) rebuilding from the same source binary reports changed=false"
else
  bad "(6) unchanged rebuild wrongly reported drift: $B1BJSON"
fi

# ---- (7) rebuilding from a DIFFERENT source binary reports changed=true ----------
DRIFT_RC=0
DRIFT_JSON="$(HEIMDALL_DREAM_BUNDLE_BASH=/bin/cat "$BUNDLE" build --out "$D1" --json 2>/dev/null)" || DRIFT_RC=$?
DRIFT_CDHASH="$(field "$DRIFT_JSON" cdhash)"
DRIFT_PREV="$(field "$DRIFT_JSON" previous_cdhash)"

if [ "$DRIFT_RC" -eq 0 ] \
   && printf '%s' "$DRIFT_JSON" | grep -q '"changed": "true"' \
   && [ "$DRIFT_PREV" = "$CDHASH1" ] \
   && [ -n "$DRIFT_CDHASH" ] && [ "$DRIFT_CDHASH" != "$CDHASH1" ]; then
  ok "(7) rebuilding from a different source binary reports changed=true with the right previous_cdhash"
else
  bad "(7) drift not detected correctly: rc=$DRIFT_RC prev=[$DRIFT_PREV] want=[$CDHASH1] new=[$DRIFT_CDHASH] $DRIFT_JSON"
fi

# ---- (8) usage errors exit 2, matching the other dream-* tools' contract --------
NOARGRC=0
"$BUNDLE" >/dev/null 2>&1 || NOARGRC=$?
BADCMDRC=0
"$BUNDLE" bogus >/dev/null 2>&1 || BADCMDRC=$?

if [ "$NOARGRC" -eq 2 ] && [ "$BADCMDRC" -eq 2 ]; then
  ok "(8) no-command and unknown-command both exit 2"
else
  bad "(8) usage exit codes wrong: no-arg=$NOARGRC bad-cmd=$BADCMDRC"
fi

echo "------------------------------"
if [ "$FAIL" -eq 0 ]; then
  printf "dream-bundle: \033[32m%d passed\033[0m, 0 failed\n" "$PASS"
else
  printf "dream-bundle: %d passed, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
  exit 1
fi
