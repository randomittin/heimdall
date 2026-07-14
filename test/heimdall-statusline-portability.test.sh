#!/usr/bin/env bash
# heimdall-statusline-portability.test.sh — the statusline must activate + render
# for ANY teammate on ANY checkout/username, not just RJ.
#
# THE RJ-ONLY BUG (root cause, evidenced): the working statusLine registration
# lived ONLY in RJ's personal ~/.claude/settings.json, hardcoded to the absolute
# path /Users/rj/Downloads/heimdall/hooks/statusline.sh (RJ's dev checkout) and
# with subagentStatusLine=null. User-global settings never ship to teammates, and
# an absolute /Users/rj path breaks on every other machine/username/checkout. The
# git-tracked repo settings.json uses ${CLAUDE_PLUGIN_ROOT}, which is UNSET in a
# user-level statusLine → the command silently emits nothing (a blank enter-box).
#
# THE FIX under test: bin/heimdall-statusline-register self-bootstraps the HUD into
# the user's ~/.claude/settings.json at a DYNAMICALLY-RESOLVED absolute plugin root
# (CLAUDE_PLUGIN_ROOT when the plugin injects it, else the bin's own location — never
# a hardcoded /Users/rj), idempotently, honoring a user's own custom statusLine. It
# ships to every teammate through the SessionStart hook (plugin-shipped, git-tracked)
# so a marketplace install — which never runs the curl install.sh — still activates.
#
# HERMETIC TEAMMATE SIM: a DIFFERENT $HOME, a checkout at a NON-/Users/rj path, NO
# ~/.heimdall state, NO pre-existing ~/.claude/settings.json. The registration must
# bake a PORTABLE absolute path (no /Users/rj, no unresolved ${CLAUDE_PLUGIN_ROOT}),
# the statusline must render + exit 0, and a fresh re-run must be an idempotent no-op.
#
# FALSIFIER: re-introduce a hardcoded /Users/rj path in the written command → the
# "no /Users/rj in the registered command" assertion FAILS (assert 4).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$REPO_ROOT/bin/heimdall-statusline-register"

FAILS=0
ok()  { printf 'OK  %s\n' "$*"; }
bad() { printf 'BAD %s\n' "$*"; FAILS=$((FAILS+1)); }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }

# ── Build a teammate checkout at a NON-/Users/rj path (a fresh temp root). Copy only
# the statusline surfaces the registration + render touch. HOME is a separate fresh
# dir with NO ~/.heimdall and NO ~/.claude, proving a virgin teammate. ──
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-slport.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DST="$WORK/teammate/heimdall"          # the "checkout" — deliberately NOT under /Users/rj
HOMEDIR="$WORK/home"                    # the teammate's fresh $HOME
mkdir -p "$DST" "$HOMEDIR"
# Canonicalize (resolve any // from a trailing-slash $TMPDIR + symlinks) so the
# substring comparison matches the bin's own `cd … pwd`-canonicalized root.
DST="$(cd "$DST" && pwd)"; HOMEDIR="$(cd "$HOMEDIR" && pwd)"
for d in hooks sentinels bin; do cp -R "$REPO_ROOT/$d" "$DST/" 2>/dev/null; done

case "$DST" in
  /Users/rj/*) echo "FATAL: sim checkout must NOT be under /Users/rj ($DST)"; exit 1 ;;
esac

SETTINGS="$HOMEDIR/.claude/settings.json"

# helper: read a top-level statusLine/subagentStatusLine .command from settings JSON
sl_cmd() { # $1=settings path  $2=key
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
v=(d.get(sys.argv[2]) or {})
print(v.get("command","") if isinstance(v,dict) else "")
PY
}

# ── 0) the bin exists and is executable ──
if [ -x "$REG" ]; then ok "bin/heimdall-statusline-register present + executable"
else bad "bin/heimdall-statusline-register missing/not executable ($REG)"; echo "FAILS=$FAILS"; exit 1; fi

# ── 1) virgin teammate register (NO CLAUDE_PLUGIN_ROOT → root resolves from the bin's
#       OWN location = the teammate checkout). Must write ~/.claude/settings.json. ──
STATE="$(env -i HOME="$HOMEDIR" PATH="/usr/bin:/bin:/usr/local/bin" \
  "$DST/bin/heimdall-statusline-register" register 2>/dev/null)"
if [ -f "$SETTINGS" ]; then ok "register wrote a fresh ~/.claude/settings.json (state=$STATE)"
else bad "register did NOT write ~/.claude/settings.json (state=$STATE)"; fi

# ── 2) BOTH statusLine and subagentStatusLine are wired (RJ's was null) ──
SL="$(sl_cmd "$SETTINGS" statusLine)"
SA="$(sl_cmd "$SETTINGS" subagentStatusLine)"
[ -n "$SL" ] && ok "statusLine registered" || bad "statusLine NOT registered"
[ -n "$SA" ] && ok "subagentStatusLine registered (RJ's was null)" || bad "subagentStatusLine NOT registered"

# ── 3) the registered commands point at THIS teammate's checkout (portable absolute
#       path), resolved dynamically — not a foreign path ──
case "$SL" in *"$DST/hooks/statusline.sh"*) ok "statusLine points at teammate checkout ($DST)" ;;
  *) bad "statusLine does NOT point at teammate checkout: $SL" ;; esac
case "$SA" in *"$DST/hooks/subagent-statusline.sh"*) ok "subagentStatusLine points at teammate checkout" ;;
  *) bad "subagentStatusLine does NOT point at teammate checkout: $SA" ;; esac

# ── 4) PORTABILITY / FALSIFIER: no /Users/rj, no unresolved ${CLAUDE_PLUGIN_ROOT}
#       or $PLUGIN_DIR in either written command. Re-introducing a hardcoded RJ path
#       or an unresolved var here fails the teammate sim. ──
for pair in "statusLine|$SL" "subagentStatusLine|$SA"; do
  key="${pair%%|*}"; cmd="${pair#*|}"
  case "$cmd" in
    *"/Users/rj"*)               bad "$key contains a hardcoded /Users/rj path (non-portable): $cmd" ;;
    *'${CLAUDE_PLUGIN_ROOT}'*|*'$CLAUDE_PLUGIN_ROOT'*|*'$PLUGIN_DIR'*)
                                 bad "$key contains an UNRESOLVED plugin-root var (renders blank in user settings): $cmd" ;;
    *)                           ok "$key is portable (no /Users/rj, no unresolved var)" ;;
  esac
done

# ── 5) the registered statusLine actually RENDERS a non-empty line + exits 0 for the
#       teammate — fresh $HOME, no ~/.heimdall state, run exactly as CC would ──
OUT="$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":21}}' "$DST" \
  | env -i HOME="$HOMEDIR" PATH="/usr/bin:/bin:/usr/local/bin" TERM=xterm bash -c "$SL" 2>/dev/null)"
RC=$?
[ "$RC" = 0 ] && ok "registered statusLine exits 0" || bad "registered statusLine exited $RC"
[ -n "$OUT" ] && ok "registered statusLine renders a non-empty line (no blank enter-box)" \
              || bad "registered statusLine rendered BLANK (the teammate bug)"

# ── 6) IDEMPOTENT: a second register is a no-op ('current'), settings byte-identical ──
BEFORE="$(cat "$SETTINGS")"
STATE2="$(env -i HOME="$HOMEDIR" PATH="/usr/bin:/bin:/usr/local/bin" \
  "$DST/bin/heimdall-statusline-register" register 2>/dev/null)"
AFTER="$(cat "$SETTINGS")"
[ "$STATE2" = current ] && ok "second register is idempotent (state=current)" \
                        || bad "second register not idempotent (state=$STATE2)"
[ "$BEFORE" = "$AFTER" ] && ok "settings.json unchanged on re-register" \
                         || bad "settings.json changed on idempotent re-register"

# ── 7) a user's OWN custom statusLine is NEVER clobbered ──
HOME2="$WORK/home-custom"; mkdir -p "$HOME2/.claude"
python3 - "$HOME2/.claude/settings.json" <<'PY'
import json,sys
json.dump({"statusLine":{"type":"command","command":"my-own-line"}}, open(sys.argv[1],"w"))
PY
STATE3="$(env -i HOME="$HOME2" PATH="/usr/bin:/bin:/usr/local/bin" \
  "$DST/bin/heimdall-statusline-register" register 2>/dev/null)"
KEPT="$(sl_cmd "$HOME2/.claude/settings.json" statusLine)"
[ "$KEPT" = "my-own-line" ] && ok "custom statusLine preserved (state=$STATE3)" \
                            || bad "custom statusLine clobbered (now: $KEPT, state=$STATE3)"

# ── 8) render-layer graceful degrade: statusline.sh itself, run directly under a fresh
#       HOME with NO per-user state and NO CLAUDE_PLUGIN_ROOT, still renders + exits 0. ──
mkdir -p "$WORK/home-bare"
ROUT="$(printf '{"workspace":{"current_dir":"%s"}}' "$DST" \
  | env -i HOME="$WORK/home-bare" PATH="/usr/bin:/bin:/usr/local/bin" TERM=dumb bash "$DST/hooks/statusline.sh" 2>/dev/null)"
RRC=$?
[ "$RRC" = 0 ] && ok "statusline.sh exits 0 with no state (graceful degrade)" \
              || bad "statusline.sh exited $RRC with no state"
[ -n "$ROUT" ] && ok "statusline.sh renders a line with no state" \
              || bad "statusline.sh rendered blank with no state"

# ── 9) BELT-AND-SUSPENDERS: the FIRST register (statusLine key absent → now written)
#       emits a ONE-TIME stderr activation note ("visible next session"); a second,
#       idempotent register must NOT re-emit it. The note is stderr-only so it never
#       pollutes the state-word contract on stdout. ──
HOMEDIR3="$WORK/home-note"; mkdir -p "$HOMEDIR3/.claude"
NERR1="$(env -i HOME="$HOMEDIR3" PATH="/usr/bin:/bin:/usr/local/bin" \
  "$DST/bin/heimdall-statusline-register" register 2>&1 >/dev/null)"
case "$NERR1" in *"statusline activated"*) ok "first register emits one-time stderr activation note" ;;
  *) bad "first register did NOT emit stderr activation note (got: '$NERR1')" ;; esac
# stdout must still be JUST the state word (note lives on stderr, not stdout)
NOUT1="$(env -i HOME="$WORK/home-note2" PATH="/usr/bin:/bin:/usr/local/bin" \
  "$DST/bin/heimdall-statusline-register" register 2>/dev/null)"
[ "$NOUT1" = registered ] && ok "stdout state word uncontaminated by the note (=registered)" \
                          || bad "stdout state word contaminated: '$NOUT1'"
NERR2="$(env -i HOME="$HOMEDIR3" PATH="/usr/bin:/bin:/usr/local/bin" \
  "$DST/bin/heimdall-statusline-register" register 2>&1 >/dev/null)"
case "$NERR2" in *"statusline activated"*) bad "second (idempotent) register wrongly re-emitted the note (got: '$NERR2')" ;;
  *) ok "second (idempotent) register emits NO note" ;; esac

# ── 10) the SessionStart hook runs the statusline register SYNCHRONOUSLY (not
#       backgrounded/detached). CC snapshots the settings.json statusLine key AT
#       session start; an async write lands AFTER the snapshot → teammate's FIRST
#       session shows a blank HUD. Synchronous register = key present before snapshot. ──
HJ="$REPO_ROOT/hooks/hooks.json"
jq . "$HJ" >/dev/null 2>&1 && ok "hooks.json is valid JSON" || bad "hooks.json is NOT valid JSON"
SS="$(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty' "$HJ" 2>/dev/null)"
case "$SS" in
  *'("$SLREG" register'*'&)'*) bad "SessionStart still backgrounds SLREG register (async write lands after CC snapshot → blank first session)" ;;
  *'"$SLREG" register'*)       ok "SessionStart runs SLREG register synchronously (no backgrounding &)" ;;
  *)                           bad "SessionStart no longer invokes SLREG register" ;;
esac

echo
if [ "$FAILS" = 0 ]; then echo "PASS — statusline portable + propagates to any teammate"; exit 0
else echo "FAIL — $FAILS assertion(s) failed"; exit 1; fi
