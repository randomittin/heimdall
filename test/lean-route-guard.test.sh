#!/usr/bin/env bash
#
# lean-route-guard.test.sh -- the route guard behind `install.sh --reset` (lean-core plan T2.6,
# docs/superpowers/plans/2026-11-12-3x-lean-core.md; invariant INV-L11 in .planning/lean-core/INVARIANTS.md).
#
# bin/lib/lean_route_guard.sh answers one question before a reset changes anything: is THIS session routed through Headroom, the proxy a
# reset turns off? `check` prints `<verdict>: <reason>` and exits 0 (ok), 10 (defer) or 11 (refuse). On the operator's machine `claude` is a
# shell function that starts Claude Code with ANTHROPIC_BASE_URL=http://127.0.0.1:8787, so the live session carries that route in its
# environment and keeps it until it ends: the guard must see it, and must never fail open. The proofs:
#   A. no proxy => ok: nothing routes the session; an off-box gateway or tunnel is not Headroom's; another local proxy is named and left alone
#   B. a base URL (or any routing variable) on the loopback port Headroom listens on => defer, however loopback is spelled and whatever the
#      module's state, a credential is never echoed, and the live proxy is still there afterwards
#   C. unreadable state => refuse (fail closed): a state file that exists but cannot be read, the default state path, a route value that is
#      not a host and port, a missing or drifted library; a refusal beats a defer
#   D. read-only; usage errors exit 2 with nothing on stdout; the verdicts hold under bash 3.2
#   X. falsifiers: a mutant of a COPY of the guard (or of a library it reads) for each claim; each must change the verdict that claim guards
#
# Hermetic: the guard and the libraries it reads run from a COPY of the tree under a throwaway dir (so the default state path is under this
# test's control), the environment is cleared (env -i), HOME is a throwaway dir, the only listener is a socket this test opens on a free
# loopback port, and nothing outside $WORK is touched. bash 3.2 compatible.
#
# Usage: test/lean-route-guard.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required (it opens the stand-in proxy socket)"; exit 2; }
for f in lean_route_guard.sh hmd-gate-endpoint.sh hmd-headroom-chain.sh real-home.sh; do
  [ -f "$REPO/bin/lib/$f" ] || { echo "FATAL: $REPO/bin/lib/$f missing"; exit 1; }
done

WORK="$(cd "$(mktemp -d)" && pwd)"
STUB_PID=""
cleanup() { [ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null; chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# mk_plugin DIR -- a copy of the guard and the libraries it reads, laid out as bin/lib under DIR (the guard finds its plugin root from there)
mk_plugin() {
  local f
  mkdir -p "$1/bin/lib"
  for f in lean_route_guard.sh hmd-gate-endpoint.sh hmd-headroom-chain.sh real-home.sh; do cp "$REPO/bin/lib/$f" "$1/bin/lib/$f"; done
}
PLUGIN="$WORK/plugin"; mk_plugin "$PLUGIN"
GUARD="$PLUGIN/bin/lib/lean_route_guard.sh"
GBASH=bash
HOME_T="$WORK/home"; MS="$WORK/modstate"; mkdir -p "$HOME_T"
STATE_ARG="HMD_MODULES_STATE=$MS"      # the module state root of the next call; empty = leave it to the default (<plugin>/.heimdall/modules)

# The stand-in for the Headroom proxy: a socket on a free loopback port that accepts and closes. It prints its port once it listens.
cat > "$WORK/stand-in-proxy.py" <<'EOPY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(16)
print(s.getsockname()[1], flush=True)
while True:
    s.accept()[0].close()
EOPY
mkfifo "$WORK/port.fifo"
python3 -I "$WORK/stand-in-proxy.py" > "$WORK/port.fifo" &
STUB_PID=$!
disown "$STUB_PID"      # bash would print a "Terminated" line when cleanup kills it; the job is ours to stop, not to report
read -r P < "$WORK/port.fifo"
case "$P" in ''|*[!0-9]*) echo "FATAL: the stand-in proxy did not report a port"; exit 2 ;; esac
stub_alive() { kill -0 "$STUB_PID" 2>/dev/null && ( exec 3<>"/dev/tcp/127.0.0.1/$P" ) 2>/dev/null; }

# g [VAR=value ...] -- run `check` in a cleared environment (only PATH, HOME and the state root get in); sets OUT, ERR and RC
g() {
  local a=(PATH="$PATH" HOME="$HOME_T")
  [ -z "$STATE_ARG" ] || a+=("$STATE_ARG")
  while [ "$#" -gt 0 ]; do a+=("$1"); shift; done
  OUT="$(env -i "${a[@]}" "$GBASH" "$GUARD" check 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
# expect LABEL VERDICT RC [NEEDLE ...] -- the last call printed ONE line `VERDICT: reason`, exited RC, said nothing on stderr, and the line holds every NEEDLE
expect() {
  local label="$1" want="$2" rc="$3" n; shift 3
  case "$OUT" in *$'\n'*) bad "$label (not one line: [$OUT])"; return ;; esac
  if [ "${OUT%%: *}" != "$want" ] || [ "$RC" -ne "$rc" ] || [ -n "$ERR" ]; then
    bad "$label (want $want/$rc, got out=[$OUT] rc=$RC err=[$ERR])"; return
  fi
  for n in "$@"; do
    case "$OUT" in *"$n"*) ;; *) bad "$label (the line lacks [$n]: [$OUT])"; return ;; esac
  done
  ok "$label"
}
lacks() { case "$OUT" in *"$2"*) bad "$1 (the line holds [$2]: [$OUT])" ;; *) ok "$1" ;; esac; }

# state_fx none|receipt|optout|both -- a fresh module state root: the module added (receipt.json), opted out (optout.json), both or neither
state_fx() {
  chmod -R u+rwx "$MS" 2>/dev/null; rm -rf "$MS"
  mkdir -p "$MS/headroom" "$MS/.modstate/headroom"
  case "$1" in receipt|both) : > "$MS/headroom/receipt.json" ;; esac
  case "$1" in optout|both) : > "$MS/.modstate/headroom/optout.json" ;; esac
}

# ╔═ A. no proxy => ok ═══════════════════════════════════════════════════════════════════╗
echo "A. no proxy => ok"
g
expect "A: nothing in the environment, no Headroom state anywhere" ok 0 "not routed through Headroom" "port 8787" "module state: not added"
state_fx receipt; g
expect "A: the module is added (a readable receipt)" ok 0 "module state: added)"
state_fx both; g
expect "A: added and opted out" ok 0 "module state: added, opted out"
state_fx optout; g
expect "A: opted out without the module" ok 0 "module state: not added, opted out"
STATE_ARG=""; g
expect "A: no HMD_MODULES_STATE, and <plugin>/.heimdall/modules absent: the default path is absent, not an error" ok 0 "module state: not added"
STATE_ARG="HMD_MODULES_STATE=$MS"
state_fx none
g HEADROOM_PORT=8787 HEADROOM_LOSSLESS=1 NO_PROXY=127.0.0.1,localhost no_proxy=localhost
expect "A: HEADROOM_PORT, HEADROOM_LOSSLESS and NO_PROXY alone route nothing (a port, a flag, an allowlist)" ok 0 "not routed through Headroom"
g HEADROOM_PORT="$P" HEADROOM_BIND="127.0.0.1:$P"
expect "A: another HEADROOM_* variable counts only when its value is a URL (HEADROOM_BIND is where the proxy listens, not a route)" ok 0 "not routed through Headroom"
g ANTHROPIC_BASE_URL=https://api.anthropic.com
expect "A: the provider itself is no proxy" ok 0 "not routed through Headroom"
g HTTPS_PROXY=http://proxy.corp.example:3128 ALL_PROXY=socks5://gw.corp.example:1080 HEADROOM_BASE_URL=https://headroom.corp.example:8787 https_proxy=http://127.0.0.1:pw@proxy.corp.example:8787
expect "A: off-box gateways and tunnels are not Headroom's, whatever port or userinfo they carry" ok 0 "not routed through Headroom"
g HTTPS_PROXY=http://127.0.0.1:7890 ANTHROPIC_BASE_URL=http://localhost:20128
expect "A: a local proxy on another port (a VPN client, OmniRoute) is ok: named, and left alone" ok 0 "HTTPS_PROXY=127.0.0.1:7890" "ANTHROPIC_BASE_URL=localhost:20128" "left alone"
g HEADROOM_PORT="$P" ANTHROPIC_BASE_URL=http://127.0.0.1:8787
expect "A: Headroom moved to another port: the old default port is another proxy's" ok 0 "ANTHROPIC_BASE_URL=127.0.0.1:8787" "left alone"

# ╔═ B. a route on the loopback port Headroom listens on => defer ═════════════════════════╗
echo "B. a route on the loopback port Headroom listens on => defer"
g HEADROOM_PORT="$P" ANTHROPIC_BASE_URL="http://127.0.0.1:$P"
expect "B: ANTHROPIC_BASE_URL on the port Headroom listens on" defer 10 "routed through Headroom (port $P)" "by ANTHROPIC_BASE_URL=127.0.0.1:$P" "next session"
if stub_alive; then ok "B: the proxy is still listening afterwards (the guard stops nothing)"; else bad "B: the stand-in proxy is gone or no longer accepts connections"; fi
g ANTHROPIC_BASE_URL=http://127.0.0.1:8787
expect "B: the default port, the operator's machine (claude() -> hmd route claude -> 127.0.0.1:8787)" defer 10 "routed through Headroom (port 8787)" "by ANTHROPIC_BASE_URL=127.0.0.1:8787"
for url in "http://localhost:$P" "http://LOCALHOST:$P/v1" "http://[::1]:$P" "http://0.0.0.0:$P" "http://127.0.0.2:$P" "127.0.0.1:$P" "http://127.0.0.1:0$P" "  http://127.0.0.1:$P  " "http://127.0.0.1:$P?x=1"; do
  g HEADROOM_PORT="$P" ANTHROPIC_BASE_URL="$url"
  expect "B: loopback spelled [$url]" defer 10 "routed through Headroom (port $P)"
done
g HEADROOM_PORT="$P" ANTHROPIC_BASE_URL="http://user:s3cret@127.0.0.1:$P"
expect "B: a base URL with credentials" defer 10 "by ANTHROPIC_BASE_URL=127.0.0.1:$P"
lacks "B: ... and the credentials are never echoed (host and port only)" "s3cret"
for var in ANTHROPIC_BASE_URL ANTHROPIC_API_URL ANTHROPIC_DEFAULT_BASE_URL CLAUDE_CODE_BASE_URL HTTP_PROXY HTTPS_PROXY ALL_PROXY \
           http_proxy https_proxy all_proxy HEADROOM_BASE_URL HEADROOM_PROXY HEADROOM_PROXY_URL HEADROOM_URL; do
  g HEADROOM_PORT="$P" "$var=http://127.0.0.1:$P"
  expect "B: $var" defer 10 "by $var=127.0.0.1:$P"
done
g HEADROOM_PORT="$P" HEADROOM_PROXY="127.0.0.1:$P"
expect "B: HEADROOM_PROXY in the bare host:port form" defer 10 "by HEADROOM_PROXY=127.0.0.1:$P"
g HEADROOM_PORT="$P" ANTHROPIC_BASE_URL="http://127.0.0.1:$P" HTTPS_PROXY="http://localhost:$P" HTTP_PROXY=http://proxy.corp.example:3128
expect "B: every route to Headroom is named; an off-box one beside them changes nothing" defer 10 "ANTHROPIC_BASE_URL=127.0.0.1:$P" "HTTPS_PROXY=localhost:$P"
for st in none receipt optout both; do
  state_fx "$st"; g HEADROOM_PORT="$P" ANTHROPIC_BASE_URL="http://127.0.0.1:$P"
  expect "B: module state [$st] does not change the defer" defer 10 "routed through Headroom (port $P)"
done

# ╔═ C. unreadable state => refuse, fail closed ═══════════════════════════════════════════╗
echo "C. unreadable state => refuse, fail closed"
state_fx none; mkdir "$MS/headroom/receipt.json"
g
expect "C: the module record is a directory, no route in sight" refuse 11 "$MS/headroom/receipt.json" "cannot be read"
g HEADROOM_PORT="$P" ANTHROPIC_BASE_URL="http://127.0.0.1:$P"
expect "C: ... and with a route to Headroom the refusal beats the defer" refuse 11 "$MS/headroom/receipt.json"
state_fx none; mkdir "$MS/.modstate/headroom/optout.json"
g
expect "C: the opt-out record is a directory" refuse 11 "$MS/.modstate/headroom/optout.json" "cannot be read"
state_fx none; ln -s "$WORK/nowhere" "$MS/headroom/receipt.json"
g
expect "C: the module record is a dangling link" refuse 11 "$MS/headroom/receipt.json"
: > "$WORK/state-is-a-file"; STATE_ARG="HMD_MODULES_STATE=$WORK/state-is-a-file"
g
expect "C: the state root is a regular file (nothing under it can be read)" refuse 11 "$WORK/state-is-a-file/headroom/receipt.json"
STATE_ARG="HMD_MODULES_STATE=$MS"
if [ "$(id -u)" -ne 0 ]; then
  state_fx receipt; chmod 000 "$MS/headroom/receipt.json"
  g
  expect "C: a receipt without read permission" refuse 11 "$MS/headroom/receipt.json"
  chmod 600 "$MS/headroom/receipt.json"; chmod 000 "$MS/headroom"
  g
  expect "C: a module directory that cannot be entered" refuse 11 "$MS/headroom/receipt.json"
  chmod 755 "$MS/headroom"
else
  echo "  SKIP C: the permission cases (running as root: chmod does not stop root)"
fi
STATE_ARG=""; mkdir -p "$PLUGIN/.heimdall/modules/headroom/receipt.json"
g
expect "C: the DEFAULT state path (<plugin>/.heimdall/modules, where hmd headroom looks) is read too" refuse 11 "$PLUGIN/.heimdall/modules/headroom/receipt.json"
rm -rf "$PLUGIN/.heimdall"; STATE_ARG="HMD_MODULES_STATE=$MS"
state_fx none
for assign in "ANTHROPIC_BASE_URL=http://" "HTTPS_PROXY=http://127.0.0.1:notaport" "ALL_PROXY=unix:///var/run/proxy.sock" \
              "HEADROOM_PROXY_URL=http://[::1" "HTTP_PROXY=http://127.0.0.1:0" "http_proxy=http://127.0.0.1:99999"; do
  g "$assign"
  expect "C: [$assign] is not a host and port" refuse 11 "${assign%%=*} holds a value" "cannot tell"
done
BARE="$WORK/bare"; mkdir -p "$BARE/bin/lib"; cp "$REPO/bin/lib/lean_route_guard.sh" "$BARE/bin/lib/"
GUARD_REAL="$GUARD"; GUARD="$BARE/bin/lib/lean_route_guard.sh"
g
expect "C: a library that is missing" refuse 11 "hmd-gate-endpoint.sh" "missing"
: > "$BARE/bin/lib/hmd-gate-endpoint.sh"; cp "$REPO/bin/lib/hmd-headroom-chain.sh" "$BARE/bin/lib/"
g
expect "C: a library that no longer defines what the guard reads" refuse 11 "is not defined"
GUARD="$GUARD_REAL"

# ╔═ D. read-only, usage, bash 3.2 ═══════════════════════════════════════════════════════╗
echo "D. read-only, usage errors, bash 3.2"
sig() { (cd "$WORK" && { find plugin home modstate -print | LC_ALL=C sort; find plugin home modstate -type f -exec cksum {} + | LC_ALL=C sort; }) | cksum; }
state_fx both
before="$(sig)"
g; g HEADROOM_PORT="$P" ANTHROPIC_BASE_URL="http://127.0.0.1:$P"; g ANTHROPIC_BASE_URL=http://
after="$(sig)"
if [ "$before" = "$after" ]; then ok "D: ok, defer and refuse leave every file under the plugin, HOME and the state root as they were"; else bad "D: a check changed something on disk"; fi
for args in "" "frob" "check extra" "--help"; do
  # shellcheck disable=SC2086  # the word list is the point
  OUT="$(env -i PATH="$PATH" HOME="$HOME_T" bash "$GUARD" $args 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
  if [ "$RC" -eq 2 ] && [ -z "$OUT" ] && case "$ERR" in usage:*) true ;; *) false ;; esac; then ok "D: usage error [$args] exits 2, nothing on stdout, usage on stderr"
  else bad "D: [$args] rc=$RC out=[$OUT] err=[$ERR]"; fi
done
if [ -x /bin/bash ]; then
  GBASH=/bin/bash; bv="$(/bin/bash -c 'echo "${BASH_VERSION%%(*}"')"
  state_fx none; g
  expect "D: under /bin/bash $bv, no proxy" ok 0 "not routed through Headroom"
  g HEADROOM_PORT="$P" ANTHROPIC_BASE_URL="http://[::1]:0$P" HTTPS_PROXY="http://user:pw@LOCALHOST:$P"
  expect "D: under /bin/bash $bv, a route to Headroom" defer 10 "ANTHROPIC_BASE_URL=[::1]:$P" "HTTPS_PROXY=localhost:$P"
  mkdir "$MS/headroom/receipt.json"; g
  expect "D: under /bin/bash $bv, unreadable state" refuse 11 "cannot be read"
  GBASH=bash
fi

# ╔═ X. falsifiers ═══════════════════════════════════════════════════════════════════════╗
# mutant NAME FILE SED_EXPR [VAR=value ...] -- copy the tree, apply SED_EXPR to FILE, require that the edit changed the file and that the
# mutant's verdict differs from the real guard's on the same environment and state: a claim nothing here would notice losing is no claim
echo "X. falsifiers: each mutant must change the verdict its claim guards"
MUT=0
mutant() {
  local name="$1" file="$2" expr="$3" gold dir keep
  shift 3
  g "$@"; gold="${OUT%%: *}"
  MUT=$((MUT + 1)); dir="$WORK/mut-$MUT"; mk_plugin "$dir"
  sed -e "$expr" "$dir/bin/lib/$file" > "$dir/bin/lib/$file.new" && mv "$dir/bin/lib/$file.new" "$dir/bin/lib/$file"
  if cmp -s "$dir/bin/lib/$file" "$REPO/bin/lib/$file"; then bad "X: $name (the edit changed nothing: its pattern no longer matches $file)"; return; fi
  keep="$GUARD"; GUARD="$dir/bin/lib/lean_route_guard.sh"; g "$@"; GUARD="$keep"
  if [ "${OUT%%: *}" != "$gold" ]; then ok "X: $name -> the verdict changes ($gold -> ${OUT%%: *})"
  else bad "X: $name -> still $gold: nothing in this suite notices"; fi
}
state_fx none
mutant "ok while a proxy is live" lean_route_guard.sh 's/^  say defer /  say ok /' \
  HEADROOM_PORT="$P" ANTHROPIC_BASE_URL="http://127.0.0.1:$P"
mutant "only ANTHROPIC_BASE_URL is read" lean_route_guard.sh 's/^for var in .*; do$/for var in ANTHROPIC_BASE_URL; do/' \
  HEADROOM_PORT="$P" HTTPS_PROXY="http://127.0.0.1:$P"
mutant "every local port is Headroom's" lean_route_guard.sh 's/^  if \[ "\$LRG_PORT" = "\$hp" ]; then/  if true; then/' \
  HTTPS_PROXY=http://127.0.0.1:7890
mutant "a route value that is no host and port is skipped" lean_route_guard.sh 's/^    say refuse "\$var holds/    continue # "$var holds/' \
  ANTHROPIC_BASE_URL=http://
mutant "the loopback test of the gate library stops matching" hmd-gate-endpoint.sh 's/127\.\*|0\.0\.0\.0|::1/NOWHERE/' \
  HEADROOM_PORT="$P" ANTHROPIC_BASE_URL="http://127.0.0.1:$P"
state_fx none; mkdir "$MS/headroom/receipt.json"
mutant "unreadable state reads as absent" lean_route_guard.sh 's/echo unreadable/echo absent/'

echo "--------------------------------------------------------------------"
printf 'lean-route-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
