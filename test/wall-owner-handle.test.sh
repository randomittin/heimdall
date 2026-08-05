#!/usr/bin/env bash
# wall-owner-handle — Row1 names the owner by the handle the WORLD knows him by.
#
# The header read `⛭ HEIMDALL │ rj · Opus`. `rj` is a local git-config nickname; the
# person is `randomittin` on GitHub, which is the name every teammate, every commit on
# the remote and every roster row already uses. On the launch screenshot the owner was
# therefore introduced under a name that appears nowhere else in the product.
#
# The identity was never missing — bin/lib/repo_roster.py resolves it in
# local_github_login() (git config -> HAID -> `gh api user`, cached, negatively cached).
# So the rule this locks down is REUSE: there is exactly ONE answer to "who am I", and
# the statusline asks the roster for it rather than growing a second, divergent chain.
#
# The other half is that this runs on the HOT PATH — every keystroke. So it must be a
# CACHE READ: no `gh`, no probe, no detached refresh fork. And it must degrade rather
# than blank: no gh installed, not authenticated, offline, rate-limited, or a cold cache
# all fall back to the handle the header showed before.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCHMAN="$REPO/sentinels/hmd-statusline.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/cache"; mkdir -p "$CACHE"
PROJ="$TMP/proj"; mkdir -p "$PROJ/.heimdall"

BLOB='{"workspace":{"current_dir":"'"$PROJ"'"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":0},"session_id":"owner-handle-probe"}'

# A PATH whose `gh` is a tripwire: if the render shells out to GitHub, it leaves a file.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\ntouch "%s/gh-was-called"\nexit 1\n' "$TMP" > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

render() {
  printf '%s' "$BLOB" | env COLUMNS=120 \
    PATH="$TMP/bin:$PATH" \
    HMD_ROSTER_CACHE_DIR="$CACHE" \
    HMD_HAID="haid:rj.probe-box" \
    HEIMDALL_HOME="$TMP/home" \
    HMD_STATUSLINE_TMP="$TMP/sltmp" \
    "$@" python3 "$WATCHMAN" --no-color 2>/dev/null | sed -n '1p'
}

# ── 1. the GitHub login reaches Row1 ──────────────────────────────────────────
row1="$(render HMD_ROSTER_SELF_LOGIN=randomittin)"
case "$row1" in
  *randomittin*) ok ;;
  *) bad "Row1 does not carry the GitHub handle: [$row1]" ;;
esac

# ── 2. HOT PATH — resolving it must not shell out to gh ───────────────────────
if [ -e "$TMP/gh-was-called" ]; then
  bad "the render shelled out to gh — the hot path must be a cache read only"
else
  ok
fi

# ── 3. HOT PATH — nor fork the detached roster refresh ────────────────────────
if [ -e "$CACHE/.repo-roster-refresh.lock" ]; then
  bad "the render spawned the roster refresh child — cache reads only on the hot path"
else
  ok
fi

# ── 4. DEGRADE: no gh / unauthenticated / offline / rate-limited → the old handle,
#      never a blank. HMD_ROSTER_NO_GITHUB is exactly the no-signal case.
row1="$(render HMD_ROSTER_NO_GITHUB=1)"
case "$row1" in
  ""|*"HEIMDALL"*) : ;;
  *) bad "the degraded render lost its Row1 entirely: [$row1]" ;;
esac
case "$row1" in
  *HEIMDALL*) ok ;;
  *) bad "no-github degraded to a BLANK Row1: [$row1]" ;;
esac
case "$row1" in
  *randomittin*) bad "no-github still produced a GitHub handle — the signal is fabricated" ;;
  *) ok ;;
esac

# ── 5. DEGRADE: an EMPTY resolution (authenticated as nobody) is not a name ────
row1="$(render HMD_ROSTER_SELF_LOGIN=)"
case "$row1" in
  *HEIMDALL*) ok ;;
  *) bad "an empty login blanked Row1: [$row1]" ;;
esac
# The identity segment must still name SOMEBODY — the fallback handle, not an empty gap.
case "$row1" in
  *"HEIMDALL │ "*|*"HEIMDALL | "*) ok ;;
  *) bad "the identity segment vanished when the login was empty: [$row1]" ;;
esac

# ── 6. ONE RESOLVER. The statusline must ASK the roster, never re-derive. A second
#      chain here is how the header and the roster start disagreeing about who you are.
if grep -q 'local_github_login' "$WATCHMAN"; then ok
else bad "the statusline does not call local_github_login — it grew its own resolver"; fi
# Checked on the SYNTAX TREE, not on the text: a file that documents why it refuses to
# shell out to `gh` necessarily mentions `gh`, and a grep cannot tell that sentence from
# the code it forbids. The AST can — it only ever sees real argv literals.
argv="$(python3 - "$WATCHMAN" <<'PY' 2>&1
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
hits = []
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    for arg in list(node.args) + [k.value for k in node.keywords]:
        if not isinstance(arg, (ast.List, ast.Tuple)) or not arg.elts:
            continue
        head = arg.elts[0]
        if isinstance(head, ast.Constant) and isinstance(head.value, str):
            exe = head.value.rsplit("/", 1)[-1]
            if exe == "gh":
                hits.append("line %d" % node.lineno)
print("gh_argv=%s" % (",".join(hits) if hits else "none"))
PY
)"
case "$argv" in
  *"gh_argv=none"*) ok ;;
  *) bad "the statusline builds its own gh argv ($argv) — that is the second resolution path" ;;
esac

# ── 7. the roster keeps its OWN behaviour: by default it still warms the cache. The
#      read-only mode is an addition for the hot path, not a change of the default.
probe="$(python3 - "$REPO" "$TMP" <<'PY' 2>&1
import sys, os, importlib.util as u
repo, tmp = sys.argv[1], sys.argv[2]
spec = u.spec_from_file_location("rr", repo + "/bin/lib/repo_roster.py")
rr = u.module_from_spec(spec); spec.loader.exec_module(rr)
cold = os.path.join(tmp, "cold"); os.makedirs(cold, exist_ok=True)
os.environ.pop("HMD_ROSTER_SELF_LOGIN", None)
os.environ["HMD_ROSTER_CACHE_DIR"] = cold
# spawn=False on a COLD cache must return the empty answer WITHOUT forking a refresh.
rr.local_github_login(repo, cache_dir=cold, spawn=False)
print("readonly_forked=%s" % ("yes" if os.path.exists(
    os.path.join(cold, ".repo-roster-refresh.lock")) else "no"))
# the DEFAULT is unchanged: a cold cache still warms itself in the background.
rr.local_github_login(repo, cache_dir=cold)
print("default_forked=%s" % ("yes" if os.path.exists(
    os.path.join(cold, ".repo-roster-refresh.lock")) else "no"))
PY
)"
case "$probe" in
  *"readonly_forked=no"*) ok ;;
  *) bad "spawn=False still forked the refresh child ($probe)" ;;
esac
case "$probe" in
  *"default_forked=yes"*) ok ;;
  *) bad "the DEFAULT no longer warms a cold cache — read-only mode changed the default ($probe)" ;;
esac

printf '\n  %s%d passed, %d failed\033[0m\n' \
  "$([ "$FAIL" -eq 0 ] && printf '\033[32m' || printf '\033[31m')" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
