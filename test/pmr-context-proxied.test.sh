#!/usr/bin/env bash
# test/pmr-context-proxied.test.sh — gates the PMR research fields `env.context_proxied`
# and `env.proxy_vendor` (bin/lib/pmr_corpus.py::project).
#
# WHY TWO FIELDS AND NOT ONE NAMED FOR COMPRESSION: the observable is base-URL
# REDIRECTION, nothing more. An enterprise LiteLLM/Bedrock gateway sets
# ANTHROPIC_BASE_URL and compresses nothing, so a field named for compression would
# be an overclaim on every enterprise row. `context_proxied` states exactly what was
# observed; `proxy_vendor` names a vendor ONLY when the env names one, and is ABSENT
# otherwise — an "unknown" tag would assert a vendor on every unproxied session.
#
# THE ASSERTION THAT PROTECTS THE RESEARCH DATA is section (D): a corporate
# HTTPS_PROXY must NOT set context_proxied. Corporate egress proxies set
# HTTP_PROXY/HTTPS_PROXY/ALL_PROXY/NO_PROXY (and the lowercase forms curl reads) and
# redirect no base URL. Counting them would fire `true` for every developer behind a
# corporate network and plant an enterprise-correlated bias in a corpus whose whole
# purpose is to answer whether proxying correlates with deny classes. A confounded
# signal is worse than no signal, so the exclusion is gated, not merely intended.
#
# NO EGRESS IS ADDED HERE. PMR is written to a LOCAL spool only in this release
# (DATA.md:15, bin/lib/pmr_corpus.py:10), so these fields are two more locally-spooled
# booleans/tags — the record still goes nowhere, and IDENTITY.md:32-38 stands.
#
# Sections:
#   (A) SHARED SOURCE — the detected vars are a strict SUBSET of the routing-var
#       enumeration in bin/lib/hmd-gate-endpoint.sh, so the research field and the
#       gates-read-raw defense cannot drift apart. The generic proxy vars are proven
#       ABSENT from the subset.
#   (B) context_proxied TRUE on each base-URL redirect, FALSE on a clean env.
#   (C) proxy_vendor == "headroom" on HEADROOM_*, ABSENT otherwise.
#   (D) FALSIFIER — the corporate proxy vars ALONE leave context_proxied FALSE.
#   (E) the projected record still passes the zero-content CARDINAL guard, and the
#       REAL emit path spools a record carrying both fields.
#
# Exit 0 = every executed assertion passed. Non-zero = a regression.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIBDIR="$ROOT/bin/lib"
LIB="$LIBDIR/pmr_corpus.py"
GATE_SH="$LIBDIR/hmd-gate-endpoint.sh"
CLI="$ROOT/bin/heimdall-telemetry-corpus"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }
[ -f "$GATE_SH" ] || { echo "FATAL: $GATE_SH missing" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "hmd-pmr-proxied-test")"
trap 'rm -rf "$WORK"' EXIT

# The generic egress-proxy vars that must NEVER move context_proxied — the corporate
# network shape the exclusion exists to keep out of the corpus.
CORP_VARS="HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy"

# proj [VAR=val …] — run project() under a SCRUBBED ambient env (`env -i`: the
# developer's own exported proxy vars must never decide a test's verdict) and print
# the record's `env` block as COMPACT sorted JSON. PATH is carried because python3
# needs it; HMDLIB points the import at the library under test.
proj() {
  env -i PATH="$PATH" HMDLIB="$LIBDIR" "$@" "$PY" - <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["HMDLIB"])
import pmr_corpus as pmr
rec = pmr.project({"ids": {"team_id": "t", "repo": "r"}})
print(json.dumps(rec["env"], sort_keys=True, separators=(",", ":")))
PYEOF
}

# assertions over the compact JSON — no jq dependency (the suite must run on a bare mac).
is_true()   { case "$2" in *'"context_proxied":true'*)  ok "$1" ;; *) bad "$1 -- got: $2" ;; esac; }
is_false()  { case "$2" in *'"context_proxied":false'*) ok "$1" ;; *) bad "$1 -- got: $2" ;; esac; }
vendor_is() { case "$3" in *"\"proxy_vendor\":\"$2\""*) ok "$1" ;; *) bad "$1 -- got: $3" ;; esac; }
no_vendor() { case "$2" in *'"proxy_vendor"'*) bad "$1 -- got: $2" ;; *) ok "$1" ;; esac; }

printf "\n=== PMR research fields: context_proxied / proxy_vendor ===\n"

# ─────────────────────────────────────────────────────────────────────────────
# (A) SHARED SOURCE — subset of the gate's routing-var enumeration.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[A] the detected vars are a strict subset of _HMD_GATE_ROUTING_VARS\n"

SUBSET="$(env -i PATH="$PATH" HMDLIB="$LIBDIR" "$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["HMDLIB"])
import pmr_corpus as pmr
print(" ".join(pmr._PROXY_BASE_URL_VARS))
PYEOF
)"

# The gate file's enumeration, read as the literal block between the assignment and
# its closing quote — so a var added ANYWHERE else in that file cannot fake a match.
GATE_VARS="$(sed -n '/^_HMD_GATE_ROUTING_VARS="/,/^"$/p' "$GATE_SH" | sed '1d;$d')"

if [ -n "$SUBSET" ] && [ -n "$GATE_VARS" ]; then
  ok "(A1) both enumerations are readable (pmr subset + gate routing vars)"
else
  bad "(A1) an enumeration is EMPTY -- subset='$SUBSET' gate_vars='$GATE_VARS'"
fi

NOT_SHARED=""
for v in $SUBSET; do
  grep -qx "$v" <<<"$GATE_VARS" || NOT_SHARED="$NOT_SHARED $v"
done
if [ -z "$NOT_SHARED" ]; then
  ok "(A2) EVERY detected var is also scrubbed by hmd-gate-endpoint.sh -- the research field and the gates-read-raw defense read the same list"
else
  bad "(A2) a detected var is NOT in the gate enumeration (drift):$NOT_SHARED"
fi

# The subset is PINNED. Widening it must be a deliberate edit to this line, reviewed
# with the bias argument in front of the reviewer -- never an accidental include.
EXPECT_SUBSET="ANTHROPIC_BASE_URL ANTHROPIC_API_URL ANTHROPIC_DEFAULT_BASE_URL CLAUDE_CODE_BASE_URL"
if [ "$SUBSET" = "$EXPECT_SUBSET" ]; then
  ok "(A3) the subset is EXACTLY the four base-URL redirect vars"
else
  bad "(A3) subset drifted -- want '$EXPECT_SUBSET' got '$SUBSET'"
fi

LEAKED=""
for v in $CORP_VARS; do
  case " $SUBSET " in *" $v "*) LEAKED="$LEAKED $v" ;; esac
done
if [ -z "$LEAKED" ]; then
  ok "(A4) NO generic egress-proxy var is in the subset -- the enterprise-bias vector is excluded at the source"
else
  bad "(A4) a generic egress-proxy var entered the subset:$LEAKED"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (B) context_proxied — TRUE on a redirect, FALSE on a clean env.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[B] context_proxied tracks a base-URL redirect\n"

CLEAN="$(proj)"
is_false "(B1) a CLEAN env projects context_proxied=false" "$CLEAN"

for v in $EXPECT_SUBSET; do
  is_true "(B2:$v) a redirect via $v projects context_proxied=true" \
          "$(proj "$v=https://gw.example.internal/v1")"
done

# An exported-but-EMPTY var redirects nothing -- it must not count as a proxy.
is_false "(B3) an exported-but-EMPTY ANTHROPIC_BASE_URL is NOT a redirect" \
         "$(proj ANTHROPIC_BASE_URL=)"

# ─────────────────────────────────────────────────────────────────────────────
# (C) proxy_vendor — named only when the env names it.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[C] proxy_vendor is present only when a vendor namespace is\n"

no_vendor "(C1) a CLEAN env emits NO proxy_vendor key (absent, never 'unknown')" "$CLEAN"

HR="$(proj HEADROOM_BASE_URL=https://hr.example.internal)"
vendor_is "(C2) HEADROOM_BASE_URL names the vendor 'headroom'" "headroom" "$HR"

# Detection is a PURE ENV READ -- any var in the namespace names the vendor, and the
# tool need never be installed for the field to be correct.
HR2="$(proj HEADROOM_PROXY_URL=https://hr.example.internal)"
vendor_is "(C3) HEADROOM_PROXY_URL also names 'headroom' (namespace, not one var)" "headroom" "$HR2"

no_vendor "(C4) a base-URL redirect with NO vendor namespace emits NO proxy_vendor" \
          "$(proj ANTHROPIC_BASE_URL=https://gw.example.internal/v1)"

# ─────────────────────────────────────────────────────────────────────────────
# (D) THE FALSIFIER — a corporate egress proxy is NOT a context proxy.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[D] FALSIFIER: corporate proxy vars alone do NOT set context_proxied\n"

is_false "(D1) HTTPS_PROXY ALONE leaves context_proxied=false -- the assertion that keeps enterprise bias out of the corpus" \
         "$(proj HTTPS_PROXY=http://proxy.corp.example:3128)"

ALL_CORP="$(proj HTTP_PROXY=http://proxy.corp.example:3128 \
                 HTTPS_PROXY=http://proxy.corp.example:3128 \
                 ALL_PROXY=socks5://proxy.corp.example:1080 \
                 NO_PROXY=.corp.example \
                 http_proxy=http://proxy.corp.example:3128 \
                 https_proxy=http://proxy.corp.example:3128 \
                 all_proxy=socks5://proxy.corp.example:1080 \
                 no_proxy=.corp.example)"
is_false "(D2) ALL EIGHT corporate proxy vars at once still leave context_proxied=false" "$ALL_CORP"
no_vendor "(D3) the corporate-proxy env names NO vendor" "$ALL_CORP"

# A corporate proxy alongside a REAL redirect must not mask the redirect either.
is_true "(D4) a real redirect is still detected THROUGH a corporate proxy env" \
        "$(proj HTTPS_PROXY=http://proxy.corp.example:3128 ANTHROPIC_BASE_URL=https://gw.example.internal/v1)"

# ─────────────────────────────────────────────────────────────────────────────
# (E) the guard still passes, and the REAL emit path spools both fields.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[E] zero-content guard + the real emit path\n"

GUARD="$(env -i PATH="$PATH" HMDLIB="$LIBDIR" \
  ANTHROPIC_BASE_URL=https://gw.example.internal/v1 \
  HEADROOM_BASE_URL=https://hr.example.internal "$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["HMDLIB"])
import pmr_corpus as pmr
rec = pmr.project({"ids": {"team_id": "t", "repo": "r"}})
ok, violations = pmr.assert_zero_content(rec)
print("OK" if ok else "BAD %s" % violations)
PYEOF
)"
if [ "$GUARD" = "OK" ]; then
  ok "(E1) a PROXIED record still passes the zero-content CARDINAL guard"
else
  bad "(E1) the proxied record TRIPPED the zero-content guard: $GUARD"
fi

CORPUS_HOME="$WORK/emit"
EMIT="$(printf '%s' '{"attestation":{"claims":{"file_count":1,"unit_count":1,
  "files":[{"path":"src/api/users.js","lang":"js"}]}},
 "ids":{"team_id":"team-abc","repo":"acme/widgets"},
 "diff":{"loc_added":4,"loc_deleted":1,"hunks":1},
 "agent":{"tool":"claude-code","model_family":"claude","version":"opus-5"},
 "verify":{"gates_run":["secret-scan"],"verdict":"pass"},
 "human":{"merged":true,"overridden":false},
 "env":{"os_class":"darwin","ci":false,"hmd_version":"2.3.8"}}' \
  | HEIMDALL_CORPUS_HOME="$CORPUS_HOME" \
    ANTHROPIC_BASE_URL="https://gw.example.internal/v1" \
    HEADROOM_BASE_URL="https://hr.example.internal" "$CLI" emit 2>&1)"

REC="$(ls "$CORPUS_HOME/telemetry/pmr/spool"/*.json 2>/dev/null | head -1)"
if grep -q '"emitted": *true' <<<"$EMIT" && [ -n "$REC" ]; then
  ok "(E2) the real emit path queued the record to the LOCAL spool (no egress -- the spool IS the queue)"
else
  bad "(E2) emit did not spool a record: $EMIT"
fi

if [ -n "$REC" ] && grep -q '"context_proxied": *true' "$REC" && grep -q '"proxy_vendor": *"headroom"' "$REC"; then
  ok "(E3) the SPOOLED record carries context_proxied=true and proxy_vendor=headroom"
else
  bad "(E3) the spooled record is missing the research fields: $(cat "$REC" 2>/dev/null)"
fi

printf "\n--------------------------------------------------------------------\n"
printf "pmr-context-proxied: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
