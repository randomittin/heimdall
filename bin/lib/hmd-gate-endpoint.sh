#!/usr/bin/env bash
# hmd-gate-endpoint.sh — THE JUDGMENT INVARIANT.
#
#   Generation may run compressed; judgment may not.
#
# THE THREAT. A context-compressing proxy (e.g. Headroom — a LOCAL proxy that shrinks
# context on the way to the model) is wired in by exporting routing env vars into the
# SHELL: ANTHROPIC_BASE_URL=http://127.0.0.1:<port>, HTTPS_PROXY=…, and friends. Every
# child process inherits them. That is FINE for generation: a compression-induced coding
# error is exactly the class of defect the gates exist to catch.
#
# It is NOT fine for a VERDICT. If the judge's inputs are compressed, the judge itself is
# corrupted, and a corrupted judge emits FALSE GREENS — the single failure mode this whole
# project exists to prevent. A false green is worse than no gate at all, because it is
# trusted.
#
# THE RULE. Every verdict-producing execution — oracle runs, gate runs, panel/verifier
# calls, falsify/mutation adjudication, any call whose output becomes a PASS/FAIL — runs
# with the model endpoint PINNED to the real provider and every proxy/routing var SCRUBBED
# from its environment. Immune to the ambient env, not merely defaulted away from it: a
# wrapped shell exports these globally, so "we don't set it" is not a defense.
#
# WHY SCRUB THE WHOLE GATE SUBPROCESS (not just a model client): the pin is applied at the
# gate-EXECUTION boundary, so it covers any model call made anywhere beneath the gate —
# today's gates are deterministic, and a gate that grows a model call tomorrow inherits the
# invariant for free rather than having to remember it.
#
# WHAT IS DELIBERATELY *NOT* SCRUBBED: credentials. CLAUDE_CODE_OAUTH_TOKEN /
# ANTHROPIC_API_KEY / CLAUDE_CONFIG_DIR pass through untouched — we neutralize ROUTING,
# never AUTH. Scrubbing auth would break the call, and a broken judge is not a fixed judge.
#
# USAGE:
#   . "$PLUGIN_DIR/bin/lib/hmd-gate-endpoint.sh"
#   hmd_gate_exec bash "$RUN_SH" --input "$fixture" --report "$report"
#   hmd_gate_exec "$VERDICT_CMD" "$id"
#
# Covered by test/gate-judgment-uncompressed.test.sh — a mock proxy that TAGS every
# response it serves; any gate call arriving there is RED.

# double-source guard (functions are idempotent; skip re-defining on re-source).
[ -n "${_HMD_GATE_ENDPOINT_SH:-}" ] && return 0 2>/dev/null || true
_HMD_GATE_ENDPOINT_SH=1

# THE PIN. A hardcoded constant, NOT `: "${X:=…}"` — the whole point of the invariant is
# that no environment variable can move a judge onto a proxy. Changing where judgment reads
# from is a deliberate source edit, reviewed like any other, never an ambient export.
HMD_PROVIDER_BASE_URL="https://api.anthropic.com"

# The routing vars a proxy exports to hijack traffic. Scrubbed from every gate child.
# Covers: the Anthropic/Claude-Code base-URL overrides, the generic HTTP proxy protocol
# (upper AND lower case — curl reads lower, most SDKs read upper), and Headroom's own
# namespace. NO_PROXY/no_proxy go too: with the proxies gone they are inert, and leaving a
# stale allowlist behind is just another lever on the judge's routing.
_HMD_GATE_ROUTING_VARS="
ANTHROPIC_BASE_URL
ANTHROPIC_API_URL
ANTHROPIC_DEFAULT_BASE_URL
CLAUDE_CODE_BASE_URL
HTTP_PROXY
HTTPS_PROXY
ALL_PROXY
NO_PROXY
http_proxy
https_proxy
all_proxy
no_proxy
HEADROOM_BASE_URL
HEADROOM_PROXY
HEADROOM_PROXY_URL
"

# hmd_gate_exec <cmd> [args…] — run a VERDICT-PRODUCING command with judgment pinned to
# the real provider and every routing var scrubbed. Returns the command's own exit status
# verbatim (callers read the gate's exit code as the verdict — we never mask it).
hmd_gate_exec() {
  [ "$#" -gt 0 ] || { echo "hmd_gate_exec: no command given" >&2; return 2; }
  local unset_args=() var
  for var in $_HMD_GATE_ROUTING_VARS; do
    unset_args+=(-u "$var")
  done
  # `env -u …` drops the inherited routing vars; the explicit assignment then pins the
  # endpoint. Order matters: the assignment is applied after the unsets, so the pin wins.
  env "${unset_args[@]}" ANTHROPIC_BASE_URL="$HMD_PROVIDER_BASE_URL" "$@"
}
