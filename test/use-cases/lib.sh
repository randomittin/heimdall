#!/usr/bin/env bash
# test/use-cases/lib.sh -- the harness every journey in test/use-cases/journeys/ sources. SOURCED, never run.
#
# A journey is one thing a person comes to hmd to get done, walked through the PUBLIC door they use (`install.sh`, `hmd ...`, `git commit` in a repo
# `hmd init` wired), with real code end to end. Fakes sit only where hmd stops: the `claude` binary, the macOS keychain (`security`), and the network
# (the installer clones from a local snapshot, the control plane is a dead port, pip is never needed). Nothing here reads or writes the operator's
# HOME, ~/.heimdall, ~/.claude or keychain: every run is `env -i` with a HOME of its own under one private temp root that is removed on exit.
#
# What a journey gets:
#   uc_begin NAME            private temp root (test/lib/private-tmp.sh), counters, tool checks
#   uc_tree                  UC_TREE = the tree under test: a git snapshot of THIS checkout (tracked + untracked files, uncommitted edits included),
#                            or the one the runner hands over (the mutants are snapshots with one line broken). Read-only to a journey.
#   uc_fakebin               fake `claude` and `security` that only record what they were asked, plus a shim-free python3
#   uc_sandbox NAME          UC_HOME and UC_WORK: a fresh HOME and a working directory
#   uc_run HOME CWD [VAR=val ...] -- cmd args...    run in `env -i` with no tty, stdin /dev/null, a hang watchdog; sets UC_RC, UC_OUT, UC_ERR
#   uc_install HOME CWD      the real install.sh, from the tree under test
#   uc_ok / uc_bad / uc_finish   the verdict: a journey is green only when it made checks and none failed
#
# Bash 3.2 (macOS /bin/bash) compatible: no associative arrays, no mapfile, no ${var,,}.
# shellcheck disable=SC2034  # the UC_* variables are this library's interface; the journeys that source it read them

UC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UC_REPO="$(cd "$UC_LIB_DIR/../.." && pwd -P)"
UC_PASS=0
UC_FAIL=0
UC_TIMEOUT_S="${UC_TIMEOUT_S:-240}"   # a hang detector, never a speed assertion: no check depends on how fast a step ran

uc_ok()  { UC_PASS=$((UC_PASS + 1)); printf '  PASS %s\n' "$1"; }
uc_bad() { UC_FAIL=$((UC_FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '       %s\n' "$2"; return 0; }
uc_fatal() { UC_FAIL=$((UC_FAIL + 1)); printf '  FAIL cannot run this journey: %s\n' "$1"; exit 2; }
uc_need() { local t; for t in "$@"; do command -v "$t" >/dev/null 2>&1 || uc_fatal "$t is required on PATH"; done; }

# uc_finish -- print the verdict line and exit. Zero checks is a failure: a journey that asserted nothing proved nothing.
uc_finish() {
  printf '%s: %d passed, %d failed\n' "${UC_NAME:-journey}" "$UC_PASS" "$UC_FAIL"
  if [ "$UC_FAIL" -eq 0 ] && [ "$UC_PASS" -gt 0 ]; then exit 0; fi
  exit 1
}

# uc_begin NAME -- one private temp root for the whole journey (everything mktemp, TMPDIR and python tempfile make lands in it) and the tool paths.
uc_begin() {
  UC_NAME="$1"
  uc_need git jq perl python3 shasum
  # shellcheck source=../lib/private-tmp.sh
  . "$UC_REPO/test/lib/private-tmp.sh" && hmd_private_tmp "uc-$UC_NAME" || exit 2
  UC_ROOT="$HMD_PRIVATE_TMP"
  UC_TMP="$UC_ROOT/tmp"
  UC_BIN="$UC_ROOT/bin"
  UC_CLAUDE_LOG="$UC_ROOT/claude.log"
  UC_SECURITY_LOG="$UC_ROOT/security.log"
  mkdir -p "$UC_TMP" "$UC_BIN"
  : > "$UC_CLAUDE_LOG"
  : > "$UC_SECURITY_LOG"
  UC_PY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
  [ -x "$UC_PY" ] || uc_fatal "cannot resolve the python3 interpreter"
}

# uc_need_crypto -- the Ed25519 backend must already be importable: otherwise install.sh would pip-install it, over the network.
uc_need_crypto() {
  "$UC_PY" -I -c 'from cryptography.hazmat.primitives.asymmetric import ed25519' >/dev/null 2>&1 \
    || uc_fatal "the python3 on PATH ($UC_PY) has no 'cryptography' module: install.sh would pip-install it over the network"
}

# uc_need_node -- the attack engine runs on node. Resolves the real binary (an nvm shell function is not one).
uc_need_node() {
  local n
  n="$(bash -lc 'command -v node' 2>/dev/null || true)"
  case "$n" in /*) ;; *) n="$(command -v node 2>/dev/null || true)" ;; esac
  case "$n" in /*) ;; *) uc_fatal "node is required (the attack engine runs on it)" ;; esac
  UC_NODE_DIR="$(cd "$(dirname "$n")" && pwd)"
}

# uc_snapshot DEST -- a one-commit git repo holding the tracked and untracked-not-ignored files of this checkout as they are on disk right now,
# tagged v<VERSION>: what install.sh clones and what `hmd version` resolves. A copy, so no journey can write into the developer's tree.
uc_snapshot() {
  local dest="$1" list ver f
  mkdir -p "$dest" || return 1
  list="$dest.files"
  : > "$list"
  while IFS= read -r -d '' f; do
    if [ -e "$UC_REPO/$f" ] || [ -L "$UC_REPO/$f" ]; then printf '%s\n' "$f" >> "$list"; fi
  done < <(git -C "$UC_REPO" ls-files -z --cached --others --exclude-standard)
  [ -s "$list" ] || return 1
  tar -C "$UC_REPO" -cf - -T "$list" | tar -C "$dest" -xf - || return 1
  rm -f "$list"
  ver="$(cat "$dest/VERSION" 2>/dev/null || echo 0.0.0)"
  git -c core.hooksPath=/dev/null -C "$dest" init -q || return 1
  git -C "$dest" add -A -f || return 1   # -f: a file the checkout tracks although .gitignore names it is still part of the tree
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=use-case@example.invalid -c user.name=use-case \
    -C "$dest" commit -q --no-verify -m "use-case snapshot of the checkout" || return 1
  git -c tag.gpgsign=false -C "$dest" tag "v$ver"
}

# uc_tree -- fix UC_TREE (the runner exports one; a journey run on its own snapshots the checkout) and UC_REF, the tag the installer is pinned to.
uc_tree() {
  if [ -z "${UC_TREE:-}" ]; then
    UC_TREE="$UC_ROOT/tree"
    uc_snapshot "$UC_TREE" || uc_fatal "could not snapshot the checkout $UC_REPO"
  fi
  [ -f "$UC_TREE/install.sh" ] && [ -x "$UC_TREE/bin/heimdall" ] || uc_fatal "UC_TREE ($UC_TREE) is not an hmd tree"
  UC_VERSION="$(cat "$UC_TREE/VERSION")"
  UC_REF="v$UC_VERSION"
  UC_SHA="$(git -C "$UC_TREE" rev-parse HEAD)"
}

# uc_fakebin -- the two external boundaries, as recording doubles first on every sandbox PATH, and the real interpreter under its everyday name.
#   claude    answers --version, accepts `plugins ...`, answers a headless -p with one result; every call is logged to $UC_CLAUDE_LOG
#   security  the macOS keychain CLI: logs the call and says "item not found"; a journey asserts the log stayed empty
uc_fakebin() {
  cat > "$UC_BIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "${UC_CLAUDE_LOG:-/dev/null}"
case "${1:-}" in
  --version) echo "2.1.323 (Claude Code)"; exit 0 ;;
  plugin|plugins) exit 0 ;;
esac
for a in "$@"; do
  if [ "$a" = "-p" ]; then
    echo '{"type":"result","subtype":"success","result":"fake claude finished the task","session_id":"fake-session","total_cost_usd":0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
  fi
done
exit 0
EOF
  cat > "$UC_BIN/security" <<'EOF'
#!/usr/bin/env bash
echo "security $*" >> "${UC_SECURITY_LOG:-/dev/null}"
exit 44
EOF
  chmod +x "$UC_BIN/claude" "$UC_BIN/security"
  ln -sf "$UC_PY" "$UC_BIN/python3"
  local gitdir jqdir
  gitdir="$(cd "$(dirname "$(command -v git)")" && pwd)"
  jqdir="$(cd "$(dirname "$(command -v jq)")" && pwd)"
  UC_PATH="$UC_BIN:$gitdir:$jqdir${UC_NODE_DIR:+:$UC_NODE_DIR}:/usr/bin:/bin:/usr/sbin:/sbin"
}

# uc_sandbox NAME -- a fresh HOME and a working directory for one scenario inside the journey.
uc_sandbox() {
  UC_HOME="$UC_ROOT/$1/home"
  UC_WORK="$UC_ROOT/$1/work"
  mkdir -p "$UC_HOME" "$UC_WORK"
}

# uc_run HOME CWD [VAR=value ...] -- cmd args...
# Runs cmd from CWD in a scrubbed environment: no tty (stdin /dev/null), stdout and stderr kept apart in UC_OUT and UC_ERR, the status in UC_RC (142 = the
# hang watchdog fired). The environment holds what a stranger's shell would plus the switches that keep hmd off the network and off the machine's own state.
uc_run() {
  local home="$1" cwd="$2"; shift 2
  local extra=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "$#" -eq 0 ] || shift
  UC_OUT="$UC_ROOT/last.out"
  UC_ERR="$UC_ROOT/last.err"
  (
    cd "$cwd" || exit 97
    exec perl -e 'alarm shift; exec @ARGV or exit 127' "$UC_TIMEOUT_S" \
      env -i HOME="$home" TERM=dumb PATH="$UC_PATH" TMPDIR="$UC_TMP" \
      XDG_CACHE_HOME="$UC_TMP/.cache" UV_CACHE_DIR="$UC_TMP/.cache/uv" PIP_CACHE_DIR="$UC_TMP/.cache/pip" \
      UC_CLAUDE_LOG="$UC_CLAUDE_LOG" UC_SECURITY_LOG="$UC_SECURITY_LOG" \
      HMD_MIN_FREE_PCT=0 HEIMDALL_NO_COLOR=1 HEIMDALL_NO_DREAM_SCHEDULE=1 HEIMDALL_NO_AUTOUPDATE=1 HEIMDALL_NO_MODULES=1 \
      HEIMDALL_NO_UPDATE_CHECK=1 HEIMDALL_NO_TEAM_AUTOSHARE=1 HEIMDALL_NO_REUSE_METRIC=1 HEIMDALL_DEFAULT_CP_URL=http://127.0.0.1:9 \
      PYTHONDONTWRITEBYTECODE=1 GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 \
      ${extra[@]+"${extra[@]}"} "$@"
  ) </dev/null >"$UC_OUT" 2>"$UC_ERR"
  UC_RC=$?
}

# uc_install HOME CWD [VAR=value ...] -- the real installer, from the tree under test, into HOME. The checkout is the only source: HEIMDALL_REPO is a
# local path, so the one network call of a real install (the clone) never leaves the machine.
uc_install() {
  local home="$1" cwd="$2"; shift 2
  uc_run "$home" "$cwd" HEIMDALL_REPO="$UC_TREE" HEIMDALL_REF="$UC_REF" ${1+"$@"} -- bash "$UC_TREE/install.sh"
}

# uc_hang LABEL -- fail loudly when the last run was killed by the watchdog; returns 0 when it hung (the caller then skips its other checks).
uc_hang() {
  if [ "$UC_RC" -eq 142 ]; then uc_bad "$1: hung (killed by the watchdog after ${UC_TIMEOUT_S}s)"; return 0; fi
  return 1
}

# uc_rc LABEL WANT -- the last run's exit status is WANT.
uc_rc() {
  if uc_hang "$1"; then return 0; fi
  if [ "$UC_RC" -eq "$2" ]; then uc_ok "$1 (exit $2)"; else uc_bad "$1 (exit $UC_RC, wanted $2)" "$(head -c 400 "$UC_ERR" | LC_ALL=C tr '\n' ' ')"; fi
}

# uc_has LABEL FILE REGEX / uc_lacks LABEL FILE REGEX -- FILE matches (or does not match) the extended regex.
uc_has()   { if grep -Eq -- "$3" "$2" 2>/dev/null; then uc_ok "$1"; else uc_bad "$1" "no match for /$3/ in $(basename "$2"): $(head -c 300 "$2" 2>/dev/null | LC_ALL=C tr '\n' ' ')"; fi; }
uc_lacks() { if grep -Eq -- "$3" "$2" 2>/dev/null; then uc_bad "$1" "unexpected match for /$3/ in $(basename "$2")"; else uc_ok "$1"; fi; }

# uc_jq LABEL FILTER FILE -- the jq filter is true on FILE.
uc_jq() { if jq -e "$2" "$3" >/dev/null 2>&1; then uc_ok "$1"; else uc_bad "$1" "jq $2 on: $(head -c 300 "$3" 2>/dev/null | LC_ALL=C tr '\n' ' ')"; fi; }

# uc_manifest DIR -- every path and file hash under DIR: equal before and after means nothing changed.
uc_manifest() { ( cd "$1" && { find . -print | LC_ALL=C sort; find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort -k2; } ) 2>/dev/null; }
