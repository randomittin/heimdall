#!/usr/bin/env bash
# test/heimdall-ledger-mcp-path.test.sh — regression guard for issue #2.
#
# Bug (#2): the heimdall-ledger MCP server was registered in .mcp.json with a
# cwd-RELATIVE command path ("bin/heimdall-ledger-mcp"). Claude Code launches
# plugin MCP servers with cwd = the user's PROJECT dir, not the plugin root, so
# the relative path resolved to "<project>/bin/heimdall-ledger-mcp" — which does
# not exist — and the server died before the handshake (JSON-RPC -32000):
#     python3: can't open file '<project>/bin/...': [Errno 2] No such file...
#
# Fix: register the server via the plugin-root variable Claude Code expands for
# plugin MCP servers — "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-ledger-mcp" — so the
# path resolves ABSOLUTELY, independent of which project opened the session.
#
# This test is FALSIFIABLE against the fix:
#   (a) .mcp.json's command path is plugin-root / absolute, NOT bare-relative;
#   (b) expanding ${CLAUDE_PLUGIN_ROOT} yields an absolute, executable file;
#   (c) launched from a DIFFERENT cwd (/tmp) via the resolved path, the server
#       returns a clean MCP `initialize` handshake (serverInfo + protocolVersion),
#       never -32000 / "No such file";
#   (d) the SAME launch from /tmp via the OLD bare-relative arg FAILS with
#       "No such file or directory" — proving the bug recurs if reverted;
#   (e) PROTOCOL.md's .mcp.json registration snippet no longer teaches the
#       bare-relative command that reintroduces the bug.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MCP_JSON="$ROOT/.mcp.json"
SERVER_REL="bin/heimdall-ledger-mcp"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -f "$MCP_JSON" ] || { echo "FATAL: $MCP_JSON missing" >&2; exit 2; }

# jq . must succeed — the config is always valid JSON.
jq -e . "$MCP_JSON" >/dev/null 2>&1 || { echo "FATAL: $MCP_JSON is not valid JSON" >&2; exit 2; }

# The single command token Claude Code will exec: prefer args[0] when the command
# is an interpreter (python3), else the bare "command". This mirrors how the host
# resolves the server script path.
COMMAND="$(jq -r '.mcpServers["heimdall-ledger"].command // empty' "$MCP_JSON")"
ARG0="$(jq -r '.mcpServers["heimdall-ledger"].args[0] // empty' "$MCP_JSON")"
case "$COMMAND" in
  python3|python|*/python3|*/python) SCRIPT_TOKEN="$ARG0" ;;
  *)                                 SCRIPT_TOKEN="$COMMAND" ;;
esac

# Mimic Claude Code's .mcp.json variable expansion: ${VAR} and ${VAR:-default},
# resolved against the process env (CLAUDE_PLUGIN_ROOT = the plugin install dir).
expand() {
  CLAUDE_PLUGIN_ROOT="$ROOT" python3 - "$1" <<'PY'
import os, re, sys
raw = sys.argv[1]
def sub(m):
    var, default = m.group(1), m.group(3)
    val = os.environ.get(var)
    return val if val not in (None, "") else (default if default is not None else "")
print(re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}", sub, raw))
PY
}

# ── (a) the registered script path is plugin-root / absolute, not bare-relative ──
if [ -z "$SCRIPT_TOKEN" ]; then
  bad "(a) no server script path found in $MCP_JSON"
elif printf '%s' "$SCRIPT_TOKEN" | grep -Eq '^\$\{CLAUDE_PLUGIN_ROOT[:}]|^/'; then
  ok "(a) .mcp.json server path is plugin-root/absolute: $SCRIPT_TOKEN"
else
  bad "(a) .mcp.json server path is cwd-relative (bug #2 shape): $SCRIPT_TOKEN"
fi

# ── (b) expansion yields an absolute, existing, executable file ──────────────────
ABS="$(expand "$SCRIPT_TOKEN")"
if [ "${ABS#/}" != "$ABS" ] && [ -f "$ABS" ] && [ -x "$ABS" ]; then
  ok "(b) \${CLAUDE_PLUGIN_ROOT} expands to an executable absolute path: $ABS"
else
  bad "(b) expansion is not an executable absolute file: '$ABS'"
fi

# The MCP initialize request the host sends first.
REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"path-test","version":"0"}}}'

# ── (c) launched from a DIFFERENT cwd via the resolved path → clean handshake ────
OUT_DIR="$(mktemp -d)"; trap 'rm -rf "$OUT_DIR"' EXIT
ABS_RESP="$(cd /tmp && printf '%s\n' "$REQ" | python3 "$ABS" 2>"$OUT_DIR/abs.err" || true)"
if printf '%s' "$ABS_RESP" | jq -e \
     'select(.result.serverInfo.name=="heimdall-ledger-mcp" and (.result.protocolVersion|length>0))' \
     >/dev/null 2>&1 \
   && ! printf '%s' "$ABS_RESP" | grep -q -- '-32000' \
   && ! grep -q 'No such file' "$OUT_DIR/abs.err"; then
  ok "(c) absolute path launched from /tmp returns a clean MCP initialize handshake"
else
  bad "(c) handshake from /tmp failed: resp='$ABS_RESP' err='$(cat "$OUT_DIR/abs.err")'"
fi

# ── (d) FALSIFIER: the OLD bare-relative arg from /tmp must FAIL (bug recurs) ─────
REL_ERR="$(cd /tmp && printf '%s\n' "$REQ" | python3 "$SERVER_REL" 2>&1 >/dev/null || true)"
if printf '%s' "$REL_ERR" | grep -q 'No such file or directory'; then
  ok "(d) bare-relative '$SERVER_REL' from /tmp fails 'No such file' — bug recurs if reverted"
else
  bad "(d) expected the relative path to fail from /tmp, but it did not: '$REL_ERR'"
fi

# ── (e) docs no longer teach the bare-relative registration that reintroduces #2 ─
DOC="$ROOT/PROTOCOL.md"
if [ -f "$DOC" ] && grep -Eq '"command"[[:space:]]*:[[:space:]]*"bin/heimdall-ledger-mcp"' "$DOC"; then
  bad "(e) PROTOCOL.md still shows a cwd-relative \"command\":\"bin/heimdall-ledger-mcp\" registration"
else
  ok "(e) PROTOCOL.md registration snippet does not teach the bug-shaped relative command"
fi

echo
echo "  heimdall-ledger-mcp path tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
