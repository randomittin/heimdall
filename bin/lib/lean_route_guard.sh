#!/usr/bin/env bash
# bin/lib/lean_route_guard.sh -- may a reset touch what this session's route depends on? (lean-core plan T2.6, INV-L11)
#
#   bash bin/lib/lean_route_guard.sh check
#
# WHY. `install.sh --reset` switches an existing install to the lean profile and turns Headroom off for the next session. Headroom is a local
# proxy a session may be using at this very moment: a launcher such as `claude() { hmd route claude "$@"; }` starts Claude Code with
# ANTHROPIC_BASE_URL=http://127.0.0.1:8787, and the session keeps that route until it ends. A reset that stopped the proxy, or edited what the
# route reads, would fail every request of that session (INV-L11). So the reset asks this guard first and acts on the answer.
#
# `check` prints ONE line on stdout, `<verdict>: <reason>`, and exits with the verdict:
#   ok      0   this session is not routed through Headroom: every step of the reset may run
#   defer   10  it is (a route to a loopback host on Headroom's port): leave Headroom's off switch and the files this route reads for the next
#               session, record each step left undone as pending, never skip one silently. The guard edits nothing and stops nothing
#   refuse  11  it cannot tell (state it cannot read, a route value that is not a host and port, a library it cannot load): fail closed,
#               change nothing
#   a usage error exits 2 with a usage line on stderr and nothing on stdout.
# A caller proceeds only on exactly `ok` with exit 0. Under `set -e`: out="$(bash lean_route_guard.sh check)" && rc=0 || rc=$?
#
# WHAT IT READS. Only reads: no socket is opened, no file written, no process signalled.
#   * the routing variables of the environment it runs in, from the list bin/lib/hmd-gate-endpoint.sh keeps for the judgment scrub, so the two
#     cannot disagree about what routes a session: ANTHROPIC_BASE_URL and its siblings, HTTP_PROXY / HTTPS_PROXY / ALL_PROXY in both cases,
#     HEADROOM_BASE_URL, HEADROOM_PROXY, HEADROOM_PROXY_URL; and any other HEADROOM_* variable whose value is a URL. NO_PROXY is an allowlist
#     that can only remove a hop; HEADROOM_PORT, HEADROOM_BIND and HEADROOM_LOSSLESS configure the proxy. None of them is a route.
#   * Headroom's port, as `hmd headroom` and the wrap chain read it (hmd_headroom_port of bin/lib/hmd-headroom-chain.sh): HEADROOM_PORT, else 8787.
#   * Headroom's state, where `hmd headroom` keeps it (that library's _hmd_headroom_state): <state>/headroom/receipt.json (the module is added)
#     and <state>/.modstate/headroom/optout.json (opted out), <state> = $HMD_MODULES_STATE or <plugin>/.heimdall/modules. Absent is a state and
#     the reason names it; a path that exists and cannot be read as a file is not a state, and refuses.
#
# HOW A ROUTE IS JUDGED. Its host is read the way the gate library reads it (scheme, userinfo and path stripped: `http://127.0.0.1:pw@corp:3128` is
# the corporate proxy it is). A loopback host (localhost, 127.*, ::1, 0.0.0.0) on Headroom's port is a route to Headroom: defer. A loopback host on
# another port is some other local proxy (OmniRoute, a VPN client): the reset does not touch it, so it is named in the reason and left alone. An
# off-box host is a gateway or a tunnel the reset cannot turn off. A value that is not a host and port refuses. Only the host and the port are
# ever printed: a proxy URL may carry credentials. Known limits: a name that resolves to loopback through DNS or /etc/hosts is not seen, and a
# route that lives only in another process's environment, or in a settings file Claude Code applied at launch, is outside this process's
# environment (`hmd headroom off --next-session` never stops the proxy, which keeps those sessions working).
#
# Bash 3.2 compatible. Proof: test/lean-route-guard.test.sh.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/../.." && pwd)"

# say VERDICT REASON EXIT -- the one line of output, then the verdict's exit status
say() { printf '%s: %s\n' "$1" "$2"; exit "$3"; }

# _lrg_file_state PATH -- readable | absent | unreadable. Absent is ENOENT and nothing else: a path that exists but cannot be read as a regular
# file (no permission, a directory, a dangling link), or whose parent cannot be entered, is unreadable, never absent, because reading it as
# absent would let the guard say ok about a state it never saw.
_lrg_file_state() {
  local p="$1" err
  if [ -f "$p" ]; then
    if { : < "$p"; } 2>/dev/null; then echo readable; else echo unreadable; fi
    return 0
  fi
  err="$(LC_ALL=C ls -d -- "$p" 2>&1 >/dev/null)"
  case "$err" in
    *"No such file or directory"*) echo absent ;;
    *) echo unreadable ;;
  esac
}

# _lrg_tcp_port VALUE -- VALUE as a TCP port number without leading zeros (`08787` is port 8787 to every URL parser); 1 when it is not one.
_lrg_tcp_port() {
  local p="$1"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  p="${p#"${p%%[!0]*}"}"
  case "$p" in ''|??????*) return 1 ;; esac
  [ "$p" -le 65535 ] || return 1
  printf '%s' "$p"
}

# _lrg_parse VALUE -- sets LRG_VALUE (trimmed), LRG_HOST (lower case, no brackets) and LRG_PORT (the explicit one, else the scheme's default) for a
# route value; 1 when it names no usable host or port.
_lrg_parse() {
  local v="$1" scheme="" rest
  LRG_VALUE=""; LRG_HOST=""; LRG_PORT=""
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  LRG_VALUE="$v"
  case "$v" in *://*) scheme="${v%%://*}" ;; esac
  LRG_HOST="$(_hmd_routing_host "$v")"
  case "$LRG_HOST" in ''|*[!A-Za-z0-9.:_-]*) return 1 ;; esac
  rest="${v#*://}"; rest="${rest##*@}"; rest="${rest%%[/?#]*}"
  case "$rest" in
    \[*\]:*) LRG_PORT="${rest##*]:}" ;;
    \[*\])   LRG_PORT="" ;;
    *:*:*)   LRG_PORT="" ;;
    *:*)     LRG_PORT="${rest##*:}" ;;
    *)       LRG_PORT="" ;;
  esac
  if [ -z "$LRG_PORT" ]; then
    case "$scheme" in https) LRG_PORT=443 ;; *) LRG_PORT=80 ;; esac
  fi
  LRG_PORT="$(_lrg_tcp_port "$LRG_PORT")" || return 1
}

if [ "$#" -ne 1 ] || [ "$1" != check ]; then echo "usage: lean_route_guard.sh check" >&2; exit 2; fi

# The two libraries are read, never copied: what routes a session, what is loopback, and where Headroom keeps its port and its state each have
# one definition. A library that is gone, or no longer defines what is read from it, refuses: an empty routing list would read as "no route".
for lib in hmd-gate-endpoint.sh hmd-headroom-chain.sh; do
  [ -r "$LIB_DIR/$lib" ] || say refuse "$LIB_DIR/$lib is missing or unreadable: the guard cannot tell where this session's route leads" 11
  # shellcheck source=/dev/null
  . "$LIB_DIR/$lib" >/dev/null 2>&1 || true
done
for fn in _hmd_routing_host _hmd_is_local_rewriter hmd_headroom_port _hmd_headroom_state; do
  type "$fn" >/dev/null 2>&1 || say refuse "$fn is not defined by hmd-gate-endpoint.sh or hmd-headroom-chain.sh in $LIB_DIR: the guard cannot tell where this session's route leads" 11
done
[ -n "${_HMD_GATE_ROUTING_VARS:-}" ] || say refuse "hmd-gate-endpoint.sh in $LIB_DIR lists no routing variable: the guard cannot tell where this session's route leads" 11

STATE_DIR="$(_hmd_headroom_state "$PLUGIN_DIR")"
receipt="$STATE_DIR/headroom/receipt.json"
optout="$STATE_DIR/.modstate/headroom/optout.json"
r="$(_lrg_file_state "$receipt")"
o="$(_lrg_file_state "$optout")"
[ "$r" != unreadable ] || say refuse "Headroom's module record $receipt exists but cannot be read as a file: the guard cannot tell whether a route to Headroom is live (fail closed)" 11
[ "$o" != unreadable ] || say refuse "Headroom's opt-out record $optout exists but cannot be read as a file: the guard cannot tell whether a route to Headroom is live (fail closed)" 11
module="not added"; [ "$r" = readable ] && module="added"
[ "$o" = readable ] && module="$module, opted out"

hp="$(_lrg_tcp_port "$(hmd_headroom_port)")" || hp=8787

seen=" "; headroom_routes=""; other_local=""
for var in $_HMD_GATE_ROUTING_VARS $(compgen -e -- HEADROOM_); do
  case "$var" in NO_PROXY|no_proxy) continue ;; esac
  case "$seen" in *" $var "*) continue ;; esac
  seen="$seen$var "
  val="${!var:-}"
  [ -n "$val" ] || continue
  case "$var" in
    HEADROOM_BASE_URL|HEADROOM_PROXY|HEADROOM_PROXY_URL) ;;
    HEADROOM_*) case "$val" in *://*) ;; *) continue ;; esac ;;
  esac
  if ! _lrg_parse "$val"; then
    say refuse "$var holds a value that is not a host and port the guard can read: it cannot tell where this session's route leads (fail closed)" 11
  fi
  _hmd_is_local_rewriter "$LRG_VALUE" || continue
  hostport="$LRG_HOST"; case "$hostport" in *:*) hostport="[$hostport]" ;; esac
  hostport="$hostport:$LRG_PORT"
  if [ "$LRG_PORT" = "$hp" ]; then headroom_routes="${headroom_routes:+$headroom_routes, }$var=$hostport"
  else other_local="${other_local:+$other_local, }$var=$hostport"; fi
done

if [ -n "$headroom_routes" ]; then
  say defer "this session is routed through Headroom (port $hp) by $headroom_routes: leave Headroom and everything this route reads for the next session, and stop nothing (module state: $module)" 10
fi
note=""
[ -z "$other_local" ] || note="; left alone, local proxies that are not Headroom's: $other_local"
say ok "this session is not routed through Headroom (port $hp; module state: $module)$note" 0
