#!/usr/bin/env bash
#
# heimdall-identity.test.sh — acceptance harness for the file-based identity /
# sigil-seed resolver (bin/heimdall-identity).
#
# RJ's decision: a dev's watchman identity is a FILE they control, not a derived
# HAID. heimdall-identity is THE resolver every other surface (statusline sigil,
# team wall) calls. These proofs lock the contract:
#
#   1. SET + WHOAMI — `--set <handle>` writes <store>/identity.json; whoami then
#      reflects that handle + a deterministic seed (seed defaults to the handle).
#   2. SEED == SIGIL FOREVER — `hmd_sigil.py --seed "$(heimdall-identity)"` twice
#      is byte-identical; and the same handle SET in two independent stores yields
#      the SAME seed -> the SAME sigil (a chosen handle is a shareable identity).
#   3. --seed OVERRIDE — `--set <handle> --seed <s>` decouples the wall name from
#      the sigil seed (vanity handle, distinct seed).
#   4. FALLBACK CHAIN (never errors) — with NO identity.json the resolver falls
#      through HMD_HAID -> heimdall-haid -> $USER -> "you", always exit 0.
#   5. --json — machine record carries handle + seed + source for tool reads.
#   6. ATOMIC RE-SET — re-setting a handle replaces the record cleanly (valid JSON).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
ID="$REPO/bin/heimdall-identity"
SIGIL="$REPO/sentinels/hmd_sigil.py"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$ID" ]    || { echo "FATAL: heimdall-identity not executable at $ID"; exit 2; }
[ -f "$SIGIL" ] || { echo "FATAL: hmd_sigil.py not found at $SIGIL"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A clean env: pin the store to a fixture dir, strip any ambient HMD_HAID/USER so
# fallbacks are deterministic. id <store> -- <argv...> runs the resolver pinned.
id() {
  local store="$1"; shift; [ "$1" = "--" ] && shift
  HEIMDALL_IDENTITY_DIR="$store" "$ID" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "1. SET + WHOAMI (a chosen handle is written + reflected, seed deterministic):"
S1="$WORK/store1"
id "$S1" -- --set watchman-rj >/dev/null 2>&1
if [ -f "$S1/identity.json" ]; then
  ok "--set wrote $S1/identity.json"
else
  bad "--set did NOT create identity.json"
fi
if jq -e . "$S1/identity.json" >/dev/null 2>&1; then
  ok "identity.json is valid JSON"
else
  bad "identity.json is not valid JSON"
fi
WHO="$(id "$S1" -- whoami 2>/dev/null)"
if printf '%s' "$WHO" | grep -q "watchman-rj"; then
  ok "whoami reflects the chosen handle (watchman-rj)"
else
  bad "whoami does not reflect the set handle"
fi
if printf '%s' "$WHO" | grep -q "identity-file"; then
  ok "whoami reports source=identity-file once set"
else
  bad "whoami did not report the identity-file source"
fi
SEED="$(id "$S1" -- 2>/dev/null)"
if [ "$SEED" = "watchman-rj" ]; then
  ok "seed defaults to the handle (watchman-rj)"
else
  bad "seed is '$SEED', expected 'watchman-rj' (handle default)"
fi
HANDLE="$(id "$S1" -- --handle 2>/dev/null)"
if [ "$HANDLE" = "watchman-rj" ]; then
  ok "--handle prints the wall name (watchman-rj)"
else
  bad "--handle is '$HANDLE', expected 'watchman-rj'"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "2. SEED == SIGIL FOREVER (same handle -> same seed -> byte-identical sigil):"
SIG_A="$(python3 "$SIGIL" --seed "$(id "$S1" --)" --size compact 2>/dev/null)"
SIG_B="$(python3 "$SIGIL" --seed "$(id "$S1" --)" --size compact 2>/dev/null)"
if [ "$SIG_A" = "$SIG_B" ] && [ -n "$SIG_A" ]; then
  ok "two sigil renders from the resolved seed are byte-identical"
else
  bad "sigil renders differ (non-deterministic seed/sigil)"
fi
# A second, INDEPENDENT store set to the SAME handle must yield the SAME sigil —
# a chosen handle is a portable identity across machines/checkouts.
S2="$WORK/store2"
id "$S2" -- --set watchman-rj >/dev/null 2>&1
SIG_C="$(python3 "$SIGIL" --seed "$(id "$S2" --)" --size compact 2>/dev/null)"
if [ "$SIG_A" = "$SIG_C" ]; then
  ok "same handle in an independent store -> identical sigil (portable identity)"
else
  bad "same handle yielded a DIFFERENT sigil across stores"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "3. --seed OVERRIDE (vanity handle decoupled from the sigil seed):"
S3="$WORK/store3"
id "$S3" -- --set "RJ The Watcher" --seed rj-7f3a >/dev/null 2>&1
if [ "$(id "$S3" -- 2>/dev/null)" = "rj-7f3a" ]; then
  ok "seed honours --seed override (rj-7f3a)"
else
  bad "seed did not honour --seed override"
fi
if [ "$(id "$S3" -- --handle 2>/dev/null)" = "RJ The Watcher" ]; then
  ok "handle stays the chosen display name ('RJ The Watcher')"
else
  bad "handle did not preserve the display name"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "4. FALLBACK CHAIN (no identity.json — never errors, falls through cleanly):"
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"

# (a) HMD_HAID wins when present and no file.
rc=0
out="$(HEIMDALL_IDENTITY_DIR="$EMPTY" HMD_HAID="haid:fallback.mbp-1234" "$ID" 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "haid:fallback.mbp-1234" ]; then
  ok "no file + HMD_HAID set -> seed is the HMD_HAID (exit 0)"
else
  bad "HMD_HAID fallback failed (rc=$rc, out='$out')"
fi
# whoami reports the HMD_HAID source.
if HEIMDALL_IDENTITY_DIR="$EMPTY" HMD_HAID="haid:fallback.mbp-1234" "$ID" whoami 2>/dev/null | grep -q "HMD_HAID"; then
  ok "whoami reports source=HMD_HAID on that path"
else
  bad "whoami did not report the HMD_HAID source"
fi
# --handle derives the short human local-part from the HAID.
if [ "$(HEIMDALL_IDENTITY_DIR="$EMPTY" HMD_HAID="haid:fallback.mbp-1234" "$ID" --handle 2>/dev/null)" = "fallback" ]; then
  ok "--handle derives the short name from the HAID human part (fallback)"
else
  bad "--handle did not derive the short name from the HAID"
fi

# (b) No file, no HMD_HAID -> heimdall-haid current (a well-formed HAID) or $USER.
rc=0
out="$(HEIMDALL_IDENTITY_DIR="$EMPTY" HMD_HAID="" "$ID" 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
  ok "no file + no HMD_HAID -> a non-empty seed (heimdall-haid/USER), exit 0"
else
  bad "deep fallback failed (rc=$rc, out='$out')"
fi

# (c) Stripped to nothing (no file, no HMD_HAID, no heimdall-haid, no USER) -> "you".
BARE="$WORK/bare-bin"; mkdir -p "$BARE"
# A PATH with no heimdall-haid and an empty USER drives the resolver to "you".
rc=0
out="$(cd "$EMPTY" && env -i PATH="$(command -v jq | xargs dirname):/usr/bin:/bin" \
       HEIMDALL_IDENTITY_DIR="$EMPTY" "$ID" 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
  ok "fully-stripped env still resolves to a usable seed ('$out'), exit 0"
else
  bad "fully-stripped env errored or returned empty (rc=$rc, out='$out')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "5. --json (machine record: handle + seed + source):"
J="$(id "$S1" -- --json 2>/dev/null)"
if printf '%s' "$J" | jq -e '.handle == "watchman-rj" and .seed == "watchman-rj"' >/dev/null 2>&1; then
  ok "--json carries the resolved handle + seed"
else
  bad "--json record missing/incorrect handle or seed"
fi
if printf '%s' "$J" | jq -e 'has("source")' >/dev/null 2>&1; then
  ok "--json carries a source field"
else
  bad "--json record has no source field"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "6. ATOMIC RE-SET (re-setting a handle replaces the record cleanly):"
id "$S1" -- --set rebrand >/dev/null 2>&1
if jq -e '.handle == "rebrand" and .seed == "rebrand"' "$S1/identity.json" >/dev/null 2>&1; then
  ok "re-set replaced the record (handle=seed=rebrand), still valid JSON"
else
  bad "re-set did not cleanly replace the identity record"
fi

echo ""
echo "heimdall-identity.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
