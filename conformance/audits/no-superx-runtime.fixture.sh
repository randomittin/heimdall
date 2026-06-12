#!/usr/bin/env bash
# PARITY-ROW: standing audit (plan P2.3) — "no live superx runtime refs"
#   Cross-cuts: Command `superx`->`heimdall` rename, Env `SUPERX_STATE_FILE`->`HEIMDALL_STATE_FILE`,
#   Statusline `[SUPERX]`->`[HEIMDALL]`, namespace `/superx:*`->`/hmd:*`.
# ASSERT: `grep -rn "superx" .` over the repo resolves ONLY to (a) git history /
#   CHANGELOG / PARITY / IDENTITY / docs/specs prose, and (b) documented
#   BACK-COMPAT fallbacks (reading a legacy superx-state.json / ~/.superx when
#   present). There must be NO superx ref that heimdall DEPENDS ON at runtime
#   for its own operation — i.e. no path where the only way heimdall works is
#   via a superx-named live artifact.
#
# FINDING (recorded as an assertion below): hooks/hooks.json embeds the literal
#   default `${CLAUDE_PLUGIN_ROOT:-/Users/rj/Downloads/superx}` in EVERY hook
#   command (10 occurrences). When CLAUDE_PLUGIN_ROOT is set (the real install
#   case) these are inert. When it is UNSET they resolve to a superx disk path
#   that no longer exists -> the bins silently no-op (`|| true`). This is a live
#   superx ref in the fallback DEFAULT position. We assert it is ONLY ever in
#   that `:-` default position (never the primary), and FLAG the count as a
#   finding for the orchestrator (it SHOULD be retargeted to a heimdall path).
ROW="audit:no-superx-runtime"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

cd "$PLUGIN_ROOT" || { bad "cannot cd plugin root"; finish; }

# --- run: collect every superx hit outside .git ---
HITS="$(grep -rn "superx" . --exclude-dir=.git 2>/dev/null || true)"

# 1. Bins that read legacy state MUST prefer heimdall-state.json and reference
#    superx-state.json only in a fallback branch. Structural check: in each file,
#    the first line mentioning *-state.json must mention heimdall (preferred),
#    and every superx-state.json line must sit under an `elif`/`-f superx` guard.
for f in bin/heimdall-state bin/conflict-log bin/summary-card; do
  FIRST="$(grep -nE '(heimdall|superx)-state\.json' "$f" | grep -vE '^[0-9]+:#' | head -1)"
  # The superx mention must be guarded: the line directly above each
  # `STATE...="...superx-state.json"` assignment is an `elif`/`if [ -f superx-state.json ]`.
  GUARDED=1
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    n="${ln%%:*}"
    prev="$(sed -n "$((n-1))p" "$f")"
    printf '%s' "$prev" | grep -qE '(elif|if).*(-f[[:space:]]+.*superx-state\.json|superx-state\.json")' || GUARDED=0
  done < <(grep -nE '^[^#]*=("?\$?\{?[^=]*)?[^#]*superx-state\.json' "$f" | grep -E '=')
  if printf '%s' "$FIRST" | grep -q heimdall && [ "$GUARDED" = 1 ]; then
    ok "$f prefers heimdall-state.json; superx-state.json only under a fallback guard"
  else
    bad "$f: heimdall not preferred-first ($FIRST) or a superx assignment is unguarded"
  fi
done

# 2. The PRIMARY default state file name is heimdall-state.json (not superx).
assert_grep 'heimdall-state\.json' "$(sed -n '1,40p' bin/heimdall-state)" "heimdall-state.json is primary default"

# 3. FINDING: hooks.json superx fallback-path occurrences. Assert they are ALL in
#    the `${CLAUDE_PLUGIN_ROOT:-...superx}` default position (never bare).
HOOK_SUPERX="$(grep -oE '\$\{CLAUDE_PLUGIN_ROOT:-/Users/rj/Downloads/superx\}' hooks/hooks.json | wc -l | tr -d ' ')"
BARE_SUPERX="$(grep -nE '/Users/rj/Downloads/superx' hooks/hooks.json | grep -vE 'CLAUDE_PLUGIN_ROOT:-' || true)"
if [ -z "$BARE_SUPERX" ]; then
  ok "hooks.json: all $HOOK_SUPERX superx path refs are in the CLAUDE_PLUGIN_ROOT fallback default position"
else
  bad "hooks.json has a BARE superx path (not a fallback default): $BARE_SUPERX"
fi
note "FINDING: hooks.json hardcodes /Users/rj/Downloads/superx as the CLAUDE_PLUGIN_ROOT fallback in $HOOK_SUPERX places — inert when CLAUDE_PLUGIN_ROOT is set, but a stale superx disk path otherwise. Recommend retargeting the default to a heimdall path."

# 4. No runtime invocation of a binary literally named `superx`/`superx-state`/`superx-ui`
#    OUTSIDE history/docs/back-compat/the conformance harness itself. We scan only
#    executable bins + hooks (the live runtime surface), excluding comment lines.
LIVE_BIN=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  HIT="$(grep -nE '(^|[^a-zA-Z0-9_-])(superx|superx-state|superx-ui)([[:space:]]|$|\")' "$f" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -viE 'legacy|back-compat|fallback|adopt|former|previously|rename' || true)"
  [ -n "$HIT" ] && LIVE_BIN="$LIVE_BIN
$f: $HIT"
done < <(find bin hooks -type f 2>/dev/null)
if [ -z "$(printf '%s' "$LIVE_BIN" | tr -d '[:space:]')" ]; then
  ok "no live invocation of a superx-named binary in bin/ or hooks/ (outside back-compat/comments)"
else
  bad "possible live superx-binary invocation:$LIVE_BIN"
fi

finish
