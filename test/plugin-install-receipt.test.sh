#!/usr/bin/env bash
#
# plugin-install-receipt.test.sh — auto-install transparency (2.4.8 M0, interim).
#
# The defect: the plugin/skill auto-install paths ran `claude plugins install … || true`,
# fell back to an unlisted third-party marketplace (wshobson/agents), and recorded nothing —
# so a run that installed code onto the machine left no trace, and a failed install vanished.
# That contradicts the install-transparency stance in README / docs/INSTALL.md.
#
# The contract proven here (no consent model — that is 3.1; no change to WHAT is installed):
#   A. every install attempt is receipted: name, source marketplace, version, result — one
#      NDJSON line per attempt in $HEIMDALL_HOME/receipts/installs-<run id>.ndjson;
#   B. a failed install is NOT swallowed: `install failed, continuing without <name>` goes to
#      stderr AND into the receipt, and the run still completes (fail-open);
#   C. the prompt-driven preinstall attempts exactly the same 8 plugins as before, each from
#      the listed marketplace only — no third-party marketplace is ever added;
#   D. the Run Receipt (`summary-card --receipt`) lists every install of THAT run, and nothing
#      for any other run;
#   E. the skill auto-install (git clone of a registry repo) is receipted the same way;
#   F. install.sh's own plugin install is receipted, loud on failure, and a no-op when present;
#   G. a hostile error message can never corrupt the receipt, and an unlisted marketplace is
#      refused without ever invoking `claude`.
#
# Hermetic: `claude`/`git`/`node` are PATH fakes, HOME and HEIMDALL_HOME are throwaway dirs, no
# network, no real `claude plugins install` against the operator's HOME.
#
# Usage: test/plugin-install-receipt.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── sandbox plugin tree: the launcher resolves its own PLUGIN_DIR from where it lives ──
TPLUG="$WORK/plugin"
mkdir -p "$TPLUG/bin/lib" "$WORK/fakehome" "$WORK/state" "$WORK/proj" "$WORK/none"
cp "$REPO/bin/heimdall" "$TPLUG/bin/heimdall"
cp "$REPO/skills-registry.json" "$TPLUG/skills-registry.json"
cp "$REPO/bin/lib/install-receipt.sh" "$TPLUG/bin/lib/install-receipt.sh" 2>/dev/null || true
chmod +x "$TPLUG/bin/heimdall"

FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
HH="$WORK/hh"
STATE="$WORK/state"
CALLS="$WORK/claude-calls.log"
GITCALLS="$WORK/git-calls.log"

cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
# Recording fake. State: $FAKE_STATE/{installed,markets}. FAKE_FAIL_RE fails `install <name>`;
# FAKE_FAIL_MSG overrides the failure text; FAKE_FAIL_MKT_RE fails `marketplace add <source>`.
echo "claude $*" >> "${FAKE_CALLS:-/dev/null}"
[ "${1:-}" = "--version" ] && { echo "1.99.0 (Claude Code)"; exit 0; }
case "${1:-}" in plugin|plugins) ;; *) exit 0 ;; esac
case "${2:-}" in
  install)
    id="${3:-}"; name="${id%%@*}"
    if [ -n "${FAKE_FAIL_RE:-}" ] && printf '%s' "$name" | grep -Eq "$FAKE_FAIL_RE"; then
      printf '%s\n' "${FAKE_FAIL_MSG:-✘ Failed to install plugin \"$id\": plugin not found in marketplace}" >&2
      exit 1
    fi
    echo "$id" >> "$FAKE_STATE/installed"
    echo "Successfully installed plugin: $id (scope: user)"; exit 0 ;;
  list)
    if printf '%s\n' "$@" | grep -qx -- '--json'; then
      printf '['; n=0
      while IFS= read -r id; do
        [ -n "$id" ] || continue; [ "$n" -eq 0 ] || printf ','; n=1
        printf '\n  {\n    "id": "%s",\n    "version": "%s",\n    "scope": "user",\n    "enabled": true\n  }' "$id" "${FAKE_VERSION:-5.0.7}"
      done < "$FAKE_STATE/installed"
      printf '\n]\n'
    else
      cat "$FAKE_STATE/installed"
    fi
    exit 0 ;;
  marketplace)
    case "${3:-}" in
      list) cat "$FAKE_STATE/markets"; exit 0 ;;
      add)
        src="${4%%#*}"
        if [ -n "${FAKE_FAIL_MKT_RE:-}" ] && printf '%s' "$src" | grep -Eq "$FAKE_FAIL_MKT_RE"; then
          echo "✘ Failed to add marketplace: repository not found" >&2; exit 1
        fi
        echo "${src##*/}" >> "$FAKE_STATE/markets"; echo "Successfully added marketplace: ${src##*/}"; exit 0 ;;
    esac ;;
esac
exit 0
SH
cat > "$FAKEBIN/node" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
# clone → create the dest (fail when FAKE_GIT_FAIL_RE matches the url); -C <dir> rev-parse → a sha.
case "${1:-}" in
  clone)
    dest="${@: -1}"; url="${@: -2:1}"
    echo "git clone $url" >> "${FAKE_GIT_CALLS:-/dev/null}"
    if [ -n "${FAKE_GIT_FAIL_RE:-}" ] && printf '%s' "$url" | grep -Eq "$FAKE_GIT_FAIL_RE"; then
      echo "fatal: unable to access '$url'" >&2; exit 128
    fi
    mkdir -p "$dest/.git"; exit 0 ;;
  -C) shift 2; [ "${1:-}" = "rev-parse" ] && { echo "abc1234def56"; exit 0; } ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/node" "$FAKEBIN/git"
ln -s "$PY" "$FAKEBIN/python3"

reset_fake() { : > "$STATE/installed"; : > "$STATE/markets"; : > "$CALLS"; : > "$GITCALLS"; rm -rf "$HH"; }

# Env every launcher/lib run shares. The fakes are first on PATH; /usr/bin:/bin carry coreutils.
fake_env() {  # $1 = run id ; remaining args = extra VAR=value
  local rid="$1"; shift
  env PATH="$FAKEBIN:/usr/bin:/bin" HOME="$WORK/fakehome" HEIMDALL_HOME="$HH" HMD_RUN_ID="$rid" \
    FAKE_STATE="$STATE" FAKE_CALLS="$CALLS" FAKE_GIT_CALLS="$GITCALLS" \
    ANTHROPIC_API_KEY="sk-test-not-a-real-key" "$@"
}

# One NDJSON line per attempt → `kind|name|result|version|source`. json.loads raises on a corrupt line.
summ() {
  "$PY" -I -c '
import json, sys
for line in open(sys.argv[1]):
    d = json.loads(line)
    print("|".join([d["kind"], d["name"], d["result"], d["version"], d["source"]]))
' "$1"
}
field() { "$PY" -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2])]).get(sys.argv[3], "<absent>"))' "$1" "$2" "$3"; }

OFF="anthropics/claude-plugins-official"
HMK="randomittin/heimdall-marketplace"

echo "plugin-install-receipt — every auto-install is receipted, loud on failure, no fallback marketplace"

# ╔═ A. first-run companion setup: every attempt receipted ═════════════════════════════╗
reset_fake; RID="run-a"
fake_env "$RID" "$TPLUG/bin/heimdall" --setup </dev/null >"$WORK/out.txt" 2>"$WORK/err.txt"; RC=$?
R="$HH/receipts/installs-$RID.ndjson"
[ "$RC" -eq 0 ] && ok "A: first-run setup exits 0" || bad "A: setup exit $RC: $(tail -3 "$WORK/err.txt" | tr '\n' ' ')"
WANT="$(printf 'marketplace|claude-plugins-official|ok|n/a|%s\nplugin|superpowers@claude-plugins-official|ok|5.0.7|%s\nmarketplace|heimdall-marketplace|ok|n/a|%s' "$OFF" "$OFF" "$HMK")"
GOT="$(summ "$R" 2>&1)"
[ "$GOT" = "$WANT" ] && ok "A: the receipt lists every install, in order, with source marketplace and resolved version" \
  || bad "A: receipt mismatch. want:\n$WANT\n got:\n$GOT"
[ -f "$HH/setup-done" ] && ok "A: setup marker written" || bad "A: setup marker missing"
grep -qE 'wshobson' "$CALLS" && bad "A: a third-party marketplace was touched" || ok "A: no third-party marketplace touched"
grep -qE -- '(--yes| -y( |$)|--accept-command)' "$CALLS" && bad "A: install ran with a consent-bypass flag" || ok "A: no consent-bypass flag (--yes / --accept-command) ever passed"

# ╔═ B. a failing install: loud, receipted, run completes ═══════════════════════════════╗
reset_fake; RID="run-b"
fake_env "$RID" FAKE_FAIL_RE='^superpowers$' "$TPLUG/bin/heimdall" --setup </dev/null >"$WORK/out.txt" 2>"$WORK/err.txt"; RC=$?
R="$HH/receipts/installs-$RID.ndjson"
[ "$RC" -eq 0 ] && [ -f "$HH/setup-done" ] && ok "B: a failed plugin install does not stop setup (fail-open): exit 0, marker written" \
  || bad "B: setup stopped on a failed install (rc=$RC)"
grep -q 'install failed, continuing without superpowers@claude-plugins-official' "$WORK/err.txt" \
  && ok "B: stderr says: install failed, continuing without superpowers@claude-plugins-official" \
  || bad "B: failure not on stderr: $(tr '\n' ' ' < "$WORK/err.txt" | head -c 300)"
[ "$(summ "$R" 2>&1 | sed -n 2p)" = "plugin|superpowers@claude-plugins-official|failed|unknown|$OFF" ] \
  && ok "B: the receipt records result=failed for it" || bad "B: failed install not in receipt: $(summ "$R" 2>&1 | tr '\n' ';')"
[ "$(field "$R" 1 note)" = "install failed, continuing without superpowers@claude-plugins-official" ] \
  && ok "B: the receipt line carries: install failed, continuing without <name>" || bad "B: receipt note: $(field "$R" 1 note)"
[ "$(summ "$R" 2>&1 | wc -l | tr -d ' ')" = "3" ] && ok "B: the marketplace add after it was still attempted and receipted (3 lines)" \
  || bad "B: expected 3 receipt lines"

# ╔═ C. prompt-driven preinstall: same 8 plugins, listed marketplace only ═══════════════╗
# Run under errexit like the launcher (set -e): a failed install must never abort the launch.
run_fn() {  # $1 run id, $2 function name, $3 prompt ; extra env via FAKE_* in caller
  local rid="$1" fn="$2" prompt="$3"; shift 3
  fake_env "$rid" TPLUG="$TPLUG" WORKD="$WORK/proj" FN="$fn" "$@" bash -c '
    set -euo pipefail
    . "$TPLUG/bin/lib/install-receipt.sh"
    eval "$(sed -n "/^${FN}() {/,/^}/p" "$TPLUG/bin/heimdall")"
    WORK_DIR="$WORKD"; PLUGIN_DIR="$TPLUG"
    "$FN" "$1"
  ' _ "$prompt" </dev/null >"$WORK/fn.out" 2>"$WORK/fn.err"
}
reset_fake; RID="run-c"
run_fn "$RID" preinstall_plugins "react dashboard, docker deploy, sql database, seo, oauth security, rest api, slack bot, mcp server" \
  FAKE_FAIL_RE='^(devops-toolkit|database-toolkit|seo|security-scanner|api-design)$'; RC=$?
R="$HH/receipts/installs-$RID.ndjson"
[ "$RC" -eq 0 ] && ok "C: preinstall survives five failed installs under errexit (fail-open)" || bad "C: preinstall aborted rc=$RC: $(tail -2 "$WORK/fn.err" | tr '\n' ' ')"
ATTEMPTED="$(sed -n 's/^claude plugins install \([^ ]*\).*/\1/p' "$CALLS" | tr '\n' ' ')"
WANT_SET="frontend-design@claude-plugins-official devops-toolkit@claude-plugins-official database-toolkit@claude-plugins-official seo@claude-plugins-official security-scanner@claude-plugins-official api-design@claude-plugins-official slack@claude-plugins-official mcp-server-dev@claude-plugins-official "
[ "$ATTEMPTED" = "$WANT_SET" ] && ok "C: the same 8 plugins are attempted as before — each from the listed marketplace" \
  || bad "C: attempted set changed: $ATTEMPTED"
WANT="$(printf 'marketplace|claude-plugins-official|ok|n/a|%s\nplugin|frontend-design@claude-plugins-official|ok|5.0.7|%s\nplugin|devops-toolkit@claude-plugins-official|failed|unknown|%s\nplugin|database-toolkit@claude-plugins-official|failed|unknown|%s\nplugin|seo@claude-plugins-official|failed|unknown|%s\nplugin|security-scanner@claude-plugins-official|failed|unknown|%s\nplugin|api-design@claude-plugins-official|failed|unknown|%s\nplugin|slack@claude-plugins-official|ok|5.0.7|%s\nplugin|mcp-server-dev@claude-plugins-official|ok|5.0.7|%s' "$OFF" "$OFF" "$OFF" "$OFF" "$OFF" "$OFF" "$OFF" "$OFF" "$OFF")"
GOT="$(summ "$R" 2>&1)"
[ "$GOT" = "$WANT" ] && ok "C: the receipt lists every install of the run (3 ok, 5 failed) plus the one marketplace add" \
  || bad "C: receipt mismatch. got:\n$GOT"
for n in devops-toolkit database-toolkit seo security-scanner api-design; do
  grep -q "install failed, continuing without $n@claude-plugins-official" "$WORK/fn.err" \
    && ok "C: stderr: install failed, continuing without $n" || bad "C: no stderr line for failed $n"
done
[ "$(grep -c 'marketplace add' "$CALLS")" = "1" ] && grep -q "marketplace add $OFF" "$CALLS" \
  && ok "C: exactly one marketplace is ever added — the listed official one; wshobson/agents fallback is gone" \
  || bad "C: unexpected marketplace adds: $(grep 'marketplace add' "$CALLS" | tr '\n' ';')"
grep -rq 'wshobson' "$TPLUG/bin/heimdall" && bad "C: bin/heimdall still names the wshobson marketplace" || ok "C: bin/heimdall no longer names the wshobson marketplace"

# ╔═ D. the Run Receipt lists every install of THAT run, nothing for another run ════════╗
card() {  # $1 = run id ("" = unset)
  local rid_env=()
  [ -n "$1" ] && rid_env=(HMD_RUN_ID="$1")
  env PATH="/usr/bin:/bin:$(dirname "$PY")" HOME="$WORK/fakehome" HEIMDALL_HOME="$HH" ${rid_env[@]+"${rid_env[@]}"} \
    HEIMDALL_RECEIPT_PLAIN=1 HEIMDALL_RECEIPT_WHO="t.test" HEIMDALL_RECEIPT_ORACLE_DIR="$WORK/none" \
    HEIMDALL_RECEIPT_CORPUS_STATUS="$WORK/none/c.md" HEIMDALL_RECEIPT_STUB_JSON="$WORK/none/s.json" \
    HEIMDALL_RECEIPT_POOL_JSON="$WORK/none/p.json" HEIMDALL_RECEIPT_REUSE_DIR="$WORK/none" \
    HEIMDALL_RECEIPT_PONYTAIL="$WORK/none/pt.jsonl" HEIMDALL_RECEIPT_HOLDOUT_JSON="$WORK/none/h.json" \
    "$REPO/bin/summary-card" --receipt "$WORK/proj" 2>&1
}
CARD_OUT="$(card run-c)"
echo "$CARD_OUT" | grep -q 'HEIMDALL RUN RECEIPT' && ok "D: the Run Receipt still renders" || bad "D: no receipt box"
MISSING=""
for n in frontend-design slack mcp-server-dev; do
  echo "$CARD_OUT" | grep -qE "$n@claude-plugins-official +5\.0\.7 · $OFF" || MISSING="$MISSING $n"
done
for n in devops-toolkit database-toolkit seo security-scanner api-design; do
  echo "$CARD_OUT" | grep -q "install failed, continuing without $n@claude-plugins-official · $OFF" || MISSING="$MISSING $n(failed)"
done
echo "$CARD_OUT" | grep -qE "marketplace claude-plugins-official · $OFF" || MISSING="$MISSING marketplace"
[ -z "$MISSING" ] && ok "D: the receipt lists every install — name, version, source marketplace; failures as 'install failed, continuing without <name>'" \
  || bad "D: receipt is missing:$MISSING"
card run-other | grep -q 'frontend-design' && bad "D: another run's receipt leaked these installs" || ok "D: a different run id lists none of them"
card "" | grep -q 'frontend-design' && bad "D: no run id still listed installs" || ok "D: no run id lists none of them"

# ╔═ E. skill auto-install (git clone of a registry repo) is receipted ══════════════════╗
reset_fake; RID="run-e"
run_fn "$RID" discover_skills "design a react dashboard with tailwind" FAKE_GIT_FAIL_RE='ui-ux-pro-max'; RC=$?
R="$HH/receipts/installs-$RID.ndjson"
NCLONE="$(grep -c '^git clone' "$GITCALLS")"
[ "$RC" -eq 0 ] && [ "$NCLONE" -ge 1 ] && ok "E: skill auto-install ran ($NCLONE clone(s)) and survived a failed clone under errexit" \
  || bad "E: discover_skills rc=$RC clones=$NCLONE: $(tail -2 "$WORK/fn.err" | tr '\n' ' ')"
[ "$(summ "$R" 2>&1 | grep -c '^skill|')" = "$NCLONE" ] && ok "E: one receipt line per clone attempt" || bad "E: clone/receipt count differ: $(summ "$R" 2>&1 | tr '\n' ';')"
summ "$R" 2>&1 | grep -q '^skill|ui-ux-pro-max|failed|unknown|' && grep -q 'install failed, continuing without ui-ux-pro-max' "$WORK/fn.err" \
  && ok "E: the failed clone is receipted and reported on stderr" || bad "E: failed skill not surfaced"

# ╔═ F. install.sh's own plugin install ═════════════════════════════════════════════════╗
inst() {  # $1 run id ; remaining = extra env
  local rid="$1"; shift
  fake_env "$rid" HEIMDALL_INSTALL_SOURCE_ONLY=1 "$@" bash -c '
    . "$1/install.sh"
    . "$1/bin/lib/install-receipt.sh"
    rc=0; install_hmd_plugin "$2" "hmd@heimdall" "v9.9.9" || rc=$?
    exit "$rc"
  ' _ "$REPO" "$WORK/plugin" </dev/null >"$WORK/inst.out" 2>"$WORK/inst.err"
}
reset_fake; RID="run-f1"
inst "$RID"; RC=$?; R="$HH/receipts/installs-$RID.ndjson"
[ "$RC" -eq 0 ] && [ "$(summ "$R" 2>&1)" = "plugin|hmd@heimdall|ok|5.0.7|$WORK/plugin" ] && [ "$(field "$R" 0 pin)" = "v9.9.9" ] \
  && ok "F: install.sh receipts hmd@heimdall: source = its own clone, pin = the installer's ref, resolved version" \
  || bad "F: install.sh receipt wrong (rc=$RC): $(summ "$R" 2>&1 | tr '\n' ';') pin=$(field "$R" 0 pin 2>&1)"
reset_fake; RID="run-f2"
inst "$RID" FAKE_FAIL_RE='^hmd$'; RC=$?; R="$HH/receipts/installs-$RID.ndjson"
[ "$RC" -ne 0 ] && grep -q 'install failed, continuing without hmd@heimdall' "$WORK/inst.err" && [ "$(summ "$R" 2>&1 | cut -d'|' -f3)" = "failed" ] \
  && ok "F: a failed hmd@heimdall install is reported on stderr and receipted (the installer then continues)" || bad "F: failure not surfaced (rc=$RC)"
reset_fake; RID="run-f3"; echo "hmd@heimdall" >> "$STATE/installed"
inst "$RID"; RC=$?
! grep -q 'plugins install' "$CALLS" && [ ! -f "$HH/receipts/installs-$RID.ndjson" ] \
  && ok "F: already installed → no install attempted, nothing receipted" || bad "F: an installed plugin was re-installed"

# ╔═ G. hostile error text cannot corrupt the receipt; unlisted marketplace refused ═════╗
reset_fake; RID="run-g"
HOSTILE=$'bad "quote" \\back\ttab \xc3\xa9 {"x":1}'
fake_env "$RID" FAKE_FAIL_RE='.' FAKE_FAIL_MSG="$HOSTILE" TPLUG="$TPLUG" bash -c '
  . "$TPLUG/bin/lib/install-receipt.sh"
  hmd_install_known_plugin evil claude-plugins-official test || true
  hmd_install_known_plugin foo wshobson test || true
' </dev/null >/dev/null 2>"$WORK/g.err"
R="$HH/receipts/installs-$RID.ndjson"
GOT="$(summ "$R" 2>&1)"
echo "$GOT" | grep -q '^plugin|evil@claude-plugins-official|failed|' && ok "G: a hostile failure message leaves every receipt line valid JSON" || bad "G: receipt corrupted: $GOT"
[ "$(field "$R" 1 detail)" = 'bad "quote" \back?tab ?? {"x":1}' ] && ok "G: the detail is stored printable-ASCII, quote- and backslash-escaped" || bad "G: detail: $(field "$R" 1 detail)"
echo "$GOT" | grep -q '^plugin|foo@wshobson|refused|' && ! grep -q 'plugins install foo' "$CALLS" && ! grep -q 'wshobson' "$CALLS" \
  && ok "G: an unlisted marketplace is refused, receipted, and claude is never invoked for it" || bad "G: unlisted marketplace not refused: $GOT"
grep -q 'install failed, continuing without foo@wshobson' "$WORK/g.err" && ok "G: the refusal is reported on stderr" || bad "G: refusal silent"

echo "--------------------------------------------------------------------"
printf 'plugin-install-receipt: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
