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
#   HMD_FUNNEL_APPROVE_WAIT_S bounds, in whole seconds (default 40), how long
#                          ts_funnel_start waits once the underlying CLI is
#                          running before giving up on a pending tailnet-Funnel
#                          approval (see Decision D8). Kept below bin/heimdall-
#                          app's own 45s _run_with_timeout budget around the
#                          whole call, so the lib itself returns a precise exit
#                          3 instead of being killed first and reported as an
#                          ambiguous 124.
#   HMD_TAILSCALE_APP_PLIST overrides which Info.plist ts_variant reads for the
#                          macsys/appstore bundle-id check, AND stands in for the
#                          "resolved binary lives under /Applications/Tailscale.app/"
#                          gate itself (see ts_variant, tier 1) — the only way to
#                          exercise that tier without a real Tailscale.app on disk.
#                          Never set in real usage.
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
#   D7: (bug analysis, hmdapp docs/analysis/2026-09-21-tailscale-macsys-funnel-cli-
#       error-3.md) the macsys (Mac App Store system-extension) and appstore (Mac App
#       Store GUI) builds cannot run Funnel at all — confirmed against Tailscale's own
#       macOS-variants comparison table, which lists Funnel as supported on the
#       open-source `tailscaled` build only. ts_funnel_supported reports "none" for
#       these two variants UNCONDITIONALLY, even when the CLI's own `--help` still
#       advertises modern flags (macsys/appstore ship the same CLI binary as oss; the
#       --help text alone can't tell them apart — that gap is exactly what ts_variant
#       exists to close). ts_funnel_start refuses the same way, before ever invoking
#       the CLI, with a new exit code — 9 — distinct from every other ts_funnel_start
#       exit path.
#   D8: (hmdapp handoff, docs/HANDOFF-TO-HEIMDALL-2026-09-21.md item 2) the real CLI
#       prints "Funnel is not enabled on your tailnet. To enable, visit:
#       https://login.tailscale.com/f/funnel?node=…" to STDOUT, then blocks polling
#       for approval. The pre-fix ts_funnel_start only ever captured stderr
#       (`>/dev/null 2>"$err"`), so that hint was never read and `hmd app connect`
#       looked hung with no output until the operator found the link elsewhere.
#       Fix: stdout and stderr are now captured together into one combined temp
#       file (mktemp, umask 077 — no `/tmp/$$` fallback, same hardening bin/
#       heimdall-app already applies to its own UI_OUT), and while the CLI runs
#       that file is tailed for a login.tailscale.com URL; the moment one appears
#       it is printed to the caller's stderr verbatim (D4: never paraphrased),
#       plus a one-line "open that URL…" follow-up (see _ts_funnel_await). If the
#       CLI hasn't finished by HMD_FUNNEL_APPROVE_WAIT_S, ts_funnel_start gives up
#       and returns exit 3 — the same family as the pre-existing tailnet-policy
#       hint exit, since both mean "a human has to go approve something first" —
#       rather than let bin/heimdall-app's own outer timeout kill it and report
#       an ambiguous 124. The CLI process itself is deliberately left running in
#       that case: it is tailscaled's own poll for approval, which resolves on
#       its own the moment the operator clicks the link, and killing it here
#       would only force a clean retry to repeat the same wait for nothing.
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

# _ts_realpath PATH — print PATH with symlinks resolved to their real target.
# Internal helper (not part of the public ts_* API, hence the leading underscore —
# mirrors this file's own _HMD_TAILSCALE_SH guard-variable convention). `readlink -f`
# and `realpath` are both extras — present on this machine (macOS 27) and on GNU
# coreutils, but not POSIX — so this falls back, in order, to: readlink -f, realpath,
# then a bounded manual symlink walk for a shell with neither. The manual walk mirrors
# bin/lib/real-home.sh:136 heimdall_physical_path's hop loop, capped at 16 hops so a
# symlink cycle terminates instead of hanging. When PATH doesn't exist at all, all
# three tiers naturally fall through to printing it unchanged (verified empirically:
# `readlink -f`/`realpath` both fail cleanly, non-zero, on a missing path, and the
# manual loop's `[ -L ]` test is simply false for it) — callers treat "didn't resolve
# under Tailscale.app" as "not macsys/appstore", which is already the safe default.
_ts_realpath() {
  local p="$1" out hops=0 target
  out="$(readlink -f "$p" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  out="$(realpath "$p" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  while [ -L "$p" ] && [ "$hops" -lt 16 ]; do
    target="$(readlink "$p" 2>/dev/null)" || break
    [ -n "$target" ] || break
    case "$target" in
      /*) p="$target" ;;
      *)  p="$(dirname "$p")/$target" ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s' "$p"
  return 0
}

# _ts_bundle_id PLIST — print PLIST's CFBundleIdentifier. Internal helper. Three-tier
# fallback, each only tried if the previous produced nothing: `defaults read` (the
# normal macOS way), `/usr/libexec/PlistBuddy` (present on every macOS; handles a
# plist `defaults` won't touch), then a raw `grep -A1 ... | tail -1 | sed` scrape of
# the XML for a plist neither structured tool accepts as a complete property list
# (verified empirically: a bare `<key>/<string>` pair with no enclosing
# `<plist><dict>` wrapper makes BOTH `defaults read` and PlistBuddy fail outright,
# while the text scrape still finds it). Prints empty on total failure.
_ts_bundle_id() {
  local plist="$1" bid
  [ -n "$plist" ] && [ -e "$plist" ] || return 0
  bid="$(defaults read "$plist" CFBundleIdentifier 2>/dev/null || true)"
  if [ -n "$bid" ]; then
    printf '%s' "$bid"
    return 0
  fi
  if [ -x /usr/libexec/PlistBuddy ]; then
    bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    if [ -n "$bid" ]; then
      printf '%s' "$bid"
      return 0
    fi
  fi
  bid="$(grep -A1 'CFBundleIdentifier' "$plist" 2>/dev/null | tail -1 | sed -e 's/^[[:space:]]*<string>//' -e 's/<\/string>[[:space:]]*$//')"
  printf '%s' "$bid"
  return 0
}

# _ts_app_bundle_gate REAL_PATH — should ts_variant attempt the plist-based
# macsys/appstore lookup? True in production when REAL_PATH genuinely lives under the
# real Tailscale.app bundle; true in tests whenever HMD_TAILSCALE_APP_PLIST is set,
# since that is the documented seam for exercising this tier without a real
# /Applications/Tailscale.app on disk. Internal helper.
_ts_app_bundle_gate() {
  local real="$1"
  [ -n "${HMD_TAILSCALE_APP_PLIST:-}" ] && return 0
  case "$real" in
    /Applications/Tailscale.app/*) return 0 ;;
  esac
  return 1
}

# ts_variant — classify which Tailscale build ts_bin resolves to. Fix for the hmdapp
# bug analysis (docs/analysis/2026-09-21-tailscale-macsys-funnel-cli-error-3.md): the
# Mac App Store / macsys build advertises the same modern `--bg`/`--https` flags in
# `tailscale funnel --help` as the open-source build (same CLI binary, different
# packaging), so ts_funnel_supported's help-text sniff alone cannot tell them apart —
# and Funnel silently fails/hangs on macsys regardless of what the help text says (see
# D7). ts_variant exists to make that distinction from something --help can't lie
# about: which build is actually installed.
#
# Always prints exactly one of:
#   oss       the open-source `tailscaled` build (Homebrew, or a Linux system
#             package) — the only variant Tailscale documents as supporting Funnel.
#   macsys    Mac App Store system-extension variant, bundle id io.tailscale.ipn.macsys.
#   appstore  Mac App Store GUI variant, bundle id io.tailscale.ipn.macos.
#   unknown   none of the above could be determined.
# Exit 0 always — the printed word is the result, not the exit status (same contract
# as ts_funnel_supported/ts_funnel_scoped_off_supported).
#
# Detection order — each tier runs only if the previous one found nothing:
#   1. Resolve ts_bin's REAL path (_ts_realpath). If it lives under
#      /Applications/Tailscale.app/ (or HMD_TAILSCALE_APP_PLIST is set — see
#      _ts_app_bundle_gate), read that bundle's CFBundleIdentifier (_ts_bundle_id)
#      from /Applications/Tailscale.app/Contents/Info.plist (or the override path).
#      io.tailscale.ipn.macsys -> macsys; io.tailscale.ipn.macos -> appstore;
#      anything else (unreadable, unrecognized) falls through to tier 2, same as not
#      being under Tailscale.app at all.
#   2. A Homebrew path (/opt/homebrew/bin/tailscale, /opt/homebrew/Cellar/tailscale/*,
#      /usr/local/bin/tailscale, or anything under `brew --prefix`) or a Linux system
#      path (/usr/bin/tailscale, /usr/sbin/tailscale) -> oss.
#   3. `tailscale version --json`, scanned recursively (jq's `..`) for either known
#      bundle-id string appearing ANYWHERE in the JSON, not a fixed field name —
#      checked for real on this machine, 2026-09-21, real Homebrew tailscale 1.102.4:
#        {"majorMinorPatch":"1.102.4","short":"1.102.4","long":"1.102.4-t...",
#         "gitCommit":"...","osVariant":"darwin","gitCommitTime":"...","cap":142}
#      No field distinguishes oss/macsys/appstore here (osVariant is the OS family,
#      not the packaging variant) — this tier is a live forward-compatible probe,
#      matching this file's existing philosophy (see ts_funnel_scoped_off_supported's
#      comment), not a check known to fire on any build tested so far. It costs one
#      already-resolved-binary invocation and, today, always falls through to tier 4.
#   4. unknown.
ts_variant() {
  local bin real plist bid json brew_prefix

  bin="$(ts_bin 2>/dev/null)" || { printf 'unknown'; return 0; }
  real="$(_ts_realpath "$bin")"
  [ -n "$real" ] || real="$bin"

  if _ts_app_bundle_gate "$real"; then
    plist="${HMD_TAILSCALE_APP_PLIST:-/Applications/Tailscale.app/Contents/Info.plist}"
    bid="$(_ts_bundle_id "$plist")"
    case "$bid" in
      io.tailscale.ipn.macsys) printf 'macsys'; return 0 ;;
      io.tailscale.ipn.macos)  printf 'appstore'; return 0 ;;
    esac
  fi

  case "$real" in
    /opt/homebrew/bin/tailscale|/opt/homebrew/Cellar/tailscale/*|/usr/local/bin/tailscale|/usr/bin/tailscale|/usr/sbin/tailscale)
      printf 'oss'
      return 0
      ;;
  esac
  if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [ -n "$brew_prefix" ]; then
      case "$real" in
        "$brew_prefix"/*) printf 'oss'; return 0 ;;
      esac
    fi
  fi

  json="$("$bin" version --json 2>/dev/null || true)"
  if [ -n "$json" ]; then
    bid="$(printf '%s' "$json" | jq -r '.. | strings | select(. == "io.tailscale.ipn.macsys" or . == "io.tailscale.ipn.macos")' 2>/dev/null | head -1)"
    case "$bid" in
      io.tailscale.ipn.macsys) printf 'macsys'; return 0 ;;
      io.tailscale.ipn.macos)  printf 'appstore'; return 0 ;;
    esac
  fi

  printf 'unknown'
  return 0
}

# _ts_funnel_unsupported_variant VARIANT — print the shared macsys/appstore Funnel
# refusal line on stderr (D7). Internal helper shared by ts_funnel_supported (which
# then prints "none" and returns 0) and ts_funnel_start's guard (which then returns
# 9), so the wording can never drift between the two call sites.
_ts_funnel_unsupported_variant() {
  printf 'funnel: %s build does not support Funnel; install the open-source build: brew install tailscale\n' "$1" >&2
}

# ts_funnel_supported — probe `tailscale funnel --help` and classify the CLI's funnel
# syntax generation by content, not exit code (exit code varies across CLI versions;
# the help text's shape doesn't). VARIANT-AWARE (D7): macsys/appstore builds print the
# same modern --help text as oss (same CLI binary, different packaging) but cannot run
# Funnel at all, so ts_variant is checked FIRST and short-circuits to "none" for those
# two, regardless of what --help says. Always prints exactly one of:
#   modern   --bg / --https flags (current CLI, confirmed via a real `tailscale
#            funnel --help` on this machine: v1.94.2 shows both)
#   legacy   the older `funnel <port> on|off` form
#   none     funnel subcommand unavailable, tailscale itself unresolvable, or the
#            resolved build is macsys/appstore (D7 — a stderr hint names the
#            brew-install fix; see _ts_funnel_unsupported_variant)
# Exit 0 always — the printed word is the result, not the exit status.
ts_funnel_supported() {
  local bin help variant
  bin="$(ts_bin 2>/dev/null)" || { printf 'none'; return 0; }
  variant="$(ts_variant)"
  case "$variant" in
    macsys|appstore)
      _ts_funnel_unsupported_variant "$variant"
      printf 'none'
      return 0
      ;;
  esac
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

# _ts_funnel_await OUT WAIT_S CMD... — run CMD... (a `tailscale funnel ...`
# invocation) backgrounded, with its combined stdout+stderr appended to OUT, and
# TAIL that combined output for a Tailscale tailnet-Funnel approval URL
# (login.tailscale.com) while it runs (D8). The moment that URL is seen, this
# prints the CLI's own matching line verbatim to the caller's stderr (D4: never
# paraphrased) plus a one-line "open that URL…" follow-up — exactly once, even if
# CMD keeps running past that point.
# Polling idiom (kill -0 / sleep 1) matches bin/heimdall-app's own
# _run_with_timeout (bin/heimdall-app:322); WAIT_S is a budget in whole seconds,
# not a hard preemptive kill — CMD is never killed on expiry (see D8: it is
# tailscaled's own poll for approval, which resolves asynchronously the moment
# the operator clicks the link).
# Exit 0: CMD exited 0 inside the window. Exit 3: WAIT_S elapsed while CMD was
# still running, or CMD exited nonzero, and the approval URL was seen at some
# point — the caller (ts_funnel_start) treats this the same as its own
# pre-existing tailnet-policy-hint exit. Exit 1: CMD exited nonzero and no
# approval URL was ever seen — the caller falls back to its own existing
# rc/hint handling, unchanged.
_ts_funnel_await() {
  local out="$1" wait_s="$2"
  shift 2
  local pid rc line url_seen=0 waited=0

  ( "$@" >>"$out" 2>&1 ) &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$url_seen" -eq 0 ]; then
      line="$(grep -i 'login\.tailscale\.com' "$out" 2>/dev/null | head -1)"
      if [ -n "$line" ]; then
        url_seen=1
        printf '%s\n' "$line" >&2
        printf 'hmd_tailscale: open that URL to approve Funnel for this node; waiting up to %ss...\n' "$wait_s" >&2
      fi
    fi
    if [ "$waited" -ge "$wait_s" ]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    rc=124
  else
    wait "$pid" 2>/dev/null
    rc=$?
  fi

  if [ "$url_seen" -eq 0 ]; then
    line="$(grep -i 'login\.tailscale\.com' "$out" 2>/dev/null | head -1)"
    if [ -n "$line" ]; then
      url_seen=1
      printf '%s\n' "$line" >&2
      printf 'hmd_tailscale: open that URL to approve Funnel for this node; waiting up to %ss...\n' "$wait_s" >&2
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    return 0
  fi

  if [ "$url_seen" -eq 1 ]; then
    return 3
  fi

  return 1
}

# ts_funnel_start PORT HTTPS_PORT — start funnel using the syntax matching
# ts_funnel_supported's probe.
# Exit 0: funnel started (the underlying CLI exited 0, tailnet-approval wait or
# not — see D8). Exit 64: HTTPS_PORT is not one of 443|8443|10000 (Decision D4 —
# EX_USAGE; checked BEFORE the binary is ever invoked). Exit 9: the resolved
# build is macsys/appstore (D7) — Funnel does not run on either, so this refuses
# before ever invoking the CLI; a stderr hint names the brew-install fix. Checked
# after the HTTPS_PORT validation (a malformed call is still a malformed call
# regardless of the installed build) but before resolving/invoking the tailscale
# binary for real. Exit 3: EITHER tailscale refused outright with a tailnet-policy
# hint (HTTPS certs / funnel attribute not enabled), OR (D8) a tailnet-Funnel
# approval URL was seen and HMD_FUNNEL_APPROVE_WAIT_S elapsed before the CLI
# itself finished — in both cases the hint/URL is printed VERBATIM on stderr, per
# D4, never paraphrased. Exit 1: tailscale unresolvable, or funnel unsupported on
# this CLI. Other nonzero: passed through from the underlying tailscale
# invocation.
ts_funnel_start() {
  local port="$1" https_port="$2"
  case "$https_port" in
    443|8443|10000) ;;
    *)
      printf 'hmd_tailscale: HTTPS_PORT must be one of 443, 8443, 10000 (got: %s)\n' "$https_port" >&2
      return 64
      ;;
  esac

  local variant
  variant="$(ts_variant)"
  case "$variant" in
    macsys|appstore)
      _ts_funnel_unsupported_variant "$variant"
      return 9
      ;;
  esac

  local bin mode
  bin="$(ts_bin 2>/dev/null)" || return 1
  mode="$(ts_funnel_supported)"
  case "$mode" in
    modern|legacy) ;;
    *) return 1 ;;
  esac

  # D8 / A6-style hardening (matches bin/heimdall-app's own UI_OUT): mktemp is
  # required, not best-effort — a `/tmp/$$` fallback is a predictable,
  # symlink-plantable path. umask 077 means the file is 0600 even if mktemp's
  # own default were ever looser than that on some platform.
  if ! command -v mktemp >/dev/null 2>&1; then
    printf 'hmd_tailscale: required tool missing: mktemp\n' >&2
    return 1
  fi
  local out old_umask mktemp_rc
  old_umask="$(umask)"
  umask 077
  out="$(mktemp 2>/dev/null)"
  mktemp_rc=$?
  umask "$old_umask"
  if [ "$mktemp_rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'hmd_tailscale: mktemp failed to create a temp file\n' >&2
    return 1
  fi

  local wait_s rc
  wait_s="${HMD_FUNNEL_APPROVE_WAIT_S:-40}"

  case "$mode" in
    modern)
      _ts_funnel_await "$out" "$wait_s" \
        "$bin" funnel --bg "--https=${https_port}" "http://127.0.0.1:${port}"
      rc=$?
      ;;
    legacy)
      "$bin" serve https / "http://127.0.0.1:${port}" >"$out" 2>&1
      rc=$?
      if [ "$rc" -eq 0 ]; then
        _ts_funnel_await "$out" "$wait_s" "$bin" funnel "${https_port}" on
        rc=$?
      fi
      ;;
  esac

  if [ "$rc" -eq 0 ]; then
    rm -f "$out" 2>/dev/null || true
    return 0
  fi

  if [ "$rc" -eq 3 ]; then
    # _ts_funnel_await already printed the approval URL + follow-up verbatim.
    rm -f "$out" 2>/dev/null || true
    return 3
  fi

  # Same case-insensitive matcher for a policy/approval hint regardless of
  # which stream it arrived on, now that both are captured together (D8):
  # `funnel` plus one of enable/attribute/policy/acl/visit/login.tailscale.com.
  if grep -qi 'funnel' "$out" 2>/dev/null && grep -qi -E 'enable|attribute|policy|acl|visit|login\.tailscale\.com' "$out" 2>/dev/null; then
    cat "$out" >&2
    rm -f "$out" 2>/dev/null || true
    return 3
  fi
  cat "$out" >&2
  rm -f "$out" 2>/dev/null || true
  return "$rc"
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
