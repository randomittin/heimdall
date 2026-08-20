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
# headroom installed, module removed, opted out, port occupied by a stranger, a live proxy
# that cannot be verified to have CCR tool injection off, proxy refuses to start, proxy
# starts and never becomes ready — all of them land on "run unproxied".
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

# hmd_headroom_health <port> — is a HEADROOM proxy answering there, pointed at OUR
# provider? Prints its whole /health body on success. Two refusals matter as much as the
# accept:
#   · a listener that is not headroom-proxy  -> we do not route a prompt into a stranger,
#   · a headroom pointed somewhere else      -> that is a NEW DESTINATION, which is exactly
#                                               what invariant 5 forbids.
# The BODY rather than one field, because the reuse gate below needs `config.pid` from the
# same response that answered those two questions — one fetch, one moment in time.
hmd_headroom_health() {
  local port="$1" body svc up
  body="$(curl -s --max-time 3 "http://127.0.0.1:$port/health" 2>/dev/null)" || return 1
  [ -n "$body" ] || return 1
  svc="$(printf '%s' "$body" | jq -r '.service // empty' 2>/dev/null)" || return 1
  [ "$svc" = "headroom-proxy" ] || return 1
  up="$(printf '%s' "$body" | jq -r '.checks.upstream.url // empty' 2>/dev/null)"
  [ "$up" = "$HMD_HEADROOM_UPSTREAM" ] || return 1
  printf '%s' "$body"
}

# hmd_headroom_probe <port> — the same accept/refuse decision, printing the upstream
# URL. Kept as the one-line answer for callers that only need "is a usable proxy
# there"; the reuse path needs the whole body (for the pid), so it calls
# hmd_headroom_health directly rather than paying a second /health round trip.
hmd_headroom_probe() {
  local body
  body="$(hmd_headroom_health "$1")" || return 1
  printf '%s' "$body" | jq -r '.checks.upstream.url // empty' 2>/dev/null
}

# ── REUSING A PROXY hmd DID NOT START ─────────────────────────────────────────────
# A proxy answering on the port is reused (see the chain, step 1). That branch is why
# HEADROOM_LOSSLESS alone did not fix the streaming break it was added for: the var is
# put on proxies THIS FILE LAUNCHES, and a Headroom proxy is long-lived. One started by
# `headroom wrap`, by hand, or by an hmd from before that fix keeps injecting
# `headroom_retrieve` — and every later session that finds it on the port inherits the
# downgrade, forever, with hmd reporting ROUTED the whole time. Measured on this
# machine: the proxy on 8787 ran from 11:18 to 17:12 across many sessions, and its logs
# carry 348 injections in the current log file alone.
#
# NOTHING IN /health DISTINGUISHES THE TWO. Measured 2026-08-19 against two real
# 0.33.0 proxies on isolated workspaces, one launched with HEADROOM_LOSSLESS=0 and one
# with =1: /health and /settings are byte-identical apart from pid, timestamp and
# uptime — `lossless` and `ccr` appear in neither. So the check has to read the running
# PROCESS, which /health does hand us (`config.pid`, loopback-only).

# hmd_headroom_lossless_wanted — is injection-free mode what this chain would launch
# with right now? Mirrors upstream's own truthiness (_get_env_bool: "true", "1", "yes",
# "on") against the same ${VAR:-default} the launch line uses, so the gate below and
# the proxy hmd starts can never disagree about what was asked for.
hmd_headroom_lossless_wanted() {
  case "$(printf '%s' "${HEADROOM_LOSSLESS:-1}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) return 0 ;;
  esac
  return 1
}

# hmd_headroom_proc_lossless <pid> — verdict on a RUNNING proxy, printed as one of
# `lossless` / `lossy` / `unverified`. Exit status is 0 only for `lossless`.
#
# Two readings, in this order, because they have different platform costs:
#   1. THE COMMAND LINE. `--lossless` is enough on its own upstream
#      (`lossless = getattr(args, "lossless", False) or _get_env_bool(...)`), and a
#      process's argv is readable everywhere. This is also the reading that always
#      settles hmd's OWN proxy, because the launch below passes the flag precisely so
#      that it can be verified without depending on 2.
#   2. THE ENVIRONMENT (`ps eww`). Needed for a stranger that was configured the other
#      documented way, HEADROOM_LOSSLESS=1 in the env. Environment visibility is NOT
#      universal — macOS hides it for SIP-signed binaries (/bin/bash, /bin/sleep:
#      measured, zero env tokens), while a uv-installed interpreter like Headroom's own
#      exposes it — so `PATH=` is required as proof the dump really contains an
#      environment. Without that proof an absent HEADROOM_LOSSLESS means "cannot see",
#      not "not set", and the two must never collapse into the same verdict.
hmd_headroom_proc_lossless() {
  local pid="$1" argv dump val
  case "$pid" in ''|*[!0-9]*) printf 'unverified'; return 1 ;; esac
  argv="$(ps -ww -o command= -p "$pid" 2>/dev/null)"
  [ -n "$argv" ] || { printf 'unverified'; return 1; }
  case " $argv " in *" --lossless "*) printf 'lossless'; return 0 ;; esac
  dump="$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n')"
  printf '%s' "$dump" | grep -q '^PATH=' || { printf 'unverified'; return 1; }
  val="$(printf '%s' "$dump" | sed -n 's/^HEADROOM_LOSSLESS=//p' | tail -1 | tr '[:upper:]' '[:lower:]')"
  case "$val" in true|1|yes|on) printf 'lossless'; return 0 ;; esac
  printf 'lossy'; return 1
}

# hmd_headroom_reuse_ok <port> <health_body> — THE GATE ITSELF, in one place because the
# chain (which acts on it) and the report (which shows the operator what the chain will
# do) must never be able to disagree. Prints the refusal line and returns 1 when the live
# proxy must not be routed into; prints nothing and returns 0 when reuse is allowed.
hmd_headroom_reuse_ok() {
  local port="$1" health="$2" pid verdict
  # The operator who exported a falsy HEADROOM_LOSSLESS asked for upstream's CCR default
  # and accepted the streaming risk that comes with it. hmd enforces its own default; it
  # does not overrule a stated choice — which is also why this needs no second opt-out var.
  hmd_headroom_lossless_wanted || return 0
  pid="$(printf '%s' "$health" | jq -r '.config.pid // empty' 2>/dev/null)"
  verdict="$(hmd_headroom_proc_lossless "$pid")"
  [ "$verdict" = "lossless" ] && return 0
  hmd_headroom_reuse_refusal "$port" "$verdict"
  return 1
}

# hmd_headroom_reuse_refusal <port> <verdict> — the one line the operator gets when a
# live proxy is left alone. It names the fix AND the opt-out, because a refusal the
# operator cannot act on is just an unexplained loss of compression.
hmd_headroom_reuse_refusal() {
  case "$2" in
    lossy)
      printf 'the Headroom proxy already listening on %s was started WITHOUT lossless mode: it injects headroom_retrieve, so streaming requests reach the provider as stream:false and the client sees `0 stream events received` (upstream #3071/#3130). Restart it (hmd starts one with --lossless), or export HEADROOM_LOSSLESS=0 to accept that and reuse it. Running unproxied.' "$1" ;;
    *)
      printf 'the Headroom proxy already listening on %s cannot be verified as lossless — its pid or environment is not readable from here — and an unverified proxy may be injecting headroom_retrieve, which downgrades streaming to buffered (upstream #3071/#3130). Export HEADROOM_LOSSLESS=0 to reuse it anyway. Running unproxied.' "$1" ;;
  esac
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

  # 1. ALREADY LIVE? Reuse it — but only after checking it is not the thing this chain
  #    exists to avoid. A second proxy on a busy port would fail to bind anyway, and an
  #    operator who started `headroom proxy` by hand should keep the process they own; what
  #    changes here is that hmd no longer ROUTES INTO a proxy whose CCR tool injection is on
  #    (or unverifiable), because that proxy downgrades every streaming request the session
  #    makes. See hmd_headroom_proc_lossless above for how the verdict is read, and the
  #    HEADROOM_LOSSLESS block below for what the injection does. The gate is skipped
  #    entirely when the operator has opted out of lossless mode: they asked for upstream's
  #    CCR default, and hmd enforces its own default rather than overruling a stated choice.
  local health refusal verified=""
  if health="$(hmd_headroom_health "$port")"; then
    live="$(printf '%s' "$health" | jq -r '.checks.upstream.url // empty' 2>/dev/null)"
    if ! refusal="$(hmd_headroom_reuse_ok "$port" "$health")"; then
      HMD_HEADROOM_WHY="$refusal"
      return 1
    fi
    hmd_headroom_lossless_wanted && verified=", verified lossless"
    HMD_HEADROOM_BASE_URL="http://127.0.0.1:$port"
    HMD_HEADROOM_WHY="reusing the Headroom proxy already listening on $port (upstream $live$verified)"
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
  # VERSION NOTE — the pin is 0.35.0 again as of 2026-08-20, and every file:line below
  # was RE-READ against the 0.35.0 sdist rather than carried across the bump. The
  # history matters because it is the reason the pin moved twice: 0.35.0 was installed,
  # correlated with proxy-mangled streaming in a live session, and was rolled back to
  # 0.33.0 on 2026-08-19. The cause was then found and is NOT version-specific — the
  # headroom_retrieve injection documented below, present in both versions — so
  # `--lossless` fixes it on either, and the rollback no longer buys anything.
  #   HEADROOM_COMPRESSION_TIMEOUT_SECONDS  proxy/helpers.py:1043       default "30"
  #   HEADROOM_KOMPRESS_MAX_TOKENS          content_router.py:1840      default "50000"
  # Both defaults are unchanged from 0.33.0; only their line numbers moved, which is
  # exactly why they were re-read instead of assumed.
  #
  # WHAT THE BUMP CHANGES, measured rather than read off a changelog:
  #   - HEADROOM_COMPRESSION_QUARANTINE_MAX_SECONDS (upstream #2360) EXISTS again, at
  #     proxy/server.py:1169 with a 60.0s default. Under 0.33.0 there was no such var
  #     and no cap of any kind, so the paragraph above describing the quarantine as
  #     unbounded is 0.33.0's statement and no longer this version's.
  #   - HEADROOM_BACKGROUND_COMPRESSION's call sites are gated behind
  #     `is_token_mode(...)` again (proxy/handlers/anthropic.py:1244 and :1381), so
  #     leaving it unset is a no-op under the CACHE mode hmd launches in. At 0.33.0 that
  #     gate did not exist and the flag was read as a plain env bool. Leaving it unset
  #     was right under both, for different reasons; this is the 0.35.0 reason.
  #   - upstream #2357 makes cache-mode COLD START synchronous before the request is
  #     forwarded, which is the one 0.35.0 cost this pin was previously held back for.
  #     It was MEASURED under this file's own config and does not reproduce: identical
  #     payload and env, 0.35.0 cold start 948ms against 0.33.0's 1261ms, zero
  #     `[router]` invocations on either. Held-back-for reasons have to survive
  #     measurement, and this one did not.
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
  # versions, so this is safe at the currently pinned 0.35.0 as well as at 0.33.0. With
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
  # bytes sent: 130s would guarantee the client gives up first on exactly the largest
  # payload of every session. Pinning 30 rather than dropping the override keeps hmd's
  # stall ceiling from moving if upstream's default ever does.
  #
  # HOW BIG THAT STALL ACTUALLY IS, measured on 2026-08-20 under this file's own config
  # (--lossless, 30s, 10000) rather than inferred from the changelog: a cold start on a
  # 213KB tool_result payload cost 948ms on 0.35.0 against 1261ms on 0.33.0, with ZERO
  # `[router]` invocations on either. The stall #2357 introduces is real in the code and
  # did not appear in the measurement — because `--lossless` keeps this traffic off the
  # synchronous ML path that would spend the budget. An earlier version of this comment
  # cited that same mechanism as the reason to hold the pin at 0.33.0; it did not
  # survive being measured, and the pin moved.
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
  # THE FLAG IS PASSED AS WELL AS THE VAR, and the duplication is load-bearing rather than
  # belt-and-braces. Upstream treats them as equivalent inputs
  # (`lossless = getattr(args, "lossless", False) or _get_env_bool("HEADROOM_LOSSLESS",
  # False)`), so the flag changes nothing about how THIS proxy behaves. What it changes is
  # what a LATER hmd can prove about it: a process's argv is readable on every platform,
  # its environment is not (macOS hides it for SIP-signed binaries), so a proxy launched
  # with only the env var could survive its own session and then be refused as unverifiable
  # by the very chain that started it. The var stays because it is the documented knob and
  # because the operator's own value has to reach the child unchanged; the flag is only
  # added when the effective value is truthy, so HEADROOM_LOSSLESS=0 remains a real opt-out
  # rather than being silently overridden by an argument the operator never asked for.
  local lossless_flag=""
  hmd_headroom_lossless_wanted && lossless_flag="--lossless"
  # shellcheck disable=SC2086  # deliberate: an empty $lossless_flag must expand to NO argument
  ( HEADROOM_LOSSLESS="${HEADROOM_LOSSLESS:-1}" \
    HEADROOM_COMPRESSION_TIMEOUT_SECONDS="${HEADROOM_COMPRESSION_TIMEOUT_SECONDS:-30}" \
    HEADROOM_KOMPRESS_MAX_TOKENS="${HEADROOM_KOMPRESS_MAX_TOKENS:-10000}" \
    "$bin" proxy --host 127.0.0.1 --port "$port" $lossless_flag >>"$logdir/proxy.log" 2>&1 & echo $! > "$logdir/proxy.pid" ) \
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
  local health refusal
  if health="$(hmd_headroom_health "$port")"; then
    live="$(printf '%s' "$health" | jq -r '.checks.upstream.url // empty' 2>/dev/null)"
    if ! refusal="$(hmd_headroom_reuse_ok "$port" "$health")"; then
      # A refusal the operator cannot see is indistinguishable from a silent proxy: they
      # would see a running Headroom on the port and assume it is on the wire.
      printf 'NOT ROUTED — %s' "$refusal"
      return 0
    fi
    printf 'ROUTED — generation traffic goes to http://127.0.0.1:%s, which forwards to %s. Judgment does NOT: hmd_gate_exec scrubs it.' "$port" "$live"
  else
    printf 'NOT ROUTED — no Headroom proxy is listening on %s (it starts on the next `hmd wrap`)' "$port"
  fi
}
