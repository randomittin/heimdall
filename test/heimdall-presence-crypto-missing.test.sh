#!/usr/bin/env bash
# heimdall-presence-crypto-missing.test.sh — the LOUD, diagnosable crypto-gap signal.
#
# THE BUG THIS GATES (cost RJ + two teammates hours). When the Ed25519 signing backend is
# missing, cp_auth.generate_keypair() raises AuthError('crypto_unavailable') → the client's
# seed bootstrap swallowed it (`except Exception: return ""`) → no seed → the beat was dropped
# UNSIGNED → the dev was INVISIBLE on the presence wall with ZERO indication why. NOTHING
# surfaced the crypto gap.
#
# THE FIX (falsifiable here):
#   1. An INTERACTIVE `heimdall-presence beat` with the backend missing prints ONE actionable
#      stderr line naming the ACTUAL interpreter + the pip fix (RED before: silent). Exit 0.
#   2. The statusline/keeper RENDER FORK (non-interactive: stderr redirected, no tty) stays
#      SILENT + exit 0 — no warning, no traceback, no spam (the strict silent-safe contract).
#   3. `heimdall-presence status` REPORTS the gap: `signing:   MISSING — ... pip install ...`
#      (RED before: no signing line at all). With the backend present it reports `OK`.
#   4. The warning THROTTLES to ONE line per window (a 2nd interactive beat is muted).
#
# HOW crypto-unavailable is SIMULATED (no host mutation, real cp_auth code). We PREPEND a dir
# of FAKE `cryptography` + `nacl` MODULES (not packages) to PYTHONPATH: cp_auth's guarded
# `from cryptography.hazmat... import` and `import nacl.signing` then both raise → _BACKEND=None
# → crypto_available() is genuinely False through the REAL module. INTERACTIVE is forced via the
# documented HMD_PRESENCE_INTERACTIVE seam (CI has no pty); the render-fork proof runs the AUTO
# path (no seam, stderr redirected → [ -t 2 ] False) to prove the natural gating stays silent.
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-presence"
LIB="$REPO/bin/lib"
# This suite validates the crypto-missing degrade on a repo with a github.com remote. Disable the
# zero-touch auto-github path (POST /team/auto) so it stays hermetic (no real `gh api user`); the
# auto-github path has its OWN hermetic suite (heimdall-presence-autoteam).
export HMD_AUTO_TEAM_DISABLE=1

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$BIN" ] || { echo "FATAL: $BIN missing/!exec" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

CRYPTO="$("$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;print('1' if cp_auth.crypto_available() else '0')" 2>/dev/null || echo 0)"

WORK="$(mktemp -d -t "presence-crypto.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

HOME_T="$WORK/home"; mkdir -p "$HOME_T/.heimdall"
# OPT IN (the crypto-gap warning lives DOWNSTREAM of the control-plane opt-in gate — an
# UNDECIDED dev is intentionally offline and never reaches the signing path). Persist a
# CONNECTED decision pointed at an UNROUTABLE url so URL resolves non-empty (the beat reaches
# the seed/crypto bootstrap — the exact path that hid the gap) while GUARANTEEING zero egress.
printf '{"decision": "connected", "url": "http://127.0.0.1:9"}\n' > "$HOME_T/.heimdall/cp-consent.json"

# A project repo with a git remote so HAID/PROJECT resolve (the beat reaches the seed
# bootstrap — the exact code path that hid the gap). The per-home CONNECTED consent above
# makes URL non-empty (the crypto path is downstream of the opt-in gate), and crypto-missing
# is settled BEFORE any network call, so no egress ever happens.
PROJ="$WORK/proj"; mkdir -p "$PROJ"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email "dev@example.com"
git -C "$PROJ" config user.name "Dev"
git -C "$PROJ" remote add origin "https://github.com/acme/widget.git"

# The fake-backend dir: shadow BOTH cryptography and pynacl so cp_auth degrades to _BACKEND=None.
FAKE="$WORK/fakelib"; mkdir -p "$FAKE"
: > "$FAKE/cryptography.py"   # a MODULE (not a package) → `from cryptography.hazmat...` raises.
: > "$FAKE/nacl.py"          # a MODULE (not a package) → `import nacl.signing` raises.

# Sanity: the shadow genuinely forces crypto_available() False through the real cp_auth.
SHADOW="$(PYTHONPATH="$FAKE" "$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;print('1' if cp_auth.crypto_available() else '0')" 2>/dev/null || echo '?')"
[ "$SHADOW" = "0" ] || { echo "FATAL: PYTHONPATH shadow did not force crypto_available()=False (got '$SHADOW')" >&2; exit 2; }

# run_missing <extra-env...> -- <subcommand args...> : run the client from inside the project
# with the FAKE backend on PYTHONPATH and a clean env (no manual URL exports).
run_missing() {
  local envs=(); while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift || true
  ( cd "$PROJ" && env -u HEIMDALL_CP_URL -u BASE_URL -u HEIMDALL_CP_PKI_KEY \
      HOME="$HOME_T" HEIMDALL_TEAM_DIR="$HOME_T/.heimdall" HMD_HAID="haid:cryptotest" \
      PYTHONPATH="$FAKE" ${envs[@]+"${envs[@]}"} "$BIN" "$@" )
}

echo "============================================================"
echo "PRESENCE crypto-gap signal (host crypto=$CRYPTO, shadowed=missing)"
echo "============================================================"
echo

# ── 1. INTERACTIVE beat with the backend MISSING → LOUD, actionable, exit 0 ──
echo "1. an INTERACTIVE beat with the Ed25519 backend missing prints ONE actionable line"
run_missing HMD_PRESENCE_INTERACTIVE=1 -- beat >"$WORK/i.out" 2>"$WORK/i.err"; IX="$?"
if [ "$IX" = "0" ] \
   && grep -q "signing backend missing (Ed25519)" "$WORK/i.err" \
   && grep -q "INVISIBLE to your team" "$WORK/i.err" \
   && grep -q -- "-m pip install --user cryptography" "$WORK/i.err"; then
  ok "1a interactive beat NAMED the missing backend + the pip fix on stderr, and exited 0"
else
  bad "1a interactive beat did not surface the actionable crypto warning (exit=$IX); stderr:"; sed 's/^/    /' "$WORK/i.err" >&2
fi
# the ACTUAL interpreter path is substituted (sys.executable), not a placeholder.
if grep -qE "fix: /[^ ]*python[^ ]* -m pip install --user cryptography" "$WORK/i.err"; then
  ok "1b the warning substituted the ACTUAL interpreter path (a runnable fix, not a placeholder)"
else
  bad "1b the warning did not name a concrete interpreter path; stderr:"; sed 's/^/    /' "$WORK/i.err" >&2
fi
# stdout stays CLEAN (the statusline reads stdout — the warning must never leak there).
if [ ! -s "$WORK/i.out" ]; then
  ok "1c stdout stayed CLEAN (the warning is stderr-only — stdout is the statusline's channel)"
else
  bad "1c stdout was not clean:"; sed 's/^/    /' "$WORK/i.out" >&2
fi

# ── 2. the RENDER FORK (statusline/keeper) stays SILENT + exit 0 even when crypto is missing ──
echo
echo "2. the statusline RENDER FORK stays SILENT + exit 0 (crypto missing) — no spam, no traceback"
# Mimic the statusline's exact fork: HMD_HANDLE/HMD_VERDICT set, NO interactive seam, stderr
# redirected to a file (so [ -t 2 ] is False, as it is when the statusline redirects to /dev/null).
run_missing HMD_HANDLE=alice HMD_VERDICT=working -- beat >"$WORK/r.out" 2>"$WORK/r.err"; RX="$?"
if [ "$RX" = "0" ] && [ ! -s "$WORK/r.err" ] && [ ! -s "$WORK/r.out" ]; then
  ok "2a the render fork was SILENT (empty stderr+stdout) and exited 0 — the silent-safe contract holds"
else
  bad "2a the render fork was NOT silent (exit=$RX, stderr $(wc -c <"$WORK/r.err")B, stdout $(wc -c <"$WORK/r.out")B):"; sed 's/^/    /' "$WORK/r.err" >&2
fi
if ! grep -qi "traceback" "$WORK/r.err"; then
  ok "2b the render fork produced NO python traceback (never breaks the statusline)"
else
  bad "2b the render fork leaked a traceback:"; sed 's/^/    /' "$WORK/r.err" >&2
fi

# ── 3. `status` REPORTS the crypto gap (the natural place a dev checks) ──
echo
echo "3. status reports signing: MISSING with the fix (crypto missing)"
run_missing -- status >"$WORK/s.out" 2>/dev/null
if grep -qE "^  signing: +MISSING — presence disabled, run /[^ ]*python[^ ]* -m pip install --user cryptography$" "$WORK/s.out"; then
  ok "3a status printed the signing:MISSING line naming the fix"
else
  bad "3a status did not report the crypto gap; status:"; sed 's/^/    /' "$WORK/s.out" >&2
fi

# ── 4. THROTTLE: a 2nd interactive beat within the window is MUTED (one line per window) ──
echo
echo "4. the warning throttles: a 2nd interactive beat within the window is MUTED"
# beat #1 (above, section 1) already wrote the crypto-warn stamp. A 2nd interactive beat now:
run_missing HMD_PRESENCE_INTERACTIVE=1 -- beat 2>"$WORK/t.err"; TX="$?"
if [ "$TX" = "0" ] && [ ! -s "$WORK/t.err" ]; then
  ok "4a the 2nd interactive beat within the window was MUTED (throttle holds — one line per window)"
else
  bad "4a the throttle did not hold (exit=$TX); stderr:"; sed 's/^/    /' "$WORK/t.err" >&2
fi
WARN_STAMP="$(ls "$HOME_T/.heimdall/pki/"*.crypto-warn 2>/dev/null | head -1 || true)"
if [ -n "$WARN_STAMP" ]; then
  ok "4b a dedicated crypto-warn throttle stamp was written ($WARN_STAMP)"
else
  bad "4b no crypto-warn throttle stamp was written under \$HOME/.heimdall/pki"
fi

# ── 5. with the backend PRESENT → NO warning, status reports OK (only when the host has crypto) ──
echo
if [ "$CRYPTO" = "1" ]; then
  echo "5. with the Ed25519 backend PRESENT: no warning, status reports OK"
  HOME_OK="$WORK/home_ok"; mkdir -p "$HOME_OK/.heimdall"
  # opted-in home too (URL resolves non-empty via consent; unroutable => zero egress).
  printf '{"decision": "connected", "url": "http://127.0.0.1:9"}\n' > "$HOME_OK/.heimdall/cp-consent.json"
  # interactive beat, backend present → the crypto-missing line must NOT appear.
  ( cd "$PROJ" && env -u HEIMDALL_CP_URL -u BASE_URL -u HEIMDALL_CP_PKI_KEY \
      HOME="$HOME_OK" HEIMDALL_TEAM_DIR="$HOME_OK/.heimdall" HMD_HAID="haid:cryptotest" \
      HMD_PRESENCE_INTERACTIVE=1 "$BIN" beat ) >/dev/null 2>"$WORK/ok.err"; OKX="$?"
  if [ "$OKX" = "0" ] && ! grep -q "signing backend missing" "$WORK/ok.err"; then
    ok "5a a backend-present interactive beat printed NO crypto-missing warning (exit 0)"
  else
    bad "5a a backend-present beat wrongly warned (exit=$OKX); stderr:"; sed 's/^/    /' "$WORK/ok.err" >&2
  fi
  ( cd "$PROJ" && env HOME="$HOME_OK" HEIMDALL_TEAM_DIR="$HOME_OK/.heimdall" HMD_HAID="haid:cryptotest" \
      "$BIN" status ) >"$WORK/ok.status" 2>/dev/null
  if grep -qE "^  signing: +Ed25519 backend OK" "$WORK/ok.status"; then
    ok "5b status reported signing: Ed25519 backend OK when the backend is present"
  else
    bad "5b status did not report the backend OK; status:"; sed 's/^/    /' "$WORK/ok.status" >&2
  fi
else
  echo "5. SKIPPED: this host has no Ed25519 backend — the crypto-PRESENT proof needs a real backend."
fi

echo
echo "============================================================"
printf "heimdall-presence-crypto-missing: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
