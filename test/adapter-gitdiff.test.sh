#!/usr/bin/env bash
# test/adapter-gitdiff.test.sh — the `gitdiff` adapter (RP9): start/events/claim over a diff, the
# spec grammar `hmd attack --diff` speaks, and the end-to-end `hmd attack --diff` path.
#
# This file tests ONE adapter. The contract every adapter must meet is proven separately and
# independently in test/adapter-conformance.test.sh; nothing here redefines it.
#
# WHAT THIS PROVES
#   [A] ADAPTER  patch / patch_file / head sources each yield a done claim whose diff is the change,
#                with the head_sha rule (a commit only when one exists), framed events and a repo left
#                byte-for-byte alone.
#   [B] REFUSALS garbage, empty, non-applying, path-escaping, .git-touching, oversized and ambiguous
#                inputs are typed AdapterErrors, never a raw exception, never a file outside the temp tree.
#   [C] EXPORT   the base tree is the COMMITTED bytes: a repo that marks files `export-ignore` still gets
#                patches to those files applied (git archive would have dropped them).
#   [D] SPEC     task_for_spec: patch file | A..B | A...B | - (stdin), resolved to full shas.
#   [E] CLI      `hmd attack --diff` end to end: DENIED / PROVEN with target.kind=diff, head_sha, the
#                subdirectory form, patch file, stdin, and the exit-2 refusals.
#
# Hermetic: HEIMDALL_HOME, TMPDIR and every repo live in a throwaway dir; no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HMD="$REPO/bin/hmd"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

for tool in git python3 jq node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool required" >&2; exit 2; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adapter-gitdiff-test-XXXXXX")"
TMP="$(cd "$TMP" && pwd)"   # TMPDIR often ends in a slash: compare paths in their normalised form
trap 'rm -rf "$TMP"' EXIT
export HEIMDALL_HOME="$TMP/home"; mkdir -p "$HEIMDALL_HOME"
export HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1
touch "$HEIMDALL_HOME/setup-done"
mkdir -p "$TMP/stubbin"; printf '#!/bin/sh\nexit 0\n' >"$TMP/stubbin/claude"; chmod +x "$TMP/stubbin/claude"
export PATH="$TMP/stubbin:$PATH"
export HEIMDALL_TRACE_ORDER="$TMP/trace.order"; : >"$HEIMDALL_TRACE_ORDER"
# Adapter temp dirs land here, so a leak or an escape is observable.
export TMPDIR="$TMP/adapter-tmp"; mkdir -p "$TMPDIR"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# git in a fixture repo: fixed identity, no hooks, no signing
g() { local d="$1"; shift; git -C "$d" -c user.name=fixture -c user.email=fixture@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
commit_all() { g "$1" add -A >/dev/null && g "$1" commit -q -m "$2"; }
sha() { g "$1" rev-parse "$2"; }
# the first $2 names (not paths) left in dir $1, for a failure message
leftovers() { find "$1" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | head -n "$2" | tr '\n' ' '; }

# ── fixture repo W: commit 1 = a clean settlement webhook, commit 2 = the buggy one ──────────────
W="$TMP/w"; mkdir -p "$W"; git -C "$W" init -q
cp "$REPO/fixtures/attack/clean-sample/"* "$W/"
commit_all "$W" "clean"
C1="$(sha "$W" HEAD)"
cp "$REPO/fixtures/attack/buggy-webhook/webhook.mjs" "$W/webhook.mjs"
commit_all "$W" "buggy"
C2="$(sha "$W" HEAD)"
g "$W" diff --binary --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$C1" "$C2" >"$TMP/c1-c2.patch"
g "$W" diff --binary --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$C2" "$C1" >"$TMP/c2-c1.patch"
if [ -s "$TMP/c1-c2.patch" ]; then ok "fixture: the clean->buggy patch is non-empty"; else bad "fixture patch empty"; fi

# drive '<task json>' -> DOUT: start, events, claim in one go (or the AdapterError as {error,detail})
cat >"$TMP/drive.py" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["HMD_REPO"])
from adapters import gitdiff, AdapterError
task = json.loads(sys.argv[1])
try:
    run_id = gitdiff.start(task)
    out = {"run_id": run_id, "events": list(gitdiff.events(run_id)), "claim": gitdiff.claim(run_id)}
except AdapterError as exc:
    out = {"error": exc.kind, "detail": exc.detail}
print(json.dumps(out))
PY
export HMD_REPO="$REPO"
drive() { DOUT="$(python3 "$TMP/drive.py" "$1" 2>"$TMP/drive.err")"; DRC=$?; }
task() {  # task <repo> <base> <options-json>
  jq -cn --arg repo "$1" --arg base "$2" --argjson opts "$3" '{id:"t-1", prompt:"fix the webhook", repo:$repo, base_sha:$base, options:$opts}'
}

# ══════════════════════════════════════════════════════════════════════════════
# [A] the adapter on each source
# ══════════════════════════════════════════════════════════════════════════════
echo "[A] gitdiff: patch / patch_file / head"

drive "$(task "$W" "$C1" "$(jq -cn --rawfile p "$TMP/c1-c2.patch" '{gitdiff:{patch:$p}}')")"
if [ "$DRC" -eq 0 ] && jq -e --rawfile p "$TMP/c1-c2.patch" '.claim.claim=="done" and .claim.diff==$p and .claim.head_sha==null' <<<"$DOUT" >/dev/null; then
  ok "patch source: done, the diff is the patch verbatim, head_sha is null (no commit holds a bare patch)"
else bad "patch source wrong (rc=$DRC): $(head -c 300 <<<"$DOUT") $(head -c 200 "$TMP/drive.err")"; fi
if jq -e '(.events|length)>=3 and .events[0].kind=="status" and .events[0].data.state=="started" and .events[-1].kind=="status" and .events[-1].data.state=="done"' <<<"$DOUT" >/dev/null; then
  ok "events: started first, terminal done last, at least one event between"
else bad "event framing wrong: $(jq -c '[.events[]|[.kind,.data.state]]' <<<"$DOUT")"; fi
if jq -e '[.events[]|select(.kind=="test")]|length==0' <<<"$DOUT" >/dev/null; then
  ok "no test events: gitdiff cannot observe the change being tested, so it never invents one"
else bad "gitdiff emitted a test event"; fi
if jq -e '.run_id|test("^gitdiff-[0-9a-f]{12}$")' <<<"$DOUT" >/dev/null; then ok "run id is gitdiff-<12 hex>"; else bad "run id shape: $(jq -r .run_id <<<"$DOUT")"; fi

drive "$(task "$W" "$C1" "$(jq -cn --arg f "$TMP/c1-c2.patch" '{gitdiff:{patch_file:$f}}')")"
if [ "$DRC" -eq 0 ] && jq -e --rawfile p "$TMP/c1-c2.patch" '.claim.claim=="done" and .claim.diff==$p and .claim.head_sha==null' <<<"$DOUT" >/dev/null; then
  ok "patch_file source: same claim as the inline patch"
else bad "patch_file source wrong: $(head -c 300 <<<"$DOUT")"; fi

drive "$(task "$W" "$C1" "$(jq -cn --arg h "$C2" '{gitdiff:{head:$h}}')")"
if [ "$DRC" -eq 0 ] && jq -e --arg h "$C2" '.claim.claim=="done" and .claim.head_sha==$h and (.claim.diff|startswith("diff --git "))' <<<"$DOUT" >/dev/null; then
  ok "head source: done, head_sha is the resolved head commit, the diff is git's own"
else bad "head source wrong: $(head -c 300 <<<"$DOUT")"; fi

drive "$(task "$W" "$C1" "$(jq -cn --arg h "$C2" '{gitdiff:{head:"HEAD"}}')")"
if [ "$DRC" -eq 0 ] && jq -e --arg h "$C2" '.claim.head_sha==$h' <<<"$DOUT" >/dev/null; then
  ok "head given as a ref (HEAD) is resolved to its full sha"
else bad "ref head not resolved: $(head -c 300 <<<"$DOUT")"; fi

drive "$(task "$W" "$C1" "$(jq -cn --arg f "$TMP/c1-c2.patch" '{other:{x:1}, gitdiff:{patch_file:$f}}')")"
if [ "$DRC" -eq 0 ] && jq -e '.claim.claim=="done"' <<<"$DOUT" >/dev/null; then
  ok "options for another adapter are ignored (a task is portable across adapters)"
else bad "foreign options rejected: $(head -c 200 <<<"$DOUT")"; fi

# the repo is left alone and no temp dir is left behind
if [ -z "$(g "$W" status --porcelain)" ] && [ "$(sha "$W" HEAD)" = "$C2" ]; then ok "the caller's repo is untouched (clean status, same HEAD)"; else bad "repo modified"; fi
if [ -z "$(ls -A "$TMPDIR")" ]; then ok "no adapter temp dir is left behind"; else bad "temp dirs leaked: $(leftovers "$TMPDIR" 3)"; fi

# ══════════════════════════════════════════════════════════════════════════════
# [B] refusals: typed errors, nothing escapes
# ══════════════════════════════════════════════════════════════════════════════
echo "[B] gitdiff: refusals are AdapterErrors"

refuse() {  # refuse <description> <options-json> <expected-kind> [base]
  drive "$(task "$W" "${4:-$C1}" "$2")"
  if [ "$DRC" -eq 0 ] && jq -e --arg k "$3" '.error==$k and (.detail|length>0) and (has("claim")|not)' <<<"$DOUT" >/dev/null; then ok "refuses: $1 ($3)"
  else bad "refuses: $1 (want $3, got rc=$DRC $(head -c 250 <<<"$DOUT") $(head -c 200 "$TMP/drive.err"))"; fi
}
refuse "garbage that is not a diff"          '{"gitdiff":{"patch":"this is not a patch\n"}}'                                                bad_diff
refuse "a whitespace-only patch"             '{"gitdiff":{"patch":"  \n\n"}}'                                                               empty_diff
refuse "a patch that does not apply"         "$(jq -cn --rawfile p "$TMP/c2-c1.patch" '{gitdiff:{patch:$p}}')"                             bad_diff
refuse "a patch escaping the tree"           '{"gitdiff":{"patch":"--- /dev/null\n+++ b/../../escape.txt\n@@ -0,0 +1 @@\n+x\n"}}'          bad_diff
refuse "a patch writing into .git"           '{"gitdiff":{"patch":"--- /dev/null\n+++ b/.git/hooks/pre-commit\n@@ -0,0 +1 @@\n+x\n"}}'    bad_diff
refuse "a patch writing through a symlink"   '{"gitdiff":{"patch":"diff --git a/ln b/ln\nnew file mode 120000\n--- /dev/null\n+++ b/ln\n@@ -0,0 +1 @@\n+/tmp\n\\ No newline at end of file\ndiff --git a/ln/z.txt b/ln/z.txt\nnew file mode 100644\n--- /dev/null\n+++ b/ln/z.txt\n@@ -0,0 +1 @@\n+x\n"}}' bad_diff
refuse "no source at all"                    '{}'                                                                                            bad_task
refuse "two sources at once"                 "$(jq -cn --arg f "$TMP/c1-c2.patch" '{gitdiff:{patch:"x", patch_file:$f}}')"                  bad_task
refuse "an unknown key in the gitdiff options" '{"gitdiff":{"head":"HEAD","bogus":1}}'                                                        bad_task
refuse "a patch_file that does not exist"    '{"gitdiff":{"patch_file":"/nonexistent/x.patch"}}'                                            bad_task
refuse "a head that is not in the repo"      '{"gitdiff":{"head":"no-such-ref"}}'                                                            unknown_head
refuse "a head identical to the base (no change)" "$(jq -cn --arg h "$C1" '{gitdiff:{head:$h}}')"                                           empty_diff
HMD_ADAPTER_MAX_DIFF_BYTES=50 refuse "a diff over the size cap" "$(jq -cn --rawfile p "$TMP/c1-c2.patch" '{gitdiff:{patch:$p}}')"          too_large
if [ -z "$(find "$TMP" -name 'escape*.txt' -o -name 'z.txt' | head -1)" ]; then ok "no refused patch wrote a file anywhere under the sandbox"; else bad "a refused patch wrote a file: $(find "$TMP" -name 'escape*.txt' -o -name 'z.txt' | head -2)"; fi
if [ -z "$(ls -A "$TMPDIR")" ]; then ok "refusals leave no adapter temp dir behind"; else bad "temp dirs leaked after refusals: $(leftovers "$TMPDIR" 3)"; fi

# ══════════════════════════════════════════════════════════════════════════════
# [C] the base tree is the committed bytes, not an archive view of them
# ══════════════════════════════════════════════════════════════════════════════
echo "[C] gitdiff: export-ignore does not hide files from the patch"

X="$TMP/x"; mkdir -p "$X/tests" "$X/src"; git -C "$X" init -q
printf 'tests export-ignore\n*.md export-subst\n' >"$X/.gitattributes"
printf 'one\n' >"$X/tests/t.txt"; printf "version \$Format:%%h\$\n" >"$X/src/v.md"
commit_all "$X" "base"
XB="$(sha "$X" HEAD)"
printf 'one\ntwo\n' >"$X/tests/t.txt"; printf "version \$Format:%%h\$\nmore\n" >"$X/src/v.md"
commit_all "$X" "edit"
XH="$(sha "$X" HEAD)"
drive "$(jq -cn --arg repo "$X" --arg base "$XB" --arg h "$XH" '{id:"x-1", prompt:"", repo:$repo, base_sha:$base, options:{gitdiff:{head:$h}}}')"
if [ "$DRC" -eq 0 ] && jq -e '.claim.claim=="done" and (.claim.diff|contains("tests/t.txt")) and (.claim.diff|contains("src/v.md"))' <<<"$DOUT" >/dev/null; then
  ok "a patch touching export-ignore'd and export-subst'd files applies to the exported base"
else bad "export-ignore regression: $(head -c 300 <<<"$DOUT")"; fi

# git apply inside a repository silently skips every path outside its own subdirectory: with the temp
# dir INSIDE a repo, a patch that cannot apply must still be refused, not waved through
mkdir -p "$W/inner-tmp"
OLDTMP="$TMPDIR"; export TMPDIR="$W/inner-tmp"
refuse "a non-applying patch while TMPDIR sits inside a git repository (apply must see a plain directory)" "$(jq -cn --rawfile p "$TMP/c2-c1.patch" '{gitdiff:{patch:$p}}')" bad_diff
drive "$(task "$W" "$C1" "$(jq -cn --rawfile p "$TMP/c1-c2.patch" '{gitdiff:{patch:$p}}')")"
if [ "$DRC" -eq 0 ] && jq -e '.claim.claim=="done"' <<<"$DOUT" >/dev/null; then ok "an applying patch is still accepted with TMPDIR inside a repository"; else bad "TMPDIR-in-repo broke a good patch: $(head -c 200 <<<"$DOUT")"; fi
export TMPDIR="$OLDTMP"; rm -rf "$W/inner-tmp"

# ══════════════════════════════════════════════════════════════════════════════
# [D] the spec grammar
# ══════════════════════════════════════════════════════════════════════════════
echo "[D] gitdiff.task_for_spec: patch | A..B | A...B | -"

cat >"$TMP/spec.py" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["HMD_REPO"])
from adapters import gitdiff, AdapterError
repo, spec = sys.argv[1], sys.argv[2]
try:
    task = gitdiff.task_for_spec(repo, spec, read_stdin=lambda: "STDIN-PATCH\n")
    print(json.dumps(task))
except AdapterError as exc:
    print(json.dumps({"error": exc.kind, "detail": exc.detail}))
PY
spec() { SOUT="$(python3 "$TMP/spec.py" "$1" "$2" 2>"$TMP/spec.err")"; }

spec "$W" "$TMP/c1-c2.patch"
if jq -e --arg base "$C2" --arg f "$TMP/c1-c2.patch" '.base_sha==$base and .options.gitdiff.patch_file==$f and .repo=="'"$W"'"' <<<"$SOUT" >/dev/null; then
  ok "a patch file is applied on top of the repo's HEAD"
else bad "patch-file spec wrong: $SOUT"; fi
spec "$W" "$C1..$C2"
if jq -e --arg b "$C1" --arg h "$C2" '.base_sha==$b and .options.gitdiff.head==$h' <<<"$SOUT" >/dev/null; then
  ok "A..B: base is A, head is B, both full shas"
else bad "range spec wrong: $SOUT"; fi
spec "$W" "HEAD~1..HEAD"
if jq -e --arg b "$C1" --arg h "$C2" '.base_sha==$b and .options.gitdiff.head==$h' <<<"$SOUT" >/dev/null; then
  ok "A..B with refs (HEAD~1..HEAD) resolves to full shas"
else bad "ref range spec wrong: $SOUT"; fi
g "$W" branch -q side "$C1"
spec "$W" "side...HEAD"
if jq -e --arg b "$C1" --arg h "$C2" '.base_sha==$b and .options.gitdiff.head==$h' <<<"$SOUT" >/dev/null; then
  ok "A...B: base is merge-base(A,B)"
else bad "triple-dot spec wrong: $SOUT"; fi
spec "$W" "-"
if jq -e --arg base "$C2" '.base_sha==$base and .options.gitdiff.patch=="STDIN-PATCH\n"' <<<"$SOUT" >/dev/null; then
  ok "'-' reads the patch through the caller's reader, never the process stdin itself"
else bad "stdin spec wrong: $SOUT"; fi
spec "$W" "$TMP/no-such.patch"
if jq -e '.error=="bad_task"' <<<"$SOUT" >/dev/null; then ok "a spec that is neither a file nor a range is bad_task"; else bad "bad spec accepted: $SOUT"; fi
spec "$W" "nope..HEAD"
if jq -e '.error=="bad_task"' <<<"$SOUT" >/dev/null; then ok "a range with an unresolvable side is bad_task"; else bad "bad range accepted: $SOUT"; fi
spec "$TMP" "HEAD~1..HEAD"
if jq -e '.error=="bad_task"' <<<"$SOUT" >/dev/null; then ok "a directory that is not a git repository is bad_task"; else bad "non-repo accepted: $SOUT"; fi

# ══════════════════════════════════════════════════════════════════════════════
# [E] hmd attack --diff, end to end
# ══════════════════════════════════════════════════════════════════════════════
echo "[E] hmd attack --diff"

attack() { AOUT="$TMP/attack.out"; AERR="$TMP/attack.err"; "$HMD" attack "$@" >"$AOUT" 2>"$AERR" </dev/null; ARC=$?; }

attack "$W" --diff "$C1..$C2" --json --yes
if [ "$ARC" -eq 1 ] && jq -e --arg h "$C2" '.verdict=="DENIED" and .target.kind=="diff" and .target.ref=="'"$C1..$C2"'" and .target.head_sha==$h and (.findings|length)>=1 and .agent.name=="none"' "$AOUT" >/dev/null 2>&1; then
  ok "clean->buggy range: DENIED (exit 1), target.kind=diff, ref is the spec, head_sha is the head commit"
else bad "range attack wrong (rc=$ARC): $(head -c 300 "$AOUT") $(head -c 200 "$AERR")"; fi
if jq -e '.findings[0].counterexample.repro_cmd|startswith("hmd attack ") and contains("--diff")' "$AOUT" >/dev/null 2>&1; then
  ok "the finding's repro_cmd reproduces the DIFF attack (it carries --diff), not a path attack"
else bad "repro_cmd wrong: $(jq -r '.findings[0].counterexample.repro_cmd' "$AOUT" 2>/dev/null)"; fi
attack "$W" --diff "$C2..$C1" --json --yes
if [ "$ARC" -eq 0 ] && jq -e '.verdict=="PROVEN" and .target.kind=="diff"' "$AOUT" >/dev/null 2>&1; then
  ok "buggy->clean range: PROVEN (exit 0): the attack grades the change, not the path"
else bad "reverse range wrong (rc=$ARC): $(head -c 300 "$AOUT") $(head -c 200 "$AERR")"; fi

# the candidate is HEAD + patch: the working copy at HEAD (buggy) with the clean patch applied is PROVEN
attack "$W" --diff "$TMP/c2-c1.patch" --json --yes
if [ "$ARC" -eq 0 ] && jq -e '.verdict=="PROVEN" and .target.kind=="diff" and .target.head_sha==null' "$AOUT" >/dev/null 2>&1; then
  ok "patch file on HEAD: PROVEN, head_sha null (a bare patch has no commit)"
else bad "patch-file attack wrong (rc=$ARC): $(head -c 300 "$AOUT") $(head -c 200 "$AERR")"; fi
git -C "$W" checkout -q "$C1"
attack "$W" --diff "$TMP/c1-c2.patch" --json --yes
if [ "$ARC" -eq 1 ] && jq -e '.verdict=="DENIED" and .target.kind=="diff"' "$AOUT" >/dev/null 2>&1; then
  ok "patch file on a clean HEAD introduces the bug: DENIED (exit 1)"
else bad "patch-file DENIED wrong (rc=$ARC): $(head -c 300 "$AOUT") $(head -c 200 "$AERR")"; fi
"$HMD" attack "$W" --diff - --json --yes <"$TMP/c1-c2.patch" >"$TMP/attack.out" 2>"$TMP/attack.err"; ARC=$?
if [ "$ARC" -eq 1 ] && jq -e '.verdict=="DENIED" and .target.ref=="-"' "$TMP/attack.out" >/dev/null 2>&1; then
  ok "--diff - reads the patch from stdin (with --yes): DENIED"
else bad "stdin attack wrong (rc=$ARC): $(head -c 300 "$TMP/attack.out") $(head -c 200 "$TMP/attack.err")"; fi
if [ "$(git -C "$W" rev-parse HEAD)" = "$C1" ] && [ -z "$(g "$W" status --porcelain)" ]; then ok "attacking a diff leaves the caller's repo untouched"; else bad "repo modified by --diff"; fi
git -C "$W" checkout -q "$C2"

# the target may be a subdirectory of the repository
S="$TMP/s"; mkdir -p "$S/svc"; git -C "$S" init -q
cp "$REPO/fixtures/attack/clean-sample/"* "$S/svc/"; commit_all "$S" "clean"; S1="$(sha "$S" HEAD)"
cp "$REPO/fixtures/attack/buggy-webhook/webhook.mjs" "$S/svc/webhook.mjs"; commit_all "$S" "buggy"; S2="$(sha "$S" HEAD)"
attack "$S/svc" --diff "$S1..$S2" --json --yes
if [ "$ARC" -eq 1 ] && jq -e '.verdict=="DENIED" and .target.kind=="diff"' "$AOUT" >/dev/null 2>&1; then
  ok "a subdirectory target: the change is applied to the whole repo, the attack surface is found in svc/"
else bad "subdirectory attack wrong (rc=$ARC): $(head -c 300 "$AOUT") $(head -c 200 "$AERR")"; fi

# refusals
attack "$W" --diff "$TMP/no-such.patch" --yes
if [ "$ARC" -eq 2 ] && grep -q 'no-such.patch' "$AERR"; then ok "--diff with a missing patch file: exit 2 and the error names the file"; else bad "missing patch handling wrong (rc=$ARC): $(head -c 200 "$AERR")"; fi
attack "$W" --diff "$C1..$C2" --batch "$TMP/x.txt" --out "$TMP/o" --yes
if [ "$ARC" -eq 2 ]; then ok "--diff with --batch: exit 2"; else bad "--diff + --batch rc=$ARC"; fi
attack "$TMP" --diff "HEAD~1..HEAD" --yes
if [ "$ARC" -eq 2 ]; then ok "--diff on a directory that is not a git repository: exit 2"; else bad "non-repo --diff rc=$ARC"; fi
attack "$W" --diff "$C1..$C2" --json
if [ "$ARC" -eq 3 ] && jq -e '.error=="consent_required"' "$AOUT" >/dev/null 2>&1; then ok "--diff without --yes on a non-terminal: exit 3 (consent_required), nothing ran"; else bad "consent not required for --diff (rc=$ARC)"; fi
attack "$W" --diff "$C1..$C2" --out "$TMP/out-diff" --json --yes
if [ "$ARC" -eq 1 ] && jq -e '.verdict=="DENIED"' "$TMP/out-diff/verdict.json" >/dev/null 2>&1 && [ -s "$TMP/out-diff/attacks/f-0001.json" ]; then
  ok "--out works with --diff (verdict.json + attacks/f-NNNN.json)"
else bad "--out with --diff wrong (rc=$ARC)"; fi
if [ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 \( -name 'runhmd-diff-*' -o -name 'runhmd-adapter-*' \))" ]; then ok "no candidate checkout or adapter temp dir survives the run"; else bad "temp dirs leaked: $(leftovers "$TMPDIR" 4)"; fi
if [ ! -s "$HEIMDALL_TRACE_ORDER" ]; then ok "nothing fell through to the Claude task-prompt path"; else bad "hmd attack --diff fell through to the launcher: $(cat "$HEIMDALL_TRACE_ORDER")"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
