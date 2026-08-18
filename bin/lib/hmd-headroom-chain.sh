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
  # set HEADROOM_BACKGROUND_COMPRESSION here — verified against installed 0.35.0
  # source (proxy/background_compression.py's own docstring, and the enqueue call in
  # proxy/handlers/anthropic.py) that it is gated behind `is_token_mode(...)` and is a
  # documented no-op in every mode but token. Setting it on a proxy that always runs in
  # cache mode would be config that LOOKS like a fix and does nothing.
  # HEADROOM_COMPRESSION_TIMEOUT_SECONDS is the lever that is real for cache mode: it
  # is consumed mode-agnostically by the synchronous compression wrapper
  # (proxy/server.py), so raising it gives a cold-start-large request more wall-clock
  # budget before Python's inability to preempt a worker thread turns a slow
  # compression into a leaked thread and a quarantine that blocks OTHER concurrent
  # sessions' compression too. 130s is ~2x the worst synchronous run measured on this
  # machine (64.75s, against the 30s upstream default) — a partial mitigation (raises
  # the bar, does not remove it — a still-larger request can still exceed it), not a
  # complete fix: upstream has no released way to keep an oversized cold-start context
  # off the synchronous path in cache mode. 0.35.0 separately bounds the OTHER half of
  # the blast radius on its own: HEADROOM_COMPRESSION_QUARANTINE_MAX_SECONDS (default
  # 60s, upstream #2360) now caps how long a leaked worker can block new compression
  # for OTHER sessions, so that one is left at its upstream default rather than
  # overridden here. Both vars are scoped to this ONE child only (see the file header
  # on why ANTHROPIC_BASE_URL gets the same treatment), and both stay overridable by
  # whatever the operator already exported — same precedent as hmd_headroom_port()
  # above.
  ( HEADROOM_COMPRESSION_TIMEOUT_SECONDS="${HEADROOM_COMPRESSION_TIMEOUT_SECONDS:-130}" \
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
