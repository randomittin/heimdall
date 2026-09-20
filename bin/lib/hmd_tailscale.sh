#!/usr/bin/env bash
# hmd_tailscale.sh — sourceable bash wrapper around the Tailscale CLI.
#
# Consumed by Wave 2's `hmd app connect|status|disconnect|doctor` subcommand family.
# This file only wraps `tailscale`; it never wires up a CLI subcommand itself, and it
# never mutates the caller's real tailscaled state except when a *_start/*_stop/
# ts_install_prompt function is explicitly invoked.
#
# ── ENV / OVERRIDES (test-injection seams) ──────────────────────────────────────────
#   HMD_TAILSCALE_BIN   overrides the resolved tailscale binary path. Honoured verbatim
#                        by ts_bin, without probing — this is what test/hmd-tailscale.
#                        test.sh points at its fake tailscale script.
#   HMD_ASSUME_NO        if "1", ts_install_prompt never installs (see Decision D1).
#
# ── DECISIONS THIS FILE ENCODES ──────────────────────────────────────────────────────
#   D1: install is never silent — ts_install_prompt always prints the prompt and the
#       exact command it would run, even when it is about to skip installing.
#   D4: the funnel HTTPS port is restricted to 443|8443|10000; a tailnet-policy hint
#       from the real CLI's stderr (HTTPS certs / funnel node attribute not enabled)
#       is surfaced VERBATIM on stderr, never paraphrased.
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

# ts_funnel_stop HTTPS_PORT — stop funnel using the syntax matching
# ts_funnel_supported's probe. Modern stop uses `funnel reset` (the real CLI's only
# stop-shaped subcommand — confirmed via `tailscale funnel --help`: modern has no
# per-port off flag, only `status` and `reset`); legacy stop mirrors the brief's start
# recipe's second half, `funnel PORT off`.
# Exit 0: stopped. Exit 64: HTTPS_PORT invalid (Decision D4, checked before the binary
# is invoked). Exit 1: tailscale unresolvable, or funnel unsupported. Other nonzero:
# passed through from the underlying tailscale invocation.
ts_funnel_stop() {
  local https_port="$1"
  case "$https_port" in
    443|8443|10000) ;;
    *)
      printf 'hmd_tailscale: HTTPS_PORT must be one of 443, 8443, 10000 (got: %s)\n' "$https_port" >&2
      return 64
      ;;
  esac

  local bin mode rc
  bin="$(ts_bin 2>/dev/null)" || return 1
  mode="$(ts_funnel_supported)"

  case "$mode" in
    modern)
      "$bin" funnel reset >/dev/null 2>&1
      rc=$?
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
  local os cmd ans

  os="$(uname -s 2>/dev/null || echo unknown)"
  case "$os" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        cmd="brew install --cask tailscale"
      else
        cmd="open https://tailscale.com/download/mac"
      fi
      ;;
    Linux)
      cmd="curl -fsSL https://tailscale.com/install.sh | sh"
      ;;
    *)
      cmd="visit https://tailscale.com/download"
      ;;
  esac

  printf 'Tailscale is not installed.\n' >&2
  printf 'hmd would run:\n  %s\n' "$cmd" >&2

  if [ "${HMD_ASSUME_NO:-0}" = "1" ]; then
    printf 'HMD_ASSUME_NO=1 -- skipping install.\n' >&2
    return 4
  fi

  printf 'Install now? [y/N] ' >&2
  IFS= read -r ans
  case "$ans" in
    y|Y)
      eval "$cmd"
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
