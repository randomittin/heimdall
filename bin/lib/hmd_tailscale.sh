#!/usr/bin/env bash
# hmd_tailscale.sh — sourceable bash wrapper around the Tailscale CLI.
#
# Consumed by Wave 2's `hmd app connect|status|disconnect|doctor` subcommand family.
# This file only wraps `tailscale`; it never wires up a CLI subcommand itself, and it
# never mutates the caller's real tailscaled state except when a *_start/*_stop/
# ts_install_prompt function is explicitly invoked.
#
# ── ENV / OVERRIDES (test-injection seams) ──────────────────────────────────────────
#   HMD_TAILSCALE_BIN      overrides the resolved tailscale binary path. Honoured
#                          verbatim by ts_bin, without probing — this is what
#                          test/hmd-tailscale.test.sh points at its fake tailscale
#                          script.
#   HMD_ASSUME_NO          if "1", ts_install_prompt never installs (see Decision D1).
#   HMD_FUNNEL_FORCE_RESET if "1", ts_funnel_stop resets unconditionally even when
#                          other Funnel/Serve targets are configured (see D6). Off by
#                          default — the safe default is to refuse, not to silently
#                          wipe someone else's config.
#
# ── DECISIONS THIS FILE ENCODES ──────────────────────────────────────────────────────
#   D1: install is never silent — ts_install_prompt always prints the prompt and the
#       exact command it would run, even when it is about to skip installing.
#   D4: the funnel HTTPS port is restricted to 443|8443|10000; a tailnet-policy hint
#       from the real CLI's stderr (HTTPS certs / funnel node attribute not enabled)
#       is surfaced VERBATIM on stderr, never paraphrased.
#   D5: (security audit A11) ts_install_prompt never hands a dynamically-built string
#       back to the shell for re-interpretation. What actually executes is always a
#       fixed argv array: literal words for the brew/open/visit cases, and for Linux a
#       fixed `sh -c '<the exact literal one-liner>'` that never has any variable
#       spliced into it. The prompt still SHOWS the operator the official one-liner
#       verbatim; only what gets EXECUTED is constrained.
#   D6: (security audit A13) ts_funnel_stop never lets the modern CLI's all-or-nothing
#       `funnel reset` silently wipe someone else's Funnel/Serve config. It reads
#       ts_funnel_status_json first; if anything other than hmd's own target is
#       configured it refuses (exit 7) unless HMD_FUNNEL_FORCE_RESET=1 is set, or it
#       uses a per-port scoped stop instead when the installed CLI actually exposes one
#       (see ts_funnel_scoped_off_supported — real tailscale 1.94.2 does not).
#
# JSON parsing uses the `jq -r '.path // empty' 2>/dev/null` idiom already established
# in bin/lib/hmd-headroom-chain.sh:122 and friends — jq is precedented, not a new dep.
#
# Double-source guard, matches bin/lib/hmd-python.sh:33-34.
[ -n "${_HMD_TAILSCALE_SH:-}" ] && return 0 2>/dev/null || true
_HMD_TAILSCALE_SH=1

# ts_bin — print the resolved tailscale CLI path.
# Resolution order: HMD_TAILSCALE_BIN override (honoured verbatim, unprobed — a test
# seam that has to prove itself isn't a seam), `command -v tailscale`, the macOS GUI
# app's embedded CLI, then /usr/local/bin/tailscale.
# Exit 0: path printed. Exit 1: none of the above resolved to anything.
ts_bin() {
  if [ -n "${HMD_TAILSCALE_BIN:-}" ]; then
    printf '%s' "$HMD_TAILSCALE_BIN"
    return 0
  fi

  local cand
  cand="$(command -v tailscale 2>/dev/null || true)"
  if [ -n "$cand" ]; then
    printf '%s' "$cand"
    return 0
  fi

  if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    printf '%s' "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    return 0
  fi

  if [ -x "/usr/local/bin/tailscale" ]; then
    printf '%s' "/usr/local/bin/tailscale"
    return 0
  fi

  return 1
}

# ts_installed — is a usable tailscale binary actually resolvable?
# Does more than ts_bin's own exit code: it RUNS the resolved binary (`version`), so a
# path that resolves but doesn't behave like tailscale (a broken shim, a stale override)
# is correctly reported as not installed.
# Exit 0: resolves and responds to `version`. Exit 1: otherwise.
ts_installed() {
  local bin
  bin="$(ts_bin 2>/dev/null)" || return 1
  "$bin" version >/dev/null 2>&1
}

# ts_status_json — passthrough for `tailscale status --json`.
# Exit 0: JSON printed on stdout. Exit 1: tailscale binary not resolvable (see ts_bin).
# Exit 2: binary resolved, but the local daemon isn't reachable — detected from the
# REAL CLI's observed behaviour (exit 1, stderr containing "failed to connect to local
# Tailscale service"), captured via `tailscale --socket=<bogus path> status` on a
# machine with tailscaled running, never guessed. Other nonzero: passed through
# verbatim from the underlying tailscale invocation.
ts_status_json() {
  local bin out err rc
  bin="$(ts_bin 2>/dev/null)" || return 1
  err="$(mktemp 2>/dev/null || echo "/tmp/hmd-tailscale.$$.err")"
  out="$("$bin" status --json 2>"$err")"
  rc=$?
  if [ $rc -ne 0 ]; then
    if grep -q 'failed to connect to local Tailscale service' "$err" 2>/dev/null; then
      rm -f "$err" 2>/dev/null || true
      return 2
    fi
    rm -f "$err" 2>/dev/null || true
    return "$rc"
  fi
  rm -f "$err" 2>/dev/null || true
  printf '%s' "$out"
  return 0
}

# ts_online — exit 0 when Self.Online is true.
# Exit 0: online. Exit 1: offline, or status unavailable (see ts_status_json for the
# finer-grained reason).
ts_online() {
  local json online
  json="$(ts_status_json 2>/dev/null)" || return 1
  online="$(printf '%s' "$json" | jq -r '.Self.Online // false' 2>/dev/null)"
  [ "$online" = "true" ]
}

# ts_dns_name — print Self.DNSName with the trailing dot stripped.
# Exit 0: printed (may be an empty string when DNSName itself is empty/absent).
# Exit 1: status unavailable (see ts_status_json).
ts_dns_name() {
  local json name
  json="$(ts_status_json 2>/dev/null)" || return 1
  name="$(printf '%s' "$json" | jq -r '.Self.DNSName // empty' 2>/dev/null)"
  printf '%s' "${name%.}"
  return 0
}

# ts_funnel_supported — probe `tailscale funnel --help` and classify the CLI's funnel
# syntax generation by content, not exit code (exit code varies across CLI versions;
# the help text's shape doesn't). Always prints exactly one of:
#   modern   --bg / --https flags (current CLI, confirmed via a real `tailscale
#            funnel --help` on this machine: v1.94.2 shows both)
#   legacy   the older `funnel <port> on|off` form
#   none     funnel subcommand unavailable, or tailscale itself unresolvable
# Exit 0 always — the printed word is the result, not the exit status.
ts_funnel_supported() {
  local bin help
  bin="$(ts_bin 2>/dev/null)" || { printf 'none'; return 0; }
  help="$("$bin" funnel --help 2>&1)"
  if printf '%s' "$help" | grep -q -- '--bg'; then
    printf 'modern'
  elif printf '%s' "$help" | grep -q 'on|off'; then
    printf 'legacy'
  else
    printf 'none'
  fi
  return 0
}

# ts_funnel_scoped_off_supported — probe `tailscale funnel --help` for a per-port stop
# flag/subcommand, as distinct from ts_funnel_supported's on/off *syntax generation*
# check above. Some CLI generations expose a scoped `tailscale funnel --https=PORT
# off` that only touches hmd's own mapping; the modern generation checked empirically
# on this machine (real tailscale 1.94.2 — see `tailscale funnel --help`) does NOT:
# its only funnel subcommands are `status` and `reset`, and the word "off" does not
# appear anywhere in that output.
#   `tailscale serve --help` was inspected too, same machine, same 1.94.2 -- Funnel
#   piggybacks on Serve's config, so a scoped-off form could plausibly live there
#   instead. It doesn't either: serve's subcommands are status/reset/drain/clear/
#   advertise/get-config/set-config, and "off" appears nowhere in that output.
#   This probe (and ts_funnel_stop's scoped call) deliberately only ever looks at,
#   and shells out to, `funnel`, never `serve`, even if some future CLI adds a
#   scoped `serve --https=PORT off`: that would drop the underlying Serve mapping
#   too, a bigger blast radius than "stop hmd's own Funnel exposure".
# ts_funnel_stop (D6 / security audit A13) uses this probe's result to decide
# whether it can avoid the all-or-nothing `reset`. Kept as a live probe rather than
# a hardcoded "no" so a future CLI that adds scoped support is picked up
# automatically, with no code change here.
# Always prints exactly "yes" or "no". Exit 0 always — same contract as
# ts_funnel_supported above.
ts_funnel_scoped_off_supported() {
  local bin help
  bin="$(ts_bin 2>/dev/null)" || { printf 'no'; return 0; }
  help="$("$bin" funnel --help 2>&1)"
  if printf '%s' "$help" | grep -qw 'off'; then
    printf 'yes'
  else
    printf 'no'
  fi
  return 0
}

# ts_funnel_start PORT HTTPS_PORT — start funnel using the syntax matching
# ts_funnel_supported's probe.
# Exit 0: funnel started. Exit 64: HTTPS_PORT is not one of 443|8443|10000 (Decision
# D4 — EX_USAGE; checked BEFORE the binary is ever invoked). Exit 3: tailscale refused
# with a tailnet-policy hint (HTTPS certs / funnel attribute not enabled); the hint is
# printed VERBATIM on stderr, per D4, never paraphrased. Exit 1: tailscale unresolvable,
# or funnel unsupported on this CLI. Other nonzero: passed through from the underlying
# tailscale invocation.
ts_funnel_start() {
  local port="$1" https_port="$2"
  case "$https_port" in
    443|8443|10000) ;;
    *)
      printf 'hmd_tailscale: HTTPS_PORT must be one of 443, 8443, 10000 (got: %s)\n' "$https_port" >&2
      return 64
      ;;
  esac

  local bin mode err rc
  bin="$(ts_bin 2>/dev/null)" || return 1
  mode="$(ts_funnel_supported)"
  err="$(mktemp 2>/dev/null || echo "/tmp/hmd-tailscale.$$.err")"

  case "$mode" in
    modern)
      "$bin" funnel --bg "--https=${https_port}" "http://127.0.0.1:${port}" >/dev/null 2>"$err"
      rc=$?
      ;;
    legacy)
      "$bin" serve https / "http://127.0.0.1:${port}" >/dev/null 2>"$err" \
        && "$bin" funnel "${https_port}" on >/dev/null 2>>"$err"
      rc=$?
      ;;
    *)
      rm -f "$err" 2>/dev/null || true
      return 1
      ;;
  esac

  if [ "$rc" -ne 0 ]; then
    if grep -qi 'funnel' "$err" 2>/dev/null && grep -qi -E 'enable|attribute|policy|acl' "$err" 2>/dev/null; then
      cat "$err" >&2
      rm -f "$err" 2>/dev/null || true
      return 3
    fi
    cat "$err" >&2
    rm -f "$err" 2>/dev/null || true
    return "$rc"
  fi
  rm -f "$err" 2>/dev/null || true
  return 0
}

# ts_funnel_foreign_targets JSON TARGET — print, one per line, every proxy/TCP target
# in a `funnel status --json`-shaped blob (ipn.ServeConfig: .Web.<hostport>.Handlers.
# <path>.{Proxy,Path,Text}, .TCP.<port>) that is NOT exactly TARGET. TARGET is normally
# "http://127.0.0.1:<hmd's own backend port>" (the same string ts_funnel_start builds);
# pass "" when that port is unknown so nothing can match and every configured target is
# conservatively treated as foreign — this is what makes ts_funnel_stop's one-arg
# compatibility mode safe. Prints nothing (i.e. "no foreign targets") when the blob has
# no Web/TCP entries at all, when every entry matches TARGET, or when JSON parsing
# fails outright — a malformed/empty blob is treated the same as "nothing configured",
# consistent with ts_funnel_status_json's own tolerant style elsewhere in this file.
ts_funnel_foreign_targets() {
  local json="$1" target="$2"
  printf '%s' "$json" | jq -r --arg want "$target" '
    [
      ( .Web // {} | to_entries[]? | .value.Handlers // {} | to_entries[]?
        | (.value.Proxy // .value.Path // .value.Text // empty) ),
      ( .TCP // {} | keys[]? | "tcp:" + . )
    ]
    | map(select(. != "" and . != $want))
    | unique
    | .[]
  ' 2>/dev/null
}

# ts_funnel_stop HTTPS_PORT [PORT] — stop funnel using the syntax matching
# ts_funnel_supported's probe. PORT is hmd's own backend port (the same one passed to
# ts_funnel_start) and is OPTIONAL, for backward compatibility with existing one-arg
# callers; when omitted it is treated as unknown (see ts_funnel_foreign_targets).
# Legacy stop is already scoped to just this HTTPS_PORT (`funnel PORT off`, mirroring
# the start recipe's second half) so it is unaffected by D6 below.
# Modern stop (D6 / security audit A13): the real CLI's only stop-shaped funnel
# subcommand is `reset`, which wipes ALL Funnel/Serve config on the node, not just
# hmd's mapping — confirmed via `tailscale funnel --help`, which lists only `status`
# and `reset`. Before calling it, this reads ts_funnel_status_json and refuses to reset
# when it finds any target other than hmd's own (see ts_funnel_foreign_targets), unless
# HMD_FUNNEL_FORCE_RESET=1. When PORT is known and the installed CLI actually exposes a
# per-port scoped stop (ts_funnel_scoped_off_supported — not true for real tailscale
# 1.94.2, but checked live in case a future CLI adds it), that scoped stop is used
# instead of `reset`, even when foreign targets exist, since it never touches them.
# Exit 0: stopped. Exit 64: HTTPS_PORT invalid (Decision D4, checked before the binary
# is invoked). Exit 7: refusing to reset — other Funnel/Serve targets are configured
# and neither a scoped stop nor HMD_FUNNEL_FORCE_RESET=1 was available (D6). Exit 1:
# tailscale unresolvable, or funnel unsupported. Other nonzero: passed through from the
# underlying tailscale invocation.
ts_funnel_stop() {
  local https_port="$1" port="${2:-}"
  case "$https_port" in
    443|8443|10000) ;;
    *)
      printf 'hmd_tailscale: HTTPS_PORT must be one of 443, 8443, 10000 (got: %s)\n' "$https_port" >&2
      return 64
      ;;
  esac

  local bin mode rc target foreign scoped
  bin="$(ts_bin 2>/dev/null)" || return 1
  mode="$(ts_funnel_supported)"

  case "$mode" in
    modern)
      if [ "${HMD_FUNNEL_FORCE_RESET:-0}" = "1" ]; then
        "$bin" funnel reset >/dev/null 2>&1
        rc=$?
      else
        target=""
        if [ -n "$port" ]; then
          target="http://127.0.0.1:${port}"
        fi
        foreign="$(ts_funnel_foreign_targets "$(ts_funnel_status_json 2>/dev/null)" "$target")"
        scoped="no"
        if [ -n "$port" ] && [ "$(ts_funnel_scoped_off_supported)" = "yes" ]; then
          scoped="yes"
        fi

        if [ -n "$foreign" ] && [ "$scoped" = "no" ]; then
          printf 'hmd_tailscale: refusing to reset Funnel -- other targets are configured, reset would wipe them too:\n%s\n' "$foreign" >&2
          printf 'hmd_tailscale: set HMD_FUNNEL_FORCE_RESET=1 to reset anyway, or remove those targets first.\n' >&2
          return 7
        fi
        if [ -n "$foreign" ]; then
          printf 'hmd_tailscale: other Funnel targets are configured; using a scoped stop (--https=%s off) instead of reset, leaving them untouched:\n%s\n' "$https_port" "$foreign" >&2
        fi

        if [ "$scoped" = "yes" ]; then
          "$bin" funnel "--https=${https_port}" off >/dev/null 2>&1
        else
          "$bin" funnel reset >/dev/null 2>&1
        fi
        rc=$?
      fi
      ;;
    legacy)
      "$bin" funnel "${https_port}" off >/dev/null 2>&1
      rc=$?
      ;;
    *)
      return 1
      ;;
  esac
  return "$rc"
}

# ts_funnel_status_json — print funnel status as JSON: `tailscale funnel status --json`
# when funnel is supported (modern or legacy), else falls back to
# `tailscale serve status --json`.
# Exit 0: JSON printed. Exit 1: tailscale binary not resolvable. Other nonzero: passed
# through from the underlying tailscale invocation.
ts_funnel_status_json() {
  local bin mode out rc
  bin="$(ts_bin 2>/dev/null)" || return 1
  mode="$(ts_funnel_supported)"
  if [ "$mode" = "none" ]; then
    out="$("$bin" serve status --json 2>/dev/null)"
    rc=$?
  else
    out="$("$bin" funnel status --json 2>/dev/null)"
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out"
  fi
  return "$rc"
}

# ts_install_prompt — print the consent prompt and the exact command that WOULD run,
# then install ONLY on an explicit 'y' read from stdin (Decision D1: never silent, even
# when about to skip). Command choice: macOS uses `brew install --cask tailscale` when
# brew is on PATH, else names the manual download URL; Linux uses the official
# `curl -fsSL https://tailscale.com/install.sh | sh` one-liner.
# Exit 0: user consented and the install command exited 0. Exit 4: install was skipped
# — either HMD_ASSUME_NO=1, or the user answered anything but y/Y. Other nonzero: user
# consented but the install command itself failed; that exit code is passed through.
ts_install_prompt() {
  local os cmd_display ans
  local -a cmd

  os="$(uname -s 2>/dev/null || echo unknown)"
  case "$os" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        cmd=(brew install --cask tailscale)
        cmd_display="brew install --cask tailscale"
      else
        cmd=(open https://tailscale.com/download/mac)
        cmd_display="open https://tailscale.com/download/mac"
      fi
      ;;
    Linux)
      # Fixed literal argv (D5 / security audit A11): $cmd_display below is for
      # display ONLY and is never the thing that gets run, so nothing can be spliced
      # into what actually executes. The official one-liner is still shown to the
      # operator verbatim; it is just never handed back to a shell as a built string.
      cmd=(sh -c 'curl -fsSL https://tailscale.com/install.sh | sh')
      cmd_display='curl -fsSL https://tailscale.com/install.sh | sh'
      ;;
    *)
      cmd=(visit https://tailscale.com/download)
      cmd_display="visit https://tailscale.com/download"
      ;;
  esac

  printf 'Tailscale is not installed.\n' >&2
  printf 'hmd would run:\n  %s\n' "$cmd_display" >&2

  if [ "${HMD_ASSUME_NO:-0}" = "1" ]; then
    printf 'HMD_ASSUME_NO=1 -- skipping install.\n' >&2
    return 4
  fi

  printf 'Install now? [y/N] ' >&2
  IFS= read -r ans
  case "$ans" in
    y|Y)
      "${cmd[@]}"
      return $?
      ;;
    *)
      printf 'Skipping install.\n' >&2
      return 4
      ;;
  esac
}

# ts_login_hint — print `tailscale up` guidance, plus the login URL when the CLI is
# currently offering one (Self/AuthURL in status --json). This is advisory text only;
# the caller decides WHEN to show it (typically after ts_online reports false).
# Exit 0: hint printed. Exit 1: tailscale binary not resolvable.
ts_login_hint() {
  local bin json url
  bin="$(ts_bin 2>/dev/null)" || return 1
  json="$(ts_status_json 2>/dev/null)"
  printf 'Not logged in to Tailscale. Run: tailscale up\n'
  url="$(printf '%s' "$json" | jq -r '.AuthURL // empty' 2>/dev/null)"
  if [ -n "$url" ]; then
    printf 'Login URL: %s\n' "$url"
  fi
  return 0
}
