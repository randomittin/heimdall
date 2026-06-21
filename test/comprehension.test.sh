#!/usr/bin/env bash
# test/comprehension.test.sh — SI-1 acceptance for the comprehension capsule.
#
# Proves, against REAL temp repos and the REAL structural-scan engine (no canned
# fields), the orient-once-reuse-many contract:
#   (a) first `comprehend` on a temp repo WRITES a well-formed capsule (`jq -e .`)
#       carrying every documented field, with REAL derived values (architecture,
#       build/test commands, languages, key modules);
#   (b) a second `load` on the UNCHANGED repo returns the cached capsule and does
#       NOT re-derive — asserted via the derivation COUNTER (stays at #1) and the
#       "loaded:cached" signal (exit 0);
#   (c) a structural change (new top-level module / changed manifest) makes `load`
#       signal STALE (exit 3) → `comprehend` re-derives (counter advances);
#   (d) a corrupt capsule degrades gracefully: `load` signals re-derive (exit 3,
#       no crash) and `comprehend` recovers a well-formed capsule.
# Plus: a missing capsule is "missing" (re-derive), and HEIMDALL_HOME relocates
# the capsule (no baked path).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-comprehend"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON-shape assertions" >&2; exit 2; }
[ -x "$CMD" ] || { echo "FATAL: $CMD not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "comprehend-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── build a realistic temp repo (a JS/TS project with src + tests + manifest) ──
REPO="$WORK/proj"
mkdir -p "$REPO/src" "$REPO/test"
cat > "$REPO/package.json" <<'EOF'
{ "name": "demo", "version": "1.0.0",
  "scripts": { "build": "tsc -p .", "test": "jest" } }
EOF
cat > "$REPO/src/index.ts" <<'EOF'
export function greet(name: string): string { return "hi " + name; }
EOF
cat > "$REPO/test/index.test.ts" <<'EOF'
import { greet } from "../src/index";
test("greet", () => { expect(greet("x")).toBe("hi x"); });
EOF

CAPSULE="$REPO/.heimdall/context.json"

# ── (a) first comprehend writes a well-formed capsule with all fields ─────────
"$CMD" comprehend "$REPO" >/dev/null 2>&1
REQUIRED='["schema_version","repo","generated_at","fingerprint","languages","architecture","key_modules","entry_points","conventions","manifests","build_commands","test_commands","derivation"]'
if jq -e . "$CAPSULE" >/dev/null 2>&1 \
   && jq -e --argjson req "$REQUIRED" '. as $r | ($req | all(. as $k | ($r | has($k))))' "$CAPSULE" >/dev/null \
   && jq -e '(.derivation.count == 1) and (.derivation.method == "structural-scan")' "$CAPSULE" >/dev/null \
   && jq -e '(.languages | index("typescript")) and (.build_commands | index("npm run build")) and (.test_commands | index("npm test"))' "$CAPSULE" >/dev/null \
   && jq -e '(.architecture | test("typescript")) and (.manifests | index("package.json"))' "$CAPSULE" >/dev/null; then
  ok "(a) first comprehend writes a well-formed capsule with all documented + REAL fields (count=1)"
else
  bad "(a) capsule malformed or missing fields/derived values"; jq . "$CAPSULE" 2>/dev/null || cat "$CAPSULE" 2>/dev/null
fi

# capture the first-derivation fingerprint + count for the reuse assertions.
FP1="$(jq -r '.fingerprint' "$CAPSULE")"

# ── (b) load on the UNCHANGED repo returns cached, does NOT re-derive ─────────
set +e
"$CMD" load "$REPO" >/dev/null 2>&1
LOAD_RC=$?
set -e
COUNT_AFTER_LOAD="$(jq -r '.derivation.count' "$CAPSULE")"
# Also prove `comprehend` on the unchanged repo REUSES (counter must not advance).
"$CMD" comprehend "$REPO" >/dev/null 2>&1
COUNT_AFTER_RECOMPREHEND="$(jq -r '.derivation.count' "$CAPSULE")"
if [ "$LOAD_RC" -eq 0 ] && [ "$COUNT_AFTER_LOAD" = "1" ] && [ "$COUNT_AFTER_RECOMPREHEND" = "1" ]; then
  ok "(b) load on unchanged repo = loaded:cached (exit 0), did NOT re-derive (counter stays #1)"
else
  bad "(b) load re-derived or wrong exit: load_rc=$LOAD_RC count_after_load=$COUNT_AFTER_LOAD count_after_recomprehend=$COUNT_AFTER_RECOMPREHEND"
fi

# ── (c) structural change → load signals stale → re-derive (counter advances) ─
# Add a NEW top-level module; this flips the structural fingerprint.
mkdir -p "$REPO/api"
cat > "$REPO/api/route.ts" <<'EOF'
export function route(p: string): string { return "/" + p; }
EOF
FP2="$("$CMD" fingerprint "$REPO" 2>/dev/null)"
set +e
"$CMD" load "$REPO" >/dev/null 2>&1
STALE_RC=$?
set -e
# Now re-derive: counter must advance to 2, fingerprint must update.
"$CMD" comprehend "$REPO" >/dev/null 2>&1
COUNT_AFTER_REDERIVE="$(jq -r '.derivation.count' "$CAPSULE")"
NEW_HAS_API="$(jq -r '(.key_modules | map(.path) | index("api")) != null' "$CAPSULE")"
if [ "$STALE_RC" -eq 3 ] && [ "$FP1" != "$FP2" ] && [ "$COUNT_AFTER_REDERIVE" = "2" ] && [ "$NEW_HAS_API" = "true" ]; then
  ok "(c) structural change → load signals stale (exit 3) → re-derive (counter #1→#2, new module captured)"
else
  bad "(c) staleness wrong: stale_rc=$STALE_RC fp_changed=$([ "$FP1" != "$FP2" ] && echo yes || echo no) count=$COUNT_AFTER_REDERIVE has_api=$NEW_HAS_API"
fi

# ── (c2) a CHANGED MANIFEST also invalidates (content hash, not just file list) ─
FP_BEFORE_MAN="$("$CMD" fingerprint "$REPO" 2>/dev/null)"
cat > "$REPO/package.json" <<'EOF'
{ "name": "demo", "version": "2.0.0",
  "scripts": { "build": "tsc -p .", "test": "vitest", "lint": "eslint ." } }
EOF
FP_AFTER_MAN="$("$CMD" fingerprint "$REPO" 2>/dev/null)"
set +e
"$CMD" load "$REPO" >/dev/null 2>&1
MAN_RC=$?
set -e
if [ "$MAN_RC" -eq 3 ] && [ "$FP_BEFORE_MAN" != "$FP_AFTER_MAN" ]; then
  ok "(c2) a changed manifest (package.json content) invalidates the capsule → load signals stale"
else
  bad "(c2) manifest-change staleness not detected: rc=$MAN_RC fp_changed=$([ "$FP_BEFORE_MAN" != "$FP_AFTER_MAN" ] && echo yes || echo no)"
fi
"$CMD" comprehend "$REPO" >/dev/null 2>&1   # restore a fresh capsule

# ── (d) corrupt capsule → graceful re-derive, no crash ────────────────────────
printf 'this is not valid json {{{ \x00 broken' > "$CAPSULE"
set +e
"$CMD" load "$REPO" >/dev/null 2>&1
CORRUPT_RC=$?
"$CMD" comprehend "$REPO" >/dev/null 2>&1
RECOVER_RC=$?
set -e
if [ "$CORRUPT_RC" -eq 3 ] && [ "$RECOVER_RC" -eq 0 ] && jq -e '.fingerprint and .derivation.count' "$CAPSULE" >/dev/null 2>&1; then
  ok "(d) corrupt capsule → load signals re-derive (exit 3, no crash) → comprehend recovers a well-formed capsule"
else
  bad "(d) corrupt handling wrong: corrupt_rc=$CORRUPT_RC recover_rc=$RECOVER_RC"; cat "$CAPSULE" 2>/dev/null | head -3
fi

# ── (e) missing capsule → "missing" status (re-derive), no crash ──────────────
REPO2="$WORK/empty"
mkdir -p "$REPO2/lib"
printf 'def f():\n    return 1\n' > "$REPO2/lib/core.py"
# a pyproject manifest so build/test commands are legitimately inferable.
printf '[project]\nname = "pkg"\nversion = "0.1.0"\n' > "$REPO2/pyproject.toml"
set +e
MISS_STATUS="$("$CMD" status "$REPO2" 2>/dev/null)"
MISS_RC=$?
"$CMD" load "$REPO2" >/dev/null 2>&1
MISS_LOAD_RC=$?
set -e
if [ "$MISS_STATUS" = "missing" ] && [ "$MISS_RC" -eq 3 ] && [ "$MISS_LOAD_RC" -eq 3 ]; then
  ok "(e) missing capsule → status 'missing' + load exit 3 (re-derive), never a crash"
else
  bad "(e) missing handling wrong: status=$MISS_STATUS status_rc=$MISS_RC load_rc=$MISS_LOAD_RC"
fi

# ── (f) HEIMDALL_HOME relocates the capsule (no baked path) ────────────────────
ALT_HOME="$WORK/alt-home"
HEIMDALL_HOME="$ALT_HOME" "$CMD" comprehend "$REPO2" >/dev/null 2>&1
RELOC_PATH="$(HEIMDALL_HOME="$ALT_HOME" "$CMD" path "$REPO2" 2>/dev/null)"
if [ -f "$ALT_HOME/context.json" ] && [ "$RELOC_PATH" = "$ALT_HOME/context.json" ] \
   && jq -e '(.languages | index("python")) and (.test_commands | index("pytest"))' "$ALT_HOME/context.json" >/dev/null 2>&1; then
  ok "(f) HEIMDALL_HOME relocates the capsule to a non-default home (no baked path; python repo derived)"
else
  bad "(f) HEIMDALL_HOME relocation failed: path=$RELOC_PATH exists=$([ -f "$ALT_HOME/context.json" ] && echo yes || echo no)"
fi

echo
echo "  comprehension tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
