#!/usr/bin/env bash
# install-receipt.sh — the auto-install receipt (M0, interim install transparency).
# SOURCED by install.sh, bin/heimdall and bin/discover-skills; defines functions, runs nothing.
#
# WHY: the auto-install paths ran `claude plugins install … || true`, fell back to an unlisted
# third-party marketplace, and recorded nothing — an install could land code on the machine, or
# fail, with no trace. That contradicts the install-transparency stance in README / docs/INSTALL.md.
#
# WHAT NOW: every install attempt (plugin, marketplace registration, skill clone) appends ONE NDJSON
# line to the run's receipt, $HEIMDALL_HOME/receipts/installs-<run id>.ndjson (default home
# ~/.heimdall; run id = $HMD_RUN_ID, minted once per launch by bin/heimdall). `summary-card --receipt`
# lists that run's lines. A line is {ts, run, kind, name, version, source, pin, result, via} plus, for
# anything that did not install, {detail, note}. A failure prints `install failed, continuing without
# <name>` on stderr and records the same sentence in `note`: the run goes on without the plugin
# (fail-open, as before) but never silently. A refusal (below) is a failure of the same shape.
#
# SOURCES: only the marketplaces named in hmd_marketplace_source() are ever registered. There is no
# fallback to any other marketplace; an unlisted name is refused without invoking `claude`. This is
# NOT a consent model (3.1): listed sources still install without asking, exactly as before — they
# are now named, receipted and reported. `--yes` / `--accept-command` are never passed, so a plugin
# whose marketplace declares an install command is refused by the CLI rather than run unattended.
#
# PINS (verified against Claude Code 2.1.295, 2026-10-15): `claude plugin install` has no version
# flag. The one documented pin is `#ref` on a marketplace SOURCE (owner/repo#v1.2.0 — a branch or
# TAG; a commit sha is rejected: "Remote branch <sha> not found"). anthropics/claude-plugins-official
# publishes no tags, so its plugins cannot be pinned through the CLI; the receipt records the version
# the CLI actually resolved instead. To pin a source, put the `#ref` in hmd_marketplace_source() — it
# is passed to the CLI verbatim and shows up in the receipt's `source` and `pin`.
#
# Bash 3.2-safe (macOS /bin/bash): no associative arrays, no ${var,,}. Safe under `set -euo pipefail`:
# every function returns the underlying command's status and never aborts its caller on its own.

# Path of this run's receipt. The run id is reduced to [A-Za-z0-9._-] (summary-card does the same).
hmd_install_receipt_file() {
  local rid
  rid="$(printf '%s' "${HMD_RUN_ID:-manual}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  printf '%s' "${HMD_RECEIPTS_DIR:-${HEIMDALL_HOME:-$HOME/.heimdall}/receipts}/installs-$rid.ndjson"
}

# Printable ASCII only (anything else → '?'), cut to $2 chars, then JSON-escaped: a hostile or binary
# error message can never produce an invalid or multi-line receipt record.
_hmd_ir_clean() {
  printf '%s' "$1" | LC_ALL=C tr -c ' -~' '?' | cut -c1-"${2:-200}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# hmd_install_receipt KIND NAME VERSION SOURCE PIN RESULT VIA [DETAIL] — append one record.
# RESULT is ok | failed | refused. Warns on stderr (never silent) when the receipt cannot be written.
hmd_install_receipt() {
  local kind="${1:-}" name="${2:-}" version="${3:-unknown}" src="${4:-}" pin="${5:-none}"
  local result="${6:-}" via="${7:-}" detail="${8:-}"
  local file dir extra="" line
  file="$(hmd_install_receipt_file)"
  dir="$(dirname "$file")"
  if [ "$result" != "ok" ]; then
    extra=",\"detail\":\"$(_hmd_ir_clean "$detail" 200)\",\"note\":\"$(_hmd_ir_clean "install failed, continuing without $name" 200)\""
  fi
  line="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"run\":\"$(_hmd_ir_clean "${HMD_RUN_ID:-manual}" 64)\""
  line="$line,\"kind\":\"$(_hmd_ir_clean "$kind" 16)\",\"name\":\"$(_hmd_ir_clean "$name" 120)\""
  line="$line,\"version\":\"$(_hmd_ir_clean "$version" 64)\",\"source\":\"$(_hmd_ir_clean "$src" 200)\""
  line="$line,\"pin\":\"$(_hmd_ir_clean "$pin" 64)\",\"result\":\"$(_hmd_ir_clean "$result" 16)\""
  line="$line,\"via\":\"$(_hmd_ir_clean "$via" 32)\"$extra}"
  if mkdir -p "$dir" 2>/dev/null && printf '%s\n' "$line" >> "$file" 2>/dev/null; then
    return 0
  fi
  printf '  ⚠ hmd: could not write the install receipt %s (%s %s: %s)\n' "$file" "$kind" "$name" "$result" >&2
  return 1
}

# The ref after '#' in a marketplace source, or "none".
_hmd_ir_pin() {
  case "$1" in
    *'#'*) printf '%s' "${1#*#}" ;;
    *)     printf 'none' ;;
  esac
}

# Last non-blank line of a command's output (the CLI prints the reason last), else a generic one.
_hmd_ir_detail() {  # OUTPUT RC LABEL
  local d
  d="$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
  [ -n "$d" ] || d="$3 exit $2"
  printf '%s' "$d"
}

# The visible half of "not silent": stderr, in the one form every call site shares.
_hmd_ir_warn() {  # NAME SOURCE DETAIL
  printf '  ⚠ hmd: install failed, continuing without %s (source %s): %s\n' "$1" "$2" "${3:-no detail}" >&2
}

# hmd_installed_version ID — the version the CLI resolved for an installed plugin id, else "unknown".
# Reads the pretty-printed `claude plugins list --json` (id line, then its version line) with awk, so
# it needs neither jq nor python; any other shape just yields "unknown".
hmd_installed_version() {
  local v
  v="$(claude plugins list --json 2>/dev/null | awk -v id="$1" '
    index($0, "\"id\": \"" id "\"") { hit = 1; next }
    hit && /"version":/ { sub(/^[^:]*: *"/, ""); sub(/".*$/, ""); print; exit }' || true)"
  printf '%s' "${v:-unknown}"
}

# hmd_plugin_install ID SOURCE PIN VIA [VERSION_HINT] — run the CLI install, receipt the attempt,
# report a failure on stderr. Returns the CLI's exit status; the CALLER decides to continue.
hmd_plugin_install() {
  local id="$1" src="$2" pin="$3" via="$4" hint="${5:-}" out="" rc=0 version detail
  out="$(claude plugins install "$id" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    version="$(hmd_installed_version "$id")"
    if [ "$version" = "unknown" ] && [ -n "$hint" ]; then version="$hint"; fi
    hmd_install_receipt plugin "$id" "$version" "$src" "$pin" ok "$via" || true
    return 0
  fi
  detail="$(_hmd_ir_detail "$out" "$rc" "claude plugins install")"
  hmd_install_receipt plugin "$id" unknown "$src" "$pin" failed "$via" "$detail" || true
  _hmd_ir_warn "$id" "$src" "$detail"
  return "$rc"
}

# hmd_marketplace_source NAME — the source of a LISTED marketplace, or status 1. The whole allow-list.
hmd_marketplace_source() {
  case "${1:-}" in
    claude-plugins-official) printf '%s' "anthropics/claude-plugins-official" ;;
    heimdall-marketplace)    printf '%s' "randomittin/heimdall-marketplace" ;;
    *)                       return 1 ;;
  esac
}

# hmd_marketplace_add NAME VIA — register a LISTED marketplace; receipted, loud on failure.
hmd_marketplace_add() {
  local name="$1" via="$2" src out="" rc=0 detail
  if ! src="$(hmd_marketplace_source "$name")"; then
    hmd_install_receipt marketplace "$name" n/a "$name" none refused "$via" "not a listed marketplace" || true
    _hmd_ir_warn "marketplace $name" "$name" "not a listed marketplace"
    return 1
  fi
  out="$(claude plugins marketplace add "$src" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    hmd_install_receipt marketplace "$name" n/a "$src" "$(_hmd_ir_pin "$src")" ok "$via" || true
    return 0
  fi
  detail="$(_hmd_ir_detail "$out" "$rc" "claude plugins marketplace add")"
  hmd_install_receipt marketplace "$name" n/a "$src" "$(_hmd_ir_pin "$src")" failed "$via" "$detail" || true
  _hmd_ir_warn "marketplace $name" "$src" "$detail"
  return "$rc"
}

# hmd_install_known_plugin PLUGIN MARKETPLACE VIA — install PLUGIN@MARKETPLACE from a LISTED
# marketplace (registering it first when absent). An unlisted MARKETPLACE is refused without
# invoking `claude`. Returns the install's status; a failed registration is reported and receipted
# by hmd_marketplace_add, and the install still gets its own attempt (the CLI may know the source).
hmd_install_known_plugin() {
  local plugin="$1" mkt="$2" via="$3" src
  if ! src="$(hmd_marketplace_source "$mkt")"; then
    hmd_install_receipt plugin "$plugin@$mkt" unknown "$mkt" none refused "$via" "marketplace $mkt is not a listed source" || true
    _hmd_ir_warn "$plugin@$mkt" "$mkt" "marketplace $mkt is not a listed source"
    return 1
  fi
  if ! claude plugins marketplace list 2>/dev/null | grep -q "$mkt"; then
    hmd_marketplace_add "$mkt" "$via" || true
  fi
  hmd_plugin_install "$plugin@$mkt" "$src" "$(_hmd_ir_pin "$src")" "$via"
}

# hmd_skill_install NAME REPO DEST VIA — shallow-clone a registry skill; the receipt records the commit
# cloned (the registry carries no ref, so the skill is unpinned). Returns git's status.
hmd_skill_install() {
  local name="$1" repo="$2" dest="$3" via="$4" out="" rc=0 sha detail
  out="$(git clone --depth 1 "https://github.com/${repo}.git" "$dest" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    sha="$(git -C "$dest" rev-parse --short=12 HEAD 2>/dev/null || true)"
    hmd_install_receipt skill "$name" "${sha:-unknown}" "github.com/$repo" none ok "$via" || true
    return 0
  fi
  detail="$(_hmd_ir_detail "$out" "$rc" "git clone")"
  hmd_install_receipt skill "$name" unknown "github.com/$repo" none failed "$via" "$detail" || true
  _hmd_ir_warn "$name" "github.com/$repo" "$detail"
  return "$rc"
}
