# cp-consent.sh — Heimdall control-plane URL + opt-in consent (SINGLE SOURCE OF TRUTH).
#
# Sourced by bin/heimdall-presence, bin/heimdall-presence-doctor, bin/heimdall-invite.
# Holds (a) the canonical public control-plane URL literal — the ONE place in bin/ it lives —
# and (b) the opt-in consent store the presence layer gates phone-home on. bash-only
# ($(<file), [[ =~ ]], BASH_REMATCH); every reader is #!/usr/bin/env bash.
#
# CONSENT MODEL (fail-safe DEFAULT OFF): presence resolves the baked-in public CP URL ONLY
# when the dev has EXPLICITLY opted in — a persisted {"decision":"connected"} in
# ~/.heimdall/cp-consent.json. Undecided OR declined => NO default URL => presence degrades to
# LOCAL/offline (zero beats), so nothing is ever sent to the control plane unasked. An explicit
# --url / $HEIMDALL_CP_URL / $BASE_URL / cp-endpoint.json still overrides and connects (an
# install-time or power-user choice IS consent). The decision is persisted so a dev is prompted
# at most ONCE and never re-nagged. `hmd presence connect` / `disconnect` flip it later.

# The canonical public-surface control-plane URL (NOT a secret — a public
# --allow-unauthenticated Cloud Run endpoint). This literal lives HERE and NOWHERE ELSE in
# bin/; every reader sources this file and reads $HEIMDALL_DEFAULT_CP_URL.
HEIMDALL_DEFAULT_CP_URL="https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app"

# The consent store path (0600, per-user, under the runtime home). HMD_CP_CONSENT_FILE
# overrides it for hermetic tests; else it derives from HOME (the same ~/.heimdall the
# presence layer already uses for cp-endpoint.json + the pki seed).
_cp_consent_file() {
  if [ -n "${HMD_CP_CONSENT_FILE:-}" ]; then printf '%s' "$HMD_CP_CONSENT_FILE"; return; fi
  printf '%s/.heimdall/cp-consent.json' "${HOME:-}"
}

# The persisted decision: prints "connected", "declined", or "" (undecided/absent). Pure-bash
# read (no python, no subprocess) so it is cheap on the beat hot path and cannot traceback.
_cp_consent_decision() {
  local f c; f="$(_cp_consent_file)"; [ -f "$f" ] || return 0
  c="$(<"$f")" 2>/dev/null || return 0
  if [[ "$c" =~ \"decision\"[[:space:]]*:[[:space:]]*\"connected\" ]]; then printf 'connected'
  elif [[ "$c" =~ \"decision\"[[:space:]]*:[[:space:]]*\"declined\" ]]; then printf 'declined'
  fi
}

# The URL to use when connected: the stored .url if present, else the canonical default.
_cp_consent_url() {
  local f c; f="$(_cp_consent_file)"
  if [ -f "$f" ]; then
    c="$(<"$f")" 2>/dev/null || c=""
    if [[ "$c" =~ \"url\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then printf '%s' "${BASH_REMATCH[1]}"; return; fi
  fi
  printf '%s' "$HEIMDALL_DEFAULT_CP_URL"
}

# Atomic 0600 write of the consent store (mkdir + tmp + mv). $1 = the JSON body.
_write_cp_consent() {
  local f dir tmp; f="$(_cp_consent_file)"; dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || true
  tmp="$f.tmp.$$"
  if printf '%s\n' "$1" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  else
    rm -f "$tmp" 2>/dev/null; return 1
  fi
}
