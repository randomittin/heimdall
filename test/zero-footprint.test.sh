#!/usr/bin/env bash
#
# zero-footprint.test.sh — acceptance for RP7's remainder: `hmd demo --offline`, and the
# zero-footprint trial path `npx runhmd attack` / `npx runhmd demo --offline`.
#
#   bash test/zero-footprint.test.sh    (exit 0 = every case passes)
#
# What is promised, and how each promise is made able to fail (R6):
#
#   A. demo       `hmd demo --offline` tells "agent writes a bug -> DENIED -> fix -> PROVEN" with the REAL
#                 attack engine on the bundled fixture pair. It is not a script: break the engine's
#                 answer (a "buggy" fixture that is actually clean, a missing fixture) and the demo exits 5
#                 instead of telling the story anyway.
#   B. offline    the arc makes ZERO network calls. The whole thing runs under a kernel sandbox that
#                 SIGKILLs any process that opens a socket or resolves a name (macOS sandbox-exec).
#                 Controls: a canary connects to a loopback listener outside the sandbox and is killed inside
#                 it; a deliberately leaky copy of the demo reaches the listener outside the sandbox and is
#                 killed inside it. Without a sandbox on this host the proof is SKIPPED, loudly - never faked.
#   C. footprint  `demo --offline` run in place writes nothing outside one temp dir that is gone afterwards:
#                 not HOME, not the repo it is run in, not the install it runs from (no __pycache__).
#   D. wrapper    `runhmd attack ...` and `runhmd demo --offline ...` run with HOME (and every override that
#                 would bypass it) redirected into a temp dir: a footprint-hostile stand-in installer (writes
#                 ~/.zshrc, ~/.claude/settings.json, a LaunchAgent, ~/.heimdall, the cwd) leaves a seeded HOME
#                 byte-identical - snapshot AND `find $HOME -newer marker` - and the temp dir is removed on every
#                 exit path. Writes aimed at protected paths are refused with exit 2. Mutants of the wrapper
#                 (each protection removed in turn) must make the same assertions go RED.
#   E. npx        the packed tarball, run through npx with an isolated npm cache, leaves HOME untouched too.
#
# Everything runs against a throwaway HOME / TMPDIR / project repo under one mktemp dir. The suite never
# touches the developer's real HOME: it only reads from it (git config is pointed away).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd -P)"
PKG_DIR="$REPO/packages/runhmd"
WRAP="$PKG_DIR/bin/runhmd.js"
DEMO_BIN="$REPO/bin/heimdall-demo"
FIXTURES="$SELF_DIR/lib/runhmd-fixtures.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }

[ -r "$FIXTURES" ] || { echo "FATAL: shared fixtures missing: $FIXTURES" >&2; exit 2; }
# shellcheck source=lib/runhmd-fixtures.sh
# shellcheck disable=SC1091  # sourced lib is not a shellcheck input without -x
. "$FIXTURES"
for t in node jq python3 shasum git perl; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t is required" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zero-footprint-test.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: WORK path empty (mktemp failed)" >&2; exit 2; }
WORK="$(cd "$WORK" && pwd -P)"
LISTENER_PID=""
# shellcheck disable=SC2329  # runs via the EXIT trap right below; shellcheck does not follow that reference here
cleanup() {
  if [ -n "$LISTENER_PID" ]; then kill "$LISTENER_PID" 2>/dev/null; fi
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

BIN="$WORK/bin"; TMPD="$WORK/tmp"; LOGS="$WORK/logs"
mkdir -p "$BIN" "$TMPD" "$LOGS"

# ── the toolchain every run sees ─────────────────────────────────────────────
# A scrubbed environment (env -i) and a PATH made of real binaries only. python3 is linked to the
# interpreter itself rather than whatever shim answers to the name: a version-manager shim finds its
# versions through $HOME, which every case here replaces, so a shim would fail for reasons that have
# nothing to do with the footprint under test.
NODE_BIN="$(command -v node)"
PY3_REAL="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -x "$PY3_REAL" ] || { echo "FATAL: cannot resolve the python3 interpreter" >&2; exit 2; }
ln -s "$PY3_REAL" "$BIN/python3"
ln -s "$REPO/bin/heimdall" "$BIN/hmd"          # the real dispatcher, under its everyday name
REAL_PATH="$BIN:$(dirname "$NODE_BIN"):$(dirname "$(command -v git)"):$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin"
# Stand-in cases must not be able to find the real hmd: that PATH is node and the system only.
STUB_PATH="$(dirname "$NODE_BIN"):/usr/bin:/bin"
if [ -n "$(env -i PATH="$STUB_PATH" /usr/bin/which hmd 2>/dev/null)" ]; then
  echo "FATAL: a real hmd is reachable on the hermetic stand-in PATH ($STUB_PATH) - refusing to run" >&2
  exit 2
fi
CUR_PATH="$REAL_PATH"

OUT="$WORK/out"; ERR="$WORK/err"; RC=0
PREFIX=()                       # command prefix every run goes through; the network sandbox for section B

# run_in <home> <cwd> [VAR=value ...] -- <cmd args...>
# Scrubbed environment, TMPDIR inside WORK; extra VAR=value pairs come last so they override.
run_in() {
  local home="$1" cwd="$2"; shift 2
  local extra=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  ( cd "$cwd" && ${PREFIX[@]+"${PREFIX[@]}"} env -i HOME="$home" PATH="$CUR_PATH" TMPDIR="$TMPD" \
      ${extra[@]+"${extra[@]}"} "$@" ) >"$OUT" 2>"$ERR"
  RC=$?
}

dump() { sed 's/^/    | /' "$ERR" >&2; }
jq_ok() {  # <label> <jq -e filter> [file]  — the file defaults to the last run's stdout
  local label="$1" filter="$2" file="${3:-$OUT}"
  if jq -e "$filter" "$file" >/dev/null 2>&1; then ok "$label"; else bad "$label (jq: $filter)"; head -c 600 "$file" | sed 's/^/    | /' >&2; fi
}
rc_is() {  # <label> <expected rc>
  if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $RC, wanted $2)"; dump; fi
}

# ── snapshots: the footprint check ───────────────────────────────────────────
# snapshot <dir>: every entry (so a new or removed file shows) and every file's sha256 (so a changed one does).
snapshot() {
  ( cd "$1" && { find . -print | LC_ALL=C sort; find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort -k2; } ) 2>/dev/null
}
# Everything the run must not touch is backdated to 2020-01-01; MARKER sits at 2020-06-01. So
# `find <dir> -newer $MARKER` is exactly "written during the run", with no need to wait out a clock tick -
# and a directory whose entries were created and removed again (a transient file) shows up too.
MARKER="$WORK/marker"; touch -t 202006010000 "$MARKER"
backdate() { find "$1" -exec touch -t 202001010000 {} + 2>/dev/null; }

H=""; HN=0
new_home() {  # [stub-hmd-version] — a fresh, seeded HOME the run must leave byte-identical
  HN=$((HN+1)); H="$WORK/home$HN"
  mkdir -p "$H/.claude" "$H/Library/LaunchAgents" "$H/.local/bin"
  printf '# my zshrc\nexport EDITOR=vim\n' > "$H/.zshrc"
  local f
  for f in .bashrc .bash_profile .profile .zprofile .zshenv; do printf '# my %s\n' "$f" > "$H/$f"; done
  printf '{"theme":"dark"}\n'  > "$H/.claude/settings.json"
  printf '{"model":"opus"}\n'  > "$H/.claude/settings.local.json"
  printf '<plist><!-- somebody else job --></plist>\n' > "$H/Library/LaunchAgents/com.example.keep.plist"
  printf '[user]\n\tname = someone\n' > "$H/.gitconfig"
  if [ -n "${1:-}" ]; then
    cp "$STUB_HMD_TEMPLATE" "$H/.local/bin/hmd"; chmod +x "$H/.local/bin/hmd"
    printf '%s\n' "$1" > "$H/.local/bin/.hmd-version"
  fi
  backdate "$H"
  snapshot "$H" > "$WORK/snap-home$HN"
}

PROJ="$WORK/proj"
mkdir -p "$PROJ"
( cd "$PROJ" && export HOME="$WORK/githome" GIT_CONFIG_NOSYSTEM=1 \
    && git init -q . && git config user.email t@example.invalid && git config user.name t \
    && printf 'hello\n' > app.txt && git add app.txt && git -c commit.gpgsign=false commit -q -m init ) >/dev/null 2>&1
backdate "$PROJ"
snapshot "$PROJ" > "$WORK/snap-proj"

# footprint_report — empty when HOME, the project repo and the temp dir all came out of the run unchanged.
footprint_report() {
  diff <(snapshot "$H") "$WORK/snap-home$HN" | sed 's/^/home changed: /'
  find "$H" -newer "$MARKER" | sed 's/^/home newer than marker: /'
  diff <(snapshot "$PROJ") "$WORK/snap-proj" | sed 's/^/repo changed: /'
  find "$PROJ" -newer "$MARKER" | sed 's/^/repo newer than marker: /'
  find "$TMPD" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | sed 's/^/temp dir left behind: /'
}
assert_clean() {  # <label>
  local rep; rep="$(footprint_report)"
  if [ -z "$rep" ]; then ok "$1"; else bad "$1"; printf '%s\n' "$rep" | head -12 | sed 's/^/    | /' >&2; fi
}
assert_dirty() {  # <label> — the negative control: the same check MUST see a footprint here
  local rep; rep="$(footprint_report)"
  if [ -n "$rep" ]; then ok "$1"; else bad "$1 (no footprint seen: the check cannot go red, so it proves nothing)"; fi
}
reset_tmp() { rm -rf "$TMPD"; mkdir -p "$TMPD"; }

# ── a mini install: just enough of one to run `hmd demo --offline` from somewhere else ───
make_mini() {  # <dest>
  local d="$1"
  mkdir -p "$d/bin/lib" "$d/evals/oracles" "$d/docs/schemas" "$d/fixtures"
  cp "$REPO/bin/heimdall-demo" "$REPO/bin/heimdall-attack" "$d/bin/"
  cp "$REPO/bin/lib/runhmd_demo.py" "$REPO/bin/lib/runhmd_attack.py" "$REPO/bin/lib/runhmd_card.py" \
     "$REPO/bin/lib/runhmd_schema.py" "$d/bin/lib/" 2>/dev/null
  cp -R "$REPO/evals/oracles/attack" "$d/evals/oracles/attack"
  cp "$REPO/docs/schemas/runhmd.verdict.v1.json" "$d/docs/schemas/"
  cp -R "$REPO/fixtures/attack" "$d/fixtures/attack"
}

echo "zero-footprint harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ══════════════════════════════════════════════════════════════════════════════
# A. demo
# ══════════════════════════════════════════════════════════════════════════════
echo "A. demo — hmd demo --offline: DENIED -> fix -> PROVEN, told by the real engine"

new_home
REPO_FIX="$REPO/fixtures/attack"

run_in "$H" "$PROJ" -- hmd demo --offline --json
rc_is "hmd demo --offline --json exits 0" 0
jq_ok "the sequence is exactly [DENIED, PROVEN]" '.sequence == ["DENIED","PROVEN"]'
jq_ok "the document names its schema and mode, and carries a numeric duration_s" \
  '.schema == "runhmd.demo/1" and .mode == "offline" and (.duration_s | type == "number") and .duration_s >= 0'
jq_ok "before is a real runhmd.verdict/1 DENIED with at least one counterexample" \
  '.before.schema == "runhmd.verdict/1" and .before.verdict == "DENIED" and (.before.findings | length) >= 1
   and (.before.findings[0].counterexample.summary | length) > 0'
jq_ok "after is a real runhmd.verdict/1 PROVEN with no findings, over the same battery" \
  '.after.schema == "runhmd.verdict/1" and .after.verdict == "PROVEN" and (.after.findings | length) == 0
   and .after.attacks.killed == 0 and .after.attacks.survived == .after.attacks.total
   and .after.attacks.total == .before.attacks.total and .before.attacks.killed >= 1'
if jq -e --arg a "$REPO_FIX/buggy-webhook" --arg b "$REPO_FIX/clean-sample" \
     '.before.target.ref == $a and .after.target.ref == $b' "$OUT" >/dev/null 2>&1; then
  ok "the verdicts attack the bundled fixtures: fixtures/attack/buggy-webhook, then fixtures/attack/clean-sample"
else
  bad "the verdicts do not attack buggy-webhook then clean-sample"; head -c 400 "$OUT" | sed 's/^/    | /' >&2
fi
jq_ok "the fix is a real diff of webhook.mjs (the claim made atomic)" \
  '.fix.file == "webhook.mjs" and (.fix.diff | contains("putIfAbsent")) and (.fix.diff | contains("alreadyProcessed"))'
jq_ok "cost is the sum of the verdicts' cost (no model: zero)" '.cost_usd == 0 and .cost_usd == (.before.cost_usd + .after.cost_usd)'
if [ ! -s "$ERR" ]; then ok "--json writes nothing on stderr"; else bad "--json wrote on stderr"; dump; fi

# The counterexample's repro command is the real one: run it and the same DENIED comes back.
REPRO="$(jq -r '.before.findings[0].counterexample.repro_cmd' "$WORK/out" 2>/dev/null)"
case "$REPRO" in
  "hmd attack "*" --json --yes")
    run_in "$H" "$PROJ" -- sh -c "$REPRO"
    if [ "$RC" -eq 1 ] && jq -e '.verdict == "DENIED"' "$OUT" >/dev/null 2>&1; then
      ok "the printed repro_cmd, run as printed, reproduces DENIED (exit 1)"
    else
      bad "the printed repro_cmd ($REPRO) did not reproduce DENIED (exit $RC)"; dump
    fi ;;
  *) bad "repro_cmd has an unexpected shape: $REPRO" ;;
esac

run_in "$H" "$PROJ" -- hmd demo --offline
rc_is "hmd demo --offline (human render) exits 0" 0
D_LINE="$(grep -n 'VERDICT: DENIED' "$OUT" | head -1 | cut -d: -f1)"
P_LINE="$(grep -n 'VERDICT: PROVEN' "$OUT" | head -1 | cut -d: -f1)"
if [ -n "$D_LINE" ] && [ -n "$P_LINE" ] && [ "$D_LINE" -lt "$P_LINE" ]; then
  ok "the render shows the DENIED card, then the PROVEN card"
else
  bad "the render does not show DENIED then PROVEN (DENIED at line '${D_LINE:-none}', PROVEN at '${P_LINE:-none}')"; head -40 "$OUT" | sed 's/^/    | /' >&2
fi
if grep -q 'duplicate settlement' "$OUT" && grep -q 'putIfAbsent' "$OUT" && grep -q 'DENIED -> PROVEN' "$OUT"; then
  ok "…names the counterexample, shows the fix, and ends on the DENIED -> PROVEN line"
else
  bad "the render lacks the counterexample, the fix, or the closing line"; head -60 "$OUT" | sed 's/^/    | /' >&2
fi

run_in "$H" "$PROJ" -- hmd demo --offline --help
if [ "$RC" -eq 0 ] && grep -q 'DENIED' "$OUT" && grep -q -- '--json' "$OUT"; then ok "hmd demo --offline --help explains the arc and --json (exit 0)"; else bad "hmd demo --offline --help (exit $RC)"; dump; fi
run_in "$H" "$PROJ" -- hmd demo --help
if [ "$RC" -eq 0 ] && grep -q -- '--offline' "$OUT"; then ok "hmd demo --help lists --offline"; else bad "hmd demo --help does not list --offline (exit $RC)"; fi

for bad_args in "--offline --run" "--offline some-dir" "--offline --bogus" "--offline --force"; do
  # shellcheck disable=SC2086
  run_in "$H" "$PROJ" -- hmd demo $bad_args
  if [ "$RC" -eq 2 ] && [ ! -s "$OUT" ] && [ -s "$ERR" ]; then
    ok "hmd demo $bad_args: usage error, exit 2, a message on stderr, nothing on stdout"
  else
    bad "hmd demo $bad_args: exit $RC, stdout $(wc -c < "$OUT") bytes, stderr $(wc -c < "$ERR") bytes"
  fi
done

SCAFFOLD="$WORK/scaffold"
run_in "$H" "$PROJ" HEIMDALL_HOME="$WORK/demo-heimdall-home" -- "$DEMO_BIN" "$SCAFFOLD" --no-intro
if [ "$RC" -eq 0 ] && [ -f "$SCAFFOLD/.heimdall-demo-task.md" ] && [ -f "$SCAFFOLD/.planning/PLAN.md" ]; then
  ok "without --offline the scaffold demo is unchanged (task + plan written, exit 0)"
else
  bad "the scaffold demo regressed without --offline (exit $RC)"; dump
fi

# A broken install is an error, never a happy story.
MINI="$WORK/mini"; make_mini "$MINI"
run_in "$H" "$PROJ" -- "$MINI/bin/heimdall-demo" --offline --json
if [ "$RC" -eq 0 ] && jq -e '.sequence == ["DENIED","PROVEN"]' "$OUT" >/dev/null 2>&1; then
  ok "a copied install (demo + engine + fixtures, nothing else) runs the arc too: no dependency on the checkout"
else
  bad "the mini install does not run the arc (exit $RC)"; dump
fi

MINI_BROKEN="$WORK/mini-broken"; make_mini "$MINI_BROKEN"
cp "$MINI_BROKEN/fixtures/attack/clean-sample/webhook.mjs" "$MINI_BROKEN/fixtures/attack/buggy-webhook/webhook.mjs"
run_in "$H" "$PROJ" -- "$MINI_BROKEN/bin/heimdall-demo" --offline --json
if [ "$RC" -eq 5 ] && jq -e '.error == "demo_sequence" and (has("sequence") | not)' "$OUT" >/dev/null 2>&1; then
  ok "a 'buggy' fixture the engine PROVES: exit 5, error demo_sequence, and no DENIED -> PROVEN story is printed"
else
  bad "a buggy fixture the engine proves must exit 5 with demo_sequence (exit $RC)"; head -c 400 "$OUT" | sed 's/^/    | /' >&2
fi
run_in "$H" "$PROJ" -- "$MINI_BROKEN/bin/heimdall-demo" --offline
if [ "$RC" -eq 5 ] && ! grep -q 'DENIED -> PROVEN' "$OUT" && [ -s "$ERR" ]; then
  ok "…and the human render fails the same way: exit 5, the reason on stderr, no success line"
else
  bad "human render of a broken demo (exit $RC)"; head -20 "$OUT" | sed 's/^/    | /' >&2
fi

MINI_GONE="$WORK/mini-gone"; make_mini "$MINI_GONE"; rm -rf "$MINI_GONE/fixtures/attack/clean-sample"
run_in "$H" "$PROJ" -- "$MINI_GONE/bin/heimdall-demo" --offline --json
if [ "$RC" -eq 5 ] && jq -e '.error == "demo_fixture_missing"' "$OUT" >/dev/null 2>&1; then
  ok "a missing fixture: exit 5, error demo_fixture_missing"
else
  bad "a missing fixture must exit 5 with demo_fixture_missing (exit $RC)"; head -c 400 "$OUT" | sed 's/^/    | /' >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# B. offline — zero network calls
# ══════════════════════════════════════════════════════════════════════════════
echo "B. offline — the arc under a kernel sandbox that kills any network call"

NETJAIL_PROFILE='(version 1)(allow default)(deny network* (with send-signal SIGKILL))'
jail_usable() {
  command -v sandbox-exec >/dev/null 2>&1 && sandbox-exec -p "$NETJAIL_PROFILE" /usr/bin/true >/dev/null 2>&1
}

if ! jail_usable; then
  skip "no usable kernel network sandbox on this host (macOS sandbox-exec): --offline's zero-network guarantee is NOT proven by this run"
else
  cat > "$WORK/listener.py" <<'PYEOF'
import socket
import sys

port_file, count_file, ttl = sys.argv[1], sys.argv[2], float(sys.argv[3])
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(16)
with open(count_file, "w") as fh:
    fh.write("0")
with open(port_file, "w") as fh:
    fh.write(str(srv.getsockname()[1]))
srv.settimeout(ttl)
count = 0
while True:
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        break
    conn.close()
    count += 1
    with open(count_file, "w") as fh:
        fh.write(str(count))
PYEOF
  python3 "$WORK/listener.py" "$WORK/lport" "$WORK/lcount" 300 >/dev/null 2>&1 &
  LISTENER_PID=$!
  disown "$LISTENER_PID" 2>/dev/null   # its termination at cleanup is not news
  i=0; while [ ! -s "$WORK/lport" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  LPORT="$(cat "$WORK/lport" 2>/dev/null || true)"
  lcount() { cat "$WORK/lcount" 2>/dev/null || echo "?"; }

  if [ -z "$LPORT" ]; then
    bad "could not start the loopback listener the controls depend on"
  else
    CANARY='import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 5).close()'
    DNS_CANARY='import socket; socket.getaddrinfo("zero-footprint-canary.invalid", 443)'

    run_in "$H" "$PROJ" -- python3 -c "$CANARY" "$LPORT"
    if [ "$RC" -eq 0 ] && [ "$(lcount)" = "1" ]; then
      ok "control: outside the sandbox the canary connects and the listener sees it (count 1)"
    else
      bad "control: the canary should reach the listener outside the sandbox (exit $RC, count $(lcount))"
    fi

    PREFIX=(sandbox-exec -p "$NETJAIL_PROFILE")
    run_in "$H" "$PROJ" -- python3 -c "$CANARY" "$LPORT"
    if [ "$RC" -eq 137 ] && [ "$(lcount)" = "1" ]; then
      ok "control: inside the sandbox the same canary is killed (SIGKILL) and never reaches the listener"
    else
      bad "control: the sandbox must kill a socket connect (exit $RC, listener count $(lcount))"
    fi
    run_in "$H" "$PROJ" -- python3 -c "$DNS_CANARY"
    if [ "$RC" -eq 137 ]; then ok "control: inside the sandbox a name lookup is killed too"; else bad "control: the sandbox must kill a name lookup (exit $RC)"; fi

    run_in "$H" "$PROJ" -- hmd demo --offline --json
    if [ "$RC" -eq 0 ] && jq -e '.sequence == ["DENIED","PROVEN"]' "$OUT" >/dev/null 2>&1; then
      ok "hmd demo --offline --json completes DENIED -> PROVEN with the network killed"
    else
      bad "hmd demo --offline under the network sandbox (exit $RC)"; dump
    fi
    if ! grep -q 'Killed' "$ERR"; then ok "…and nothing in its process tree was killed (no swallowed network attempt)"; else bad "a process in the tree was killed - something tried the network"; dump; fi
    run_in "$H" "$PROJ" -- hmd demo --offline
    rc_is "hmd demo --offline (human render) completes with the network killed" 0

    run_in "$H" "$PROJ" -- hmd attack "$REPO_FIX/buggy-webhook" --no-network --json --yes
    if [ "$RC" -eq 1 ] && jq -e '.verdict == "DENIED"' "$OUT" >/dev/null 2>&1; then
      ok "hmd attack on its own engine: DENIED with the network killed"
    else
      bad "hmd attack under the network sandbox (exit $RC)"; dump
    fi

    # The mutant: a demo that reaches for the network once. Outside the sandbox the leak is real and the
    # listener counts it; inside, the same copy is killed - so the checks above can go red.
    MINI_LEAK="$WORK/mini-leak"; make_mini "$MINI_LEAK"
    awk -v port="$LPORT" '{print} /^import tempfile$/ {print "import socket as _leak; _leak.socket().connect_ex((\"127.0.0.1\", " port "))"}' \
      "$MINI_LEAK/bin/lib/runhmd_demo.py" > "$WORK/leaky.py"
    if cmp -s "$WORK/leaky.py" "$MINI_LEAK/bin/lib/runhmd_demo.py"; then
      bad "SELF-TEST BROKEN: the leak was not planted (no 'import tempfile' anchor in runhmd_demo.py) - the proof would be vacuous"
    else
      cp "$WORK/leaky.py" "$MINI_LEAK/bin/lib/runhmd_demo.py"
      BEFORE="$(lcount)"
      PREFIX=()
      run_in "$H" "$PROJ" -- "$MINI_LEAK/bin/heimdall-demo" --offline --json
      if [ "$RC" -eq 0 ] && [ "$(lcount)" -gt "$BEFORE" ]; then
        ok "mutant: a demo with one planted connect still works unsandboxed, and the listener counts the leak ($BEFORE -> $(lcount))"
      else
        bad "mutant: the planted connect was not observed outside the sandbox (exit $RC, count $BEFORE -> $(lcount))"
      fi
      PREFIX=(sandbox-exec -p "$NETJAIL_PROFILE")
      run_in "$H" "$PROJ" -- "$MINI_LEAK/bin/heimdall-demo" --offline --json
      if [ "$RC" -ne 0 ] && ! jq -e '.sequence' "$OUT" >/dev/null 2>&1; then
        ok "mutant: the same leaky demo is killed under the sandbox (exit $RC) - a network call turns this suite red"
      else
        bad "mutant: the leaky demo survived the network sandbox (exit $RC)"
      fi
    fi
    PREFIX=()
  fi
fi
PREFIX=()

# ══════════════════════════════════════════════════════════════════════════════
# C. footprint of the demo, run in place
# ══════════════════════════════════════════════════════════════════════════════
echo "C. footprint — hmd demo --offline writes nothing outside its own temp dir"

new_home; reset_tmp
run_in "$H" "$PROJ" -- "$MINI/bin/heimdall-demo" --offline --json
rc_is "demo --offline from an installed copy exits 0" 0
assert_clean "HOME, the repo it ran in and the temp dir are byte-identical afterwards"
if [ -z "$(find "$MINI" -name '__pycache__' 2>/dev/null)" ]; then
  ok "the install it ran from gained no __pycache__ (bytecode writing is off)"
else
  bad "running the demo wrote bytecode into the install: $(find "$MINI" -name '__pycache__' | head -2 | tr '\n' ' ')"
fi
# control: the attack CLI on its own does write bytecode, so the check above can go red
MINI_PYC="$WORK/mini-pyc"; make_mini "$MINI_PYC"
run_in "$H" "$PROJ" -- "$MINI_PYC/bin/heimdall-attack" "$MINI_PYC/fixtures/attack/clean-sample" --json --yes
if [ -n "$(find "$MINI_PYC" -name '__pycache__' 2>/dev/null)" ]; then
  ok "control: hmd attack run bare writes __pycache__ into its install - the check above is able to fail"
else
  bad "control: no __pycache__ appeared for a bare hmd attack, so the bytecode check proves nothing"
fi
reset_tmp

# ══════════════════════════════════════════════════════════════════════════════
# D. wrapper — runhmd attack / runhmd demo --offline leave nothing behind
# ══════════════════════════════════════════════════════════════════════════════
echo "D. wrapper — HOME and every override redirected into a temp dir; protected writes refused"

STUBS="$WORK/stubs"; mkdir -p "$STUBS"
STUB_HMD_TEMPLATE="$STUBS/hmd-template"
cat > "$STUB_HMD_TEMPLATE" <<'STUB'
#!/usr/bin/env bash
# stand-in hmd: like the real one it bumps $HEIMDALL_HOME/.run-count on EVERY invocation, --version included
here="$(cd "$(dirname "$0")" && pwd)"
state="${HEIMDALL_HOME:-$HOME/.heimdall}"
mkdir -p "$state" 2>/dev/null && printf '1\n' > "$state/.run-count"
if [ "${1:-}" = "--version" ]; then
  printf 'Heimdall v%s\n' "$(cat "$here/.hmd-version" 2>/dev/null || echo '?')"
  exit 0
fi
{
  printf 'ARGV=%s\n' "$*"
  printf 'HOME=%s\n' "$HOME"
  printf 'TMPDIR=%s\n' "${TMPDIR:-}"
  printf 'HEIMDALL_HOME=%s\n' "${HEIMDALL_HOME:-}"
  printf 'CLAUDE_CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR:-}"
  printf 'HEIMDALL_LAUNCH_AGENTS_DIR=%s\n' "${HEIMDALL_LAUNCH_AGENTS_DIR:-}"
  printf 'HEIMDALL_TEAM_DIR=%s\n' "${HEIMDALL_TEAM_DIR:-}"
  printf 'PYTHONDONTWRITEBYTECODE=%s\n' "${PYTHONDONTWRITEBYTECODE:-}"
  printf 'HEIMDALL_NO_DREAM_SCHEDULE=%s\n' "${HEIMDALL_NO_DREAM_SCHEDULE:-}"
  printf 'CWD=%s\n' "$(pwd -P)"
} >> "${STUB_ENV_LOG:?}"
printf 'hmd-stub-ran\n'
exit "${STUB_HMD_EXIT:-0}"
STUB
chmod +x "$STUB_HMD_TEMPLATE"

# A footprint-hostile install.sh: the kinds of write the real one makes - a PATH line appended to the shell
# profile, Claude Code settings, a LaunchAgent, ~/.heimdall, ~/.local/bin/hmd, and a team file under the cwd.
STUB_INSTALLER="$STUBS/install.sh"
cat > "$STUB_INSTALLER" <<'STUB'
#!/usr/bin/env bash
{ printf 'ran\n'; printf '%s\n' "$#"; } > "${STUB_INSTALL_MARK:-/dev/null}"
pwd -P > "${STUB_INSTALL_CWD:-/dev/null}"
[ "${STUB_INSTALL_MODE:-ok}" = "fail" ] && exit 7
mkdir -p "$HOME/.local/bin" "${HEIMDALL_HOME:-$HOME/.heimdall}"
cp "$STUB_HMD_TEMPLATE" "$HOME/.local/bin/hmd"; chmod +x "$HOME/.local/bin/hmd"
printf '%s\n' "${STUB_INSTALL_VERSION:-999.0.0}" > "$HOME/.local/bin/.hmd-version"
printf '\nexport PATH="$HOME/.local/bin:$PATH"  # heimdall\n' >> "$HOME/.zshrc"
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; mkdir -p "$cfg"; printf '{"statusLine":{}}\n' > "$cfg/settings.json"
la="${HEIMDALL_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"; mkdir -p "$la"; printf '<plist/>\n' > "$la/com.heimdall.dream.plist"
team="${HEIMDALL_TEAM_DIR:-$(pwd)/.heimdall}"; mkdir -p "$team"; printf '{}\n' > "$team/team.json"
printf 'installed\n' > "${HEIMDALL_HOME:-$HOME/.heimdall}/installed"
exit 0
STUB
chmod +x "$STUB_INSTALLER"
INSTALLER_SHA="$(rf_sha256 "$STUB_INSTALLER")"

WRAP_UT="$WRAP"
CASE=0; ELOG=""; MARK=""; ICWD=""
zf_case() {  # [VAR=value ...] -- <runhmd args...>  — a fresh log/marker set; HOME=$H, cwd=$PROJ, stand-in PATH
  CASE=$((CASE+1)); ELOG="$LOGS/env$CASE"; MARK="$LOGS/mark$CASE"; ICWD="$LOGS/icwd$CASE"
  CUR_PATH="$STUB_PATH"
  local extra=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  run_in "$H" "$PROJ" STUB_ENV_LOG="$ELOG" STUB_INSTALL_MARK="$MARK" STUB_INSTALL_CWD="$ICWD" \
    STUB_HMD_TEMPLATE="$STUB_HMD_TEMPLATE" RUNHMD_INSTALL_SCRIPT="$STUB_INSTALLER" RUNHMD_SHA256="$INSTALLER_SHA" \
    ${extra[@]+"${extra[@]}"} -- "$NODE_BIN" "$WRAP_UT" "$@"
}
envlog()      { sed -n "s/^$1=//p" "$ELOG" 2>/dev/null | head -1; }
ran_hmd()     { [ -s "$ELOG" ]; }
ran_install() { [ -e "$MARK" ]; }
assert_refused() {  # <label> — exit 2, said so, and neither the installer nor hmd ran
  if [ "$RC" -eq 2 ] && ! ran_install && ! ran_hmd && grep -q 'zero-footprint' "$ERR"; then ok "$1"
  else bad "$1 (exit $RC; installer ran: $(ran_install && echo yes || echo no); hmd ran: $(ran_hmd && echo yes || echo no))"; dump; fi
}

new_home; reset_tmp
zf_case -- attack .
rc_is "attack, hmd not installed: the pinned installer runs, then hmd (exit 0)" 0
if ran_install && [ "$(envlog ARGV)" = "attack ." ]; then ok "…installer ran, then hmd ran with the routed argv"; else bad "installer/hmd did not both run as routed (argv: $(envlog ARGV))"; dump; fi
case "$(cat "$ICWD" 2>/dev/null)" in
  "$TMPD"/runhmd-zf-*/work) ok "…the installer's cwd was an empty work dir inside the temp dir, not the repo" ;;
  *) bad "installer cwd was: $(cat "$ICWD" 2>/dev/null)" ;;
esac
case "$(envlog HOME)" in
  "$TMPD"/runhmd-zf-*/home) ok "…hmd saw HOME inside the temp dir" ;;
  *) bad "hmd saw HOME=$(envlog HOME)" ;;
esac
if [ "$(envlog PYTHONDONTWRITEBYTECODE)" = 1 ] && [ "$(envlog HEIMDALL_NO_DREAM_SCHEDULE)" = 1 ] && [ "$(envlog CWD)" = "$(cd "$PROJ" && pwd -P)" ]; then
  ok "…bytecode writing and the LaunchAgent schedule are off, and hmd keeps the caller's cwd (relative targets still work)"
else
  bad "env/cwd hmd saw: bytecode=$(envlog PYTHONDONTWRITEBYTECODE) schedule=$(envlog HEIMDALL_NO_DREAM_SCHEDULE) cwd=$(envlog CWD)"
fi
assert_clean "…HOME (.zshrc, Claude settings, LaunchAgents, ~/.heimdall), the repo and the temp dir are untouched"

new_home 999.0.0; reset_tmp
zf_case -- demo --offline --json
rc_is "demo --offline, hmd already installed in the real home: exit 0" 0
if ! ran_install && [ "$(envlog ARGV)" = "demo --offline --json" ]; then ok "…no installer ran; hmd ran with the routed argv"; else bad "installed-hmd case (argv: $(envlog ARGV))"; fi
assert_clean "…hmd's own .run-count write (every invocation, --version included) landed in the temp dir, not ~/.heimdall"

new_home; reset_tmp
zf_case CLAUDE_CONFIG_DIR="$H/.claude" HEIMDALL_LAUNCH_AGENTS_DIR="$H/Library/LaunchAgents" HEIMDALL_HOME="$H/.heimdall" HEIMDALL_TEAM_DIR="$H/team" -- attack .
rc_is "attack with CLAUDE_CONFIG_DIR / HEIMDALL_HOME / ... pointing INTO the real home: exit 0" 0
if [ -z "$(envlog CLAUDE_CONFIG_DIR)$(envlog HEIMDALL_HOME)$(envlog HEIMDALL_LAUNCH_AGENTS_DIR)$(envlog HEIMDALL_TEAM_DIR)" ]; then ok "…none of the four overrides reached hmd"; else bad "an override survived the redirect"; fi
assert_clean "…and the installer could not write through them: the real home is untouched"

new_home; reset_tmp
zf_case TMPDIR="$H/.claude" -- attack .
assert_refused "a TMPDIR inside ~/.claude: refused with exit 2 before anything runs"
assert_clean "…nothing was created there, not even transiently"
zf_case -- attack . --out "$H/Library/LaunchAgents"
assert_refused "--out ~/Library/LaunchAgents: refused with exit 2"
zf_case -- attack . "--out=$H/.claude/settings.json"
assert_refused "--out=~/.claude/settings.json: refused with exit 2"
zf_case -- attack . --out "$H/.zshrc"
assert_refused "--out ~/.zshrc: refused with exit 2"
assert_clean "…none of the refusals touched the real home"
zf_case -- attack . --out "$WORK/outdir"
if [ "$RC" -eq 0 ] && grep -q -- '--out' "$ELOG" 2>/dev/null; then ok "an --out elsewhere is not refused: the guard is not a blanket"; else bad "a benign --out was refused or lost (exit $RC)"; dump; fi

new_home 999.0.0; reset_tmp
zf_case -- team show --json
if [ "$RC" -eq 0 ] && [ "$(envlog HOME)" = "$H" ]; then ok "team show is not a trial command: hmd keeps the real HOME (zero-footprint is attack and demo --offline only)"; else bad "team show saw HOME=$(envlog HOME) (exit $RC)"; fi
zf_case -- demo
if [ "$RC" -eq 0 ] && [ "$(envlog HOME)" = "$H" ]; then ok "demo without --offline (it scaffolds into the cwd) keeps the real HOME"; else bad "demo saw HOME=$(envlog HOME) (exit $RC)"; fi

new_home; reset_tmp
zf_case STUB_INSTALL_MODE=fail -- attack .
if [ "$RC" -ne 0 ] && ! ran_hmd; then ok "installer fails: runhmd fails and hmd never runs"; else bad "failing installer (exit $RC)"; fi
assert_clean "…and the temp dir is gone, the real home and the repo untouched"
zf_case RUNHMD_SHA256="$(rf_bend_digest "$INSTALLER_SHA")" -- attack .
if [ "$RC" -ne 0 ] && ! ran_install && ! ran_hmd; then ok "digest mismatch: refused, nothing ran"; else bad "digest mismatch (exit $RC)"; fi
assert_clean "…and nothing was left behind"
new_home 999.0.0; reset_tmp
zf_case STUB_HMD_EXIT=3 -- attack .
rc_is "hmd's exit code (3) is runhmd's exit code under zero-footprint" 3
assert_clean "…and the temp dir is still removed"

# The mutants: each protection removed in turn. The same check that is green above MUST go red.
make_mutant() {  # <name> <sed expression> — sets MUTANT_JS to a copy of the wrapper without one protection
  local d="$WORK/mutant-$1"
  mkdir -p "$d/bin"; cp "$PKG_DIR/package.json" "$PKG_DIR/subcommands.txt" "$d/"
  sed "$2" "$WRAP" > "$d/bin/runhmd.js"
  if cmp -s "$d/bin/runhmd.js" "$WRAP"; then
    bad "SELF-TEST BROKEN: the '$1' mutation did not change runhmd.js - the proof would be vacuous"; return 1
  fi
  MUTANT_JS="$d/bin/runhmd.js"
}
if make_mutant home 's/process.env.HOME = path.join(root, .home.);/void root;/'; then
  new_home; reset_tmp; WRAP_UT="$MUTANT_JS"; zf_case -- attack .; WRAP_UT="$WRAP"
  assert_dirty "mutant: HOME not redirected -> the installer's footprint lands in the real home, and the check sees it"
fi
if make_mutant overrides 's/delete process.env\[name\];/void name;/'; then
  new_home; reset_tmp; WRAP_UT="$MUTANT_JS"
  zf_case CLAUDE_CONFIG_DIR="$H/.claude" HEIMDALL_LAUNCH_AGENTS_DIR="$H/Library/LaunchAgents" HEIMDALL_HOME="$H/.heimdall" HEIMDALL_TEAM_DIR="$H/team" -- attack .
  WRAP_UT="$WRAP"
  assert_dirty "mutant: overrides left in the environment -> the installer writes straight past the HOME redirect, and the check sees it"
fi
if make_mutant refusal 's/if (why) {/if (false) {/'; then
  new_home; reset_tmp; WRAP_UT="$MUTANT_JS"; zf_case -- attack . --out "$H/Library/LaunchAgents"; WRAP_UT="$WRAP"
  if [ "$RC" -ne 2 ] && ran_hmd; then ok "mutant: refusal disabled -> --out into LaunchAgents is passed through (the refusal checks can go red)"; else bad "mutant: the disabled refusal still refused (exit $RC)"; fi
fi
if make_mutant cleanup 's/fs.rmSync(root, { recursive: true, force: true });/void root;/'; then
  new_home; reset_tmp; WRAP_UT="$MUTANT_JS"; zf_case -- attack .; WRAP_UT="$WRAP"
  assert_dirty "mutant: temp dir never removed -> it is left behind, and the check sees it"
fi
reset_tmp

# The real hmd and the real engine through the wrapper.
JAIL_OK=0; jail_usable && JAIL_OK=1
CUR_PATH="$REAL_PATH"
new_home; reset_tmp
run_in "$H" "$PROJ" -- "$NODE_BIN" "$WRAP" "$REPO_FIX/clean-sample" --json --yes
if [ "$RC" -eq 0 ] && jq -e '.verdict == "PROVEN"' "$OUT" >/dev/null 2>&1; then ok "runhmd <path> through the real hmd: PROVEN (exit 0)"; else bad "runhmd <path> (exit $RC)"; dump; fi
run_in "$H" "$PROJ" -- "$NODE_BIN" "$WRAP" attack "$REPO_FIX/buggy-webhook" --json --yes
if [ "$RC" -eq 1 ] && jq -e '.verdict == "DENIED"' "$OUT" >/dev/null 2>&1; then ok "runhmd attack <buggy fixture>: DENIED (exit 1)"; else bad "runhmd attack buggy (exit $RC)"; dump; fi
run_in "$H" "$PROJ" -- "$NODE_BIN" "$WRAP" demo --offline --json
if [ "$RC" -eq 0 ] && jq -e '.sequence == ["DENIED","PROVEN"]' "$OUT" >/dev/null 2>&1; then ok "runhmd demo --offline --json: DENIED -> PROVEN (exit 0)"; else bad "runhmd demo --offline (exit $RC)"; dump; fi
assert_clean "…all three left the real home (no ~/.heimdall/.run-count), the repo and the temp dir untouched"
new_home; reset_tmp
run_in "$H" "$PROJ" PYTHONDONTWRITEBYTECODE=1 -- hmd attack "$REPO_FIX/clean-sample" --json --yes
assert_dirty "control: the real hmd run directly, without the wrapper, does leave a footprint (~/.heimdall/.run-count) - the check above can go red"
reset_tmp
if [ "$JAIL_OK" -eq 1 ]; then
  new_home; reset_tmp; PREFIX=(sandbox-exec -p "$NETJAIL_PROFILE")
  run_in "$H" "$PROJ" -- "$NODE_BIN" "$WRAP" demo --offline --json
  PREFIX=()
  if [ "$RC" -eq 0 ] && jq -e '.sequence == ["DENIED","PROVEN"]' "$OUT" >/dev/null 2>&1 && ! grep -q 'Killed' "$ERR"; then
    ok "runhmd demo --offline (wrapper + real hmd + real engine) completes with the network killed"
  else
    bad "runhmd demo --offline under the network sandbox (exit $RC)"; dump
  fi
  assert_clean "…and left nothing behind"
else
  skip "no network sandbox: the wrapper path's zero-network proof is NOT run here"
fi

# ══════════════════════════════════════════════════════════════════════════════
# E. npx — the packed tarball, through npx, isolated npm cache
# ══════════════════════════════════════════════════════════════════════════════
echo "E. npx — the packed package run through npx (offline, isolated cache)"
if ! command -v npm >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
  skip "npm/npx not found: the npx path is not exercised"
else
  PACK="$WORK/pack"; mkdir -p "$PACK" "$WORK/npm-cache" "$WORK/npx-tmp" "$WORK/npm-home"
  ( cd "$PKG_DIR" && HOME="$WORK/npm-home" npm_config_cache="$WORK/npm-cache" npm pack --pack-destination "$PACK" --ignore-scripts --silent ) >/dev/null 2>&1
  TGZ="$(find "$PACK" -maxdepth 1 -name 'runhmd-*.tgz' 2>/dev/null | sort | head -1)"
  if [ -z "$TGZ" ]; then
    bad "npm pack produced no tarball"
  else
    npx_run() {  # <runhmd args...>
      run_in "$H" "$PROJ" npm_config_cache="$WORK/npm-cache" TMPDIR="$WORK/npx-tmp" npm_config_update_notifier=false \
        npm_config_audit=false npm_config_fund=false -- npx --yes --offline --package="$TGZ" runhmd "$@"
    }
    new_home; reset_tmp
    npx_run --version
    if [ "$RC" -eq 0 ] && grep -q '^runhmd ' "$OUT"; then ok "npx runhmd --version answers from the packed tarball (exit 0)"; else bad "npx runhmd --version (exit $RC)"; dump; fi
    npx_run demo --offline --json
    if [ "$RC" -eq 0 ] && jq -e '.sequence == ["DENIED","PROVEN"]' "$OUT" >/dev/null 2>&1; then ok "npx runhmd demo --offline --json: DENIED -> PROVEN (exit 0)"; else bad "npx runhmd demo --offline (exit $RC)"; dump; fi
    assert_clean "…through npx, the real home (strictly: no npm cache excluded), the repo and the temp dir are untouched"
    if [ "$JAIL_OK" -eq 1 ]; then
      PREFIX=(sandbox-exec -p "$NETJAIL_PROFILE"); npx_run demo --offline --json; PREFIX=()
      if [ "$RC" -eq 0 ] && jq -e '.sequence == ["DENIED","PROVEN"]' "$OUT" >/dev/null 2>&1; then ok "npx runhmd demo --offline completes with the network killed"; else bad "npx runhmd demo --offline under the network sandbox (exit $RC)"; dump; fi
    fi
  fi
fi
reset_tmp

echo ""
if [ "$SKIP" -gt 0 ]; then echo "  ($SKIP skipped - see SKIP lines above)"; fi
echo "zero-footprint.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
