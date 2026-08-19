#!/usr/bin/env bash
# hmd-headroom-chain.sh — THE WRAP-CHAIN WIRE.
#
#   hmd wrap <tool>   ->   hmd setup   ->   headroom proxy   ->   <tool>
#
# This is the file that makes `wires[0]` in modules/headroom/manifest.json TRUE. Before it
# existed the manifest declared a `wrap-chain` wire, `bin/heimdall-wrap` contained no
# reference to the module, and `hmd modules add headroom` printed "RECORDED, not routed"
# in those words. hmd installed a proxy and connected it to nothing.
#
# ── WHAT IS ROUTED, AND WHAT IS NOT ───────────────────────────────────────────────────
# ONE variable is exported, to ONE child: ANTHROPIC_BASE_URL, on the tool `hmd wrap`
# launches. That is deliberate and it is the whole security argument:
#
#   ANTHROPIC_BASE_URL   re-points a MODEL client. Nothing else reads it. It reaches
#                        generation traffic and cannot reach anything else.
#   HTTPS_PROXY/ALL_PROXY  are NEVER set by this file. They would route EVERY request the
#                        session makes — control plane, enrollment, team, presence — through
#                        the rewriter. Setting them is how a "compression proxy" quietly
#                        becomes a man-in-the-middle on signed bytes. We do not set them, so
#                        invariant 2 holds BY CONSTRUCTION rather than by scrubbing.
#
# JUDGMENT is protected by hmd_gate_exec (bin/lib/hmd-gate-endpoint.sh), which unsets
# ANTHROPIC_BASE_URL and the HEADROOM_* namespace and pins the endpoint to the real
# provider. That scrub already existed; this file is the thing that finally makes it load-
# bearing, because until now there was no proxy for it to scrub.
#
# WHY THE SCRUB, AND NOT "ADAPT THE JUDGE TO THE CODEC": a judge reads the bytes that
# ARRIVE AT THE MODEL. Headroom compresses on the way OUT and the provider receives the
# compressed form — nothing decodes it before the model reads it. Lossless TRANSPORT
# compression (gzip) is safe for a judge precisely because HTTP decodes it before the
# application sees it; that is not this architecture. Measured here on a real gate-shaped
# payload: see test/headroom-wrap-chain.test.sh section 5.
#
# ── ABSENCE IS A SUPPORTED STATE, NEVER A DEPENDENCY ──────────────────────────────────
# Every failure path in this file returns non-zero with a reason and routes NOTHING. No
# headroom installed, module removed, opted out, port occupied by a stranger, proxy refuses
# to start, proxy starts and never becomes ready — all of them land on "run unproxied".
# There is no path here that can block a prompt, and no unbounded wait: readiness is polled
# with a hard ceiling, and every probe carries curl's own --max-time (macOS has no
# timeout(1), so the ceiling has to live in the loop and in the client).

[ -n "${_HMD_HEADROOM_CHAIN_SH:-}" ] && return 0 2>/dev/null || true
_HMD_HEADROOM_CHAIN_SH=1

# THE PROVIDER THE CHAIN MAY REACH. Same constant hmd_gate_exec pins judgment to, and it is
# checked at runtime rather than trusted: the proxy reports its own upstream on /health, and
# a proxy pointing anywhere else is refused. "No new destination" is thereby MEASURED from
# the running process, not asserted in a doc.
HMD_HEADROOM_UPSTREAM="https://api.anthropic.com"

# Headroom's own default port. Overridable by the operator through HEADROOM_PORT, which is
# the variable Headroom itself documents — we do not invent a second name for it.
HMD_HEADROOM_DEFAULT_PORT=8787

# Readiness ceiling: 60 polls x 0.25s = 15s. Measured cold start on this machine is ~2.2s.
# A ceiling is not a nicety here; it is the difference between "hmd is slow to start" and
# "hmd hangs", and only one of those is survivable.
HMD_HEADROOM_READY_POLLS=60

# Set by hmd_headroom_chain on success / failure. Read by the caller and by `hmd modules
# status headroom`, so the user can always see WHY they are or are not proxied.
HMD_HEADROOM_BASE_URL=""
HMD_HEADROOM_WHY=""

# ── the module's own state, read from the SAME place bin/heimdall-modules writes it ──────
# Deliberately not a second source of truth: `hmd modules remove headroom` deletes the
# receipt and routing stops on the next launch, with no extra bookkeeping to forget.
_hmd_headroom_state() { printf '%s' "${HMD_MODULES_STATE:-$1/.heimdall/modules}"; }

# hmd_headroom_installed <plugin_dir> — is the module actually added on this machine?
hmd_headroom_installed() {
  [ -f "$(_hmd_headroom_state "$1")/headroom/receipt.json" ]
}

# hmd_headroom_opted_out <plugin_dir> — has the operator declined?
# THREE writers, all real: the module tool's own optout record, the module-wide env switch
# bin/heimdall-modules already honours, and a chain-specific kill switch for the operator
# who wants Headroom installed but not on their wire.
hmd_headroom_opted_out() {
  case "${HMD_HEADROOM_DISABLE:-}" in 1|true|TRUE|yes|YES) return 0 ;; esac
  case ",${HMD_MODULE_OPTOUT:-}," in *",headroom,"*) return 0 ;; esac
  [ -f "$(_hmd_headroom_state "$1")/.modstate/headroom/optout.json" ] && return 0
  return 1
}

# hmd_headroom_bin — the Headroom CLI, or empty. HMD_HEADROOM_BIN is a test seam of the
# same species as HEIMDALL_TRACE_ORDER in bin/heimdall-wrap: it lets an acceptance suite
# drive this code against a recorder without a network or the real tool.
hmd_headroom_bin() {
  if [ -n "${HMD_HEADROOM_BIN:-}" ]; then
    [ -x "${HMD_HEADROOM_BIN}" ] && { printf '%s' "$HMD_HEADROOM_BIN"; return 0; }
    return 1
  fi
  local p
  p="$(command -v headroom 2>/dev/null || true)"
  [ -n "$p" ] && { printf '%s' "$p"; return 0; }
  # uv tool install puts it here and does not necessarily put it on a non-login PATH.
  [ -x "$HOME/.local/bin/headroom" ] && { printf '%s' "$HOME/.local/bin/headroom"; return 0; }
  return 1
}

hmd_headroom_port() {
  local p="${HEADROOM_PORT:-$HMD_HEADROOM_DEFAULT_PORT}"
  case "$p" in ''|*[!0-9]*) p="$HMD_HEADROOM_DEFAULT_PORT" ;; esac
  printf '%s' "$p"
}

# hmd_headroom_probe <port> — is a HEADROOM proxy answering there, pointed at OUR provider?
# Prints the upstream URL on success. Two refusals matter as much as the accept:
#   · a listener that is not headroom-proxy  -> we do not route a prompt into a stranger,
#   · a headroom pointed somewhere else      -> that is a NEW DESTINATION, which is exactly
#                                               what invariant 5 forbids.
hmd_headroom_probe() {
  local port="$1" body svc up
  body="$(curl -s --max-time 3 "http://127.0.0.1:$port/health" 2>/dev/null)" || return 1
  [ -n "$body" ] || return 1
  svc="$(printf '%s' "$body" | jq -r '.service // empty' 2>/dev/null)" || return 1
  [ "$svc" = "headroom-proxy" ] || return 1
  up="$(printf '%s' "$body" | jq -r '.checks.upstream.url // empty' 2>/dev/null)"
  [ "$up" = "$HMD_HEADROOM_UPSTREAM" ] || return 1
  printf '%s' "$up"
}

# ── the chain ─────────────────────────────────────────────────────────────────────────
# Returns 0 and sets HMD_HEADROOM_BASE_URL when generation traffic should be routed.
# Returns non-zero and sets HMD_HEADROOM_WHY in every other case. NEVER returns non-zero
# by way of an unbounded wait, and never writes to the repo.
hmd_headroom_chain() {
  local plugin_dir="$1" port bin logdir live
  HMD_HEADROOM_BASE_URL=""; HMD_HEADROOM_WHY=""

  if hmd_headroom_opted_out "$plugin_dir"; then
    HMD_HEADROOM_WHY="opted out — nothing is routed through Headroom"; return 1
  fi
  if ! hmd_headroom_installed "$plugin_dir"; then
    HMD_HEADROOM_WHY="the headroom module is not added — hmd modules add headroom"; return 1
  fi
  bin="$(hmd_headroom_bin)" || {
    HMD_HEADROOM_WHY="the headroom CLI is not on PATH — running unproxied"; return 1; }

  port="$(hmd_headroom_port)"

  # 1. ALREADY LIVE? Reuse it. A second proxy on a busy port would fail to bind anyway, and
  #    an operator who started `headroom proxy` by hand should keep the process they own.
  if live="$(hmd_headroom_probe "$port")"; then
    HMD_HEADROOM_BASE_URL="http://127.0.0.1:$port"
    HMD_HEADROOM_WHY="reusing the Headroom proxy already listening on $port (upstream $live)"
    return 0
  fi

  # 2. Something is on the port but it is NOT our proxy -> refuse. Routing a prompt into an
  #    unidentified listener is the one failure this whole module is supposed to prevent.
  if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null; then
    HMD_HEADROOM_WHY="port $port is answering but is not a Headroom proxy pointed at $HMD_HEADROOM_UPSTREAM — refusing to route"
    return 1
  fi

  # 3. Start one, detached, with its own log. Output goes to $HEIMDALL_HOME, never the repo.
  logdir="${HEIMDALL_HOME:-$HOME/.heimdall}/headroom"
  mkdir -p "$logdir" 2>/dev/null || {
    HMD_HEADROOM_WHY="cannot create $logdir — running unproxied"; return 1; }
  # Timeout-debt quarantine mitigation (upstream #1171/#2360). hmd launches with no
  # --mode flag, so Headroom's OWN default applies: CACHE mode (cli/proxy.py resolves
  # mode = flag > HEADROOM_MODE env > "cache", and this file sets neither). We do NOT
  # set HEADROOM_BACKGROUND_COMPRESSION here. It is off by default (opt-in,
  # fail-open) at the pinned version and we leave it there; the version-specific
  # reasoning for that is in the VERSION NOTE below.
  # HEADROOM_COMPRESSION_TIMEOUT_SECONDS is the lever that is real for cache mode: it
  # is consumed mode-agnostically — defined once in proxy/helpers.py:683-691 (default
  # "30") and read by every handler with no mode guard anywhere on it — so raising it
  # gives a cold-start-large request more wall-clock budget before Python's inability
  # to preempt a worker thread turns a slow compression into a leaked thread and a
  # quarantine that blocks OTHER concurrent sessions' compression too. It was raised to
  # 130s here — ~2x the worst synchronous run measured on this machine, 64.75s against
  # the 30s upstream default — on that reasoning, and it is now back at 30. The reason
  # for the reversal is a client-visible cost the "background worker budget" framing
  # missed entirely, set out under HEADROOM_COMPRESSION_TIMEOUT_SECONDS in the block
  # immediately above the launch line; read that before raising it again. The half of
  # the blast radius the raise was meant to reduce is genuinely unbounded at the pinned
  # version — the quarantine at proxy/server.py:1123-1131 holds new work off "until
  # every known post-timeout worker has genuinely exited", with no time cap and no env
  # var to impose one — so this is a real trade, not a free revert: it accepts a higher
  # chance of entering that state in exchange for never stalling a prompt for two
  # minutes with nothing on the wire.
  #
  # HEADROOM_KOMPRESS_MAX_TOKENS is the size-gate half of #1171 (fork-assessment doc,
  # docs/superpowers/specs/2026-08-19-headroom-fork-assessment.md §1a; recommended
  # there as "untried... cheapest possible next step"). Upstream already caps a single
  # content block's estimated size before it reaches the synchronous ModernBERT ONNX
  # path (content_router.py:1778-1783, default "50000" when unset) — above the cap the
  # block routes to LogCompressor/TextCrusher instead of ML (the branch at
  # content_router.py:3436-3467, whose "kompress size-gate fired" log line is what the
  # grep below counts). Measured on this machine before choosing 10000:
  # `grep -c "size-gate fired"` across all six rotated ~/.headroom/logs/proxy.log*
  # files is 0 — the 50,000 default has NEVER once fired here, so it adds zero
  # protection today. Measured the traffic it would gate against: the 1,181 kompress
  # events this proxy ever recovered through its own CCR mechanism (the same events
  # behind the documented 31.24% average yield) top out at 2,464 tokens (p99.9; mean
  # 448.8, p99 1,963), and the broader, unfiltered population of every raw ONNX
  # invocation ever logged here (775 calls) tops out at 5,090 words (a different unit
  # than the gate's own token estimate, but the same order of magnitude). 10,000 is
  # roughly 2x the single largest real value observed under either measure, so this
  # costs nothing measured — all 1,181 of those events, 100% of the $42.90 lifetime
  # compression savings (small next to caching's $17,360.72 per the fork-assessment
  # doc's §0, but free to keep), stay exactly as fast as today — while shrinking the
  # no-man's-land between real traffic and the reconstructed 8.95MB/727-message
  # cascade five-fold (50,000 -> 10,000). Honest limit, checked against this same log
  # data before picking a number: inference time here does not scale cleanly with
  # size — a 47-word call took 15,736ms and a 31-word call took 11,534ms, both slower
  # than several 800+-word calls — so this gates the large-single-block failure mode
  # #1171 names, and does nothing for contention- or model-load-driven latency on
  # small blocks, a separate, still-unresolved mechanism.
  #
  # VERSION NOTE — every file:line and default above is 0.33.0's, RE-READ against the
  # installed tree, not carried over. This block was first written while 0.35.0 was
  # installed; the machine was rolled back to 0.33.0 the same day (0.35.0 correlated
  # with proxy-mangled streaming responses in a live session), and
  # modules/headroom/manifest.json pins 0.33.0 to match. Both vars this block sets were
  # re-verified as REAL at 0.33.0 rather than assumed — neither became an inert no-op
  # in the rollback:
  #   HEADROOM_COMPRESSION_TIMEOUT_SECONDS  proxy/helpers.py:688        default "30"
  #   HEADROOM_KOMPRESS_MAX_TOKENS          content_router.py:1780      default "50000"
  # Two claims that WERE true of 0.35.0 and are not true here, recorded so neither gets
  # relied on again:
  #   - HEADROOM_COMPRESSION_QUARANTINE_MAX_SECONDS (0.35.0, upstream #2360) does not
  #     exist in 0.33.0 at all — no such var, and no cap of any kind on the quarantine.
  #     An earlier version of this comment said that var bounded the other half of the
  #     blast radius "at its upstream default"; under the pinned version there is no
  #     default to leave alone, which is why the paragraph above now says unbounded.
  #   - the reason for not setting HEADROOM_BACKGROUND_COMPRESSION was "gated behind
  #     is_token_mode(...), a no-op outside token mode", verified in 0.35.0's
  #     proxy/background_compression.py. That does NOT reproduce at 0.33.0: the string
  #     `is_token_mode` appears nowhere in that module, and the flag is read as a plain
  #     env bool at proxy/server.py:1090-1092, gated at its call sites instead. Leaving
  #     it unset is still right — it is opt-in and off by default — but the mode-no-op
  #     justification is 0.35.0's, so it is no longer stated as this version's reason.
  #
  # HEADROOM_LOSSLESS=1 IS THE ONE SETTING THAT KEEPS STREAMING WORKING. It is not a
  # savings tuning knob; it is the fix for the live failure that forced the 0.35.0
  # rollback, and it is why this chain is safe on 0.35.0 at all.
  #
  # THE FAILURE, as a live Claude Code session saw it: `API returned an empty or
  # malformed response (HTTP 200) ... content-type event-stream, body is an event
  # stream (the non-streaming request was answered with a stream) ... This was the
  # non-streaming retry of streaming request ... which failed with: other; 0 stream
  # events received.` Upstream tracks that exact string as headroomlabs-ai/headroom
  # #3130 (OPEN), with the streaming half as #3071 and the empty-200 half as
  # #2952/#3019/#3040/#3055. NONE of the fixes are in a released version: #3131 (the
  # content-type fix) is unmerged, and #3092/#2953 merged only AFTER the 0.35.0 tag.
  # There is no version to upgrade to; the usage has to route around it.
  #
  # THE MECHANISM, measured against an isolated 0.35.0 proxy driven by a local fake
  # upstream (no credentials, no real API calls), reading what the UPSTREAM actually
  # received rather than what the client asked for:
  #   1. Headroom injects its `headroom_retrieve` tool into the tools array whenever a
  #      session has ever compressed. proxy/handlers/anthropic.py then computes
  #      `buffered_stream_ccr = stream AND ccr_handler_enabled AND
  #      _has_headroom_retrieve_tool(...)`, and when true it REWRITES the client's
  #      `stream:true` to `stream:false` upstream, buffers the entire generation, and
  #      re-synthesizes SSE afterwards. Time-to-first-byte becomes the whole
  #      generation. That is symptom 1: the client waits, receives nothing, and
  #      reports `0 stream events received`.
  #   2. The buffered/non-streaming return path forwards the upstream response with
  #      `dict(response.headers)` and pops only content-encoding and content-length —
  #      `content-type` rides along verbatim. Whenever that path carries an SSE-typed
  #      upstream reply, the client is handed HTTP 200 + `text/event-stream` for a
  #      request it made non-streaming. That is symptom 2, and #3130's own diagnosis
  #      names this code site.
  # Reproduced here: client `stream:true` -> upstream received `stream:false` with
  # `headroom_retrieve` appended, and the reply carried the JSON upstream's request-id
  # under an SSE content-type. Reproduced on 0.33.0 too — the header-copy defect is in
  # BOTH versions, so this is not a 0.35.0 regression to wait out.
  #
  # WHY 0.35.0 MADE IT FIRE CONSTANTLY, and 0.33.0 did not. Upstream #2848 (shipped in
  # 0.35.0) widened injection from "only markers created THIS turn" to "any marker
  # present", and made it session-sticky. Measured, same payload, same env, only the
  # version differing: on 0.33.0 a `<<ccr:...>>` marker already seen in the forwarded
  # prefix injects NOTHING and the upstream receives `stream:true`; on 0.35.0 that
  # request AND the following marker-free request both inject the tool and both arrive
  # upstream as `stream:false`. So 0.35.0 turns an occasional downgrade into a
  # per-turn one, which is why the failure only became visible after the upgrade.
  #
  # WHAT HEADROOM_LOSSLESS=1 DOES ABOUT IT. proxy/server.py's `if config.lossless:`
  # branch sets `config.ccr_inject_tool = False` (and `ccr_inject_marker = False`,
  # `router_config.lossless`, `smart_crusher_lossless_only`) — identical wiring in both
  # versions, so this is safe at the currently pinned 0.33.0 as well as at 0.35.0. With
  # the tool never injected, `buffered_stream_ccr` can never be true: streaming stays
  # streaming, and the verbatim-content-type path is only ever reached by genuinely
  # non-streaming requests, where the upstream reply is JSON anyway. Verified on the
  # isolated 0.35.0 proxy: upstream receives `stream:true`, the client gets the real
  # 46-event passthrough stream with the streaming upstream's request-id, and a
  # `stream:false` request still comes back `application/json`.
  #
  # WHY LOSSLESS AND NOT HEADROOM_NO_CCR. Both disable the injection, but `--no-ccr`
  # is documented as "lossy compression with no recovery path" — it keeps destroying
  # content while removing the only way to get it back. `--lossless` instead leaves
  # content that would need a recovery marker UNCOMPACTED. This repo's whole argument
  # for putting a rewriter in front of generation is that the bytes reaching the model
  # are not degraded, so the lossy-with-no-recovery variant is not available to it.
  # The cost is CCR's share of savings only: $42.90 lifetime on this machine against
  # caching's $17,360.72 (fork-assessment doc §0), and caching is untouched — the proxy
  # still reports `mode: cache` and a healthy cache component with this set.
  #
  # HEADROOM_LOSSLESS=0 is a real opt-out, not a no-op: click types the flag as
  # boolean, so "0"/"false" resolve to False and restore upstream's CCR default for an
  # operator who wants it back and accepts the streaming risk.
  #
  # HEADROOM_COMPRESSION_TIMEOUT_SECONDS is pinned to upstream's OWN default (30)
  # rather than the 130 this file carried while 0.35.0 was installed. 130 was chosen as
  # ~2x a 64.75s synchronous run, on the theory that the budget only bounded a
  # background worker. On 0.35.0 that is wrong in a client-visible way: upstream #2357
  # changed cache-mode COLD START from silent passthrough to a full synchronous
  # `anthropic_pipeline.apply(..., timeout=COMPRESSION_TIMEOUT_SECONDS)` that runs
  # BEFORE the request is forwarded, so the budget is a pre-upstream stall with zero
  # bytes sent. Measured across the same requests on both versions: 0.33.0 logged 0
  # `[router]` invocations (cache mode never entered the content router at all), 0.35.0
  # logged one per cold start. 130s therefore guarantees the client gives up first on
  # exactly the largest payload of every session. Pinning 30 rather than dropping the
  # override keeps hmd's stall ceiling from moving if upstream's default ever does.
  #
  # Isolation note for the two vars above: neither was the cause. Re-running the
  # streaming and non-streaming probes on 0.35.0 with (130s, 10000), with upstream's
  # (30s, 50000), and with the fix, the downgrade and the content-type mismatch were
  # byte-identical in both non-fixed configurations — the confound was three
  # simultaneous changes, and the version's injection widening is the one that matters.
  #
  # All four vars this file touches (ANTHROPIC_BASE_URL — see the file header —
  # HEADROOM_LOSSLESS, HEADROOM_COMPRESSION_TIMEOUT_SECONDS, and
  # HEADROOM_KOMPRESS_MAX_TOKENS) are scoped to this ONE child only, and all four stay
  # overridable by whatever the operator already exported — same ${VAR:-default}
  # precedent as hmd_headroom_port() above.
  ( HEADROOM_LOSSLESS="${HEADROOM_LOSSLESS:-1}" \
    HEADROOM_COMPRESSION_TIMEOUT_SECONDS="${HEADROOM_COMPRESSION_TIMEOUT_SECONDS:-30}" \
    HEADROOM_KOMPRESS_MAX_TOKENS="${HEADROOM_KOMPRESS_MAX_TOKENS:-10000}" \
    "$bin" proxy --host 127.0.0.1 --port "$port" >>"$logdir/proxy.log" 2>&1 & echo $! > "$logdir/proxy.pid" ) \
    || { HMD_HEADROOM_WHY="could not start the Headroom proxy — running unproxied"; return 1; }

  # 4. Bounded readiness. The ceiling is the whole point: a proxy that never becomes ready
  #    must cost the user 15 seconds once, not a hung session.
  local i=0
  while [ "$i" -lt "$HMD_HEADROOM_READY_POLLS" ]; do
    if live="$(hmd_headroom_probe "$port")"; then
      HMD_HEADROOM_BASE_URL="http://127.0.0.1:$port"
      HMD_HEADROOM_WHY="started the Headroom proxy on $port (upstream $live)"
      return 0
    fi
    sleep 0.25
    i=$((i+1))
  done
  HMD_HEADROOM_WHY="the Headroom proxy did not become ready within $((HMD_HEADROOM_READY_POLLS / 4))s — running unproxied"
  return 1
}

# hmd_headroom_report <plugin_dir> — one line the operator can read, for `hmd modules
# status headroom` and for the wrap banner. A silent proxy contradicts this project's own
# disclosure rules, so "am I proxied right now" has to be answerable without a packet
# capture. This PROBES rather than remembering: it reports the machine, not a stored claim.
hmd_headroom_report() {
  local plugin_dir="$1" port live
  if hmd_headroom_opted_out "$plugin_dir"; then
    printf 'NOT ROUTED — opted out'; return 0
  fi
  if ! hmd_headroom_installed "$plugin_dir"; then
    printf 'NOT ROUTED — module not added'; return 0
  fi
  if ! hmd_headroom_bin >/dev/null; then
    printf 'NOT ROUTED — the headroom CLI is not installed'; return 0
  fi
  port="$(hmd_headroom_port)"
  if live="$(hmd_headroom_probe "$port")"; then
    printf 'ROUTED — generation traffic goes to http://127.0.0.1:%s, which forwards to %s. Judgment does NOT: hmd_gate_exec scrubs it.' "$port" "$live"
  else
    printf 'NOT ROUTED — no Headroom proxy is listening on %s (it starts on the next `hmd wrap`)' "$port"
  fi
}
