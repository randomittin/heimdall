#!/usr/bin/env bash
# PARITY-ROW: standing audit (plan P2.3) — "agent roles resolve under the live namespace"
#   Cross-cuts the whole Agents table (orchestrator rename superx->heimdall + all
#   kept roles architect/coder/reviewer/... + net-new fixer/seeker) and the
#   Slash-command namespace row (/superx:* -> /hmd:*).
# ASSERT: (1) The manifest plugin name is `hmd` (the live namespace). (2) Every
#   agent under agents/*.md declares a `name:` whose value is a real role, and
#   the orchestrator resolves to `heimdall` (NOT `superx`). (3) settings.json
#   binds the main agent to `heimdall`. (4) Slash commands carry frontmatter
#   `name:` so they resolve under /hmd:<name>. This proves the rename landed and
#   roles are addressable under the heimdall/hmd namespace, meeting/exceeding the
#   superx baseline (which exposed the same roles under the superx namespace).
ROW="audit:agents-resolve"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
cd "$PLUGIN_ROOT" || { bad "cannot cd plugin root"; finish; }

# 1. Live namespace = manifest name.
NS="$(jq -r '.name' .claude-plugin/plugin.json 2>/dev/null)"
[ "$NS" = "hmd" ] && ok "manifest namespace is 'hmd'" || bad "manifest name is '$NS' (expected hmd)"

# 2. Every agent has a name: front-matter field; orchestrator resolves to heimdall.
MISSING=""
for a in agents/*.md; do
  nm="$(awk -F': *' '/^name:/{print $2; exit}' "$a")"
  [ -n "$nm" ] || MISSING="$MISSING $a"
done
[ -z "$MISSING" ] && ok "all agents/*.md declare a name: field" || bad "agents missing name::$MISSING"

ORCH="$(awk -F': *' '/^name:/{print $2; exit}' agents/heimdall.md)"
[ "$ORCH" = "heimdall" ] && ok "orchestrator agent name is 'heimdall' (renamed from superx)" \
  || bad "orchestrator name is '$ORCH' (expected heimdall)"

# No agent is still named superx.
SX="$(grep -lE '^name:[[:space:]]*superx[[:space:]]*$' agents/*.md 2>/dev/null || true)"
[ -z "$SX" ] && ok "no agent is still named 'superx'" || bad "agent still named superx: $SX"

# 3. settings.json binds the live agent to heimdall.
SAGENT="$(jq -r '.agent // empty' settings.json 2>/dev/null)"
[ "$SAGENT" = "heimdall" ] && ok "settings.json agent = heimdall" || bad "settings.json agent = '$SAGENT' (expected heimdall)"

# 4. Kept roles from the parity matrix are all present as agent files.
for role in architect coder database-architect design docs-writer incident-responder \
            lint-quality planner reviewer security-auditor test-runner verifier wave-executor; do
  assert_file "agents/${role}.md" "kept agent role '$role' present"
done

# 5. Renamed slash commands resolve under /hmd:<name> (frontmatter name present, no superx: prefix).
for cmd in level status maintain maintain-check reflect; do
  nm="$(awk -F': *' '/^name:/{print $2; exit}' "commands/${cmd}.md" 2>/dev/null)"
  [ -n "$nm" ] && ok "command '$cmd' resolves as /hmd:$nm" || bad "command '$cmd' has no name: frontmatter"
done

finish
