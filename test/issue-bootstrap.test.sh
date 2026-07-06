#!/usr/bin/env bash
# test/issue-bootstrap.test.sh — acceptance for the DEPENDENCY-BOOTSTRAP seam
# (bin/lib/issue_bootstrap.py) + its wiring into the issue-resolution loop
# (bin/lib/issue_loop.py). Bug #24, run-11: the ephemeral maintainer produced the
# CORRECT fix but the SI-2 gate ran the repo's ./run_tests.sh with ok=False + an EMPTY
# tail — the container had the image's toolchain but NOT the repo's own deps. The gate
# could not PROVE even a correct fix -> GATE_FAILED, no PR.
#
# Proves, HERMETICALLY (a FAKE pip records the call — no real network, no real install):
#
#   (1) BOOTSTRAP-THEN-EVIDENCE ORDER — a clone with requirements.txt + an acceptance
#       command that DEPENDS on the install having run (./run_tests.sh checks a marker
#       the fake pip writes). The loop pip-installs (fake pip records the call) BEFORE
#       the gate runs, so the evidence goes GREEN and the issue reaches PR_OPEN. This is
#       FALSIFIABLE: if the loop ran the gate WITHOUT bootstrapping first, the marker
#       would be absent -> ./run_tests.sh exits 1 -> GATE_FAILED.
#
#   (2) NO MANIFEST -> NO INSTALL — a clone with no requirements/pyproject/setup makes
#       NO pip call (fake-pip sentinel empty), and the gate still runs (evidence green).
#
#   (3) INSTALL FAILURE -> TOLERANT — a fake pip that EXITS 1 is RECORDED (dep_bootstrap
#       installed=false, reason install-failed) but the loop does NOT crash: the evidence
#       is still attempted and the gate still decides on merit.
#
#   (4) UNIT — bootstrap_dependencies() direct: requirements.txt -> `install -r`,
#       pyproject/setup.py -> `install -e .`, no manifest -> no call, a runner that
#       RAISES -> a recorded reason, never a raised exception (always tolerant).
#
# Mocks in the TEST (a fake pip) are fine; production (issue_bootstrap.py) has no stubs.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-issue-loop"
LIB="$ROOT/bin/lib/issue_bootstrap.py"
LOOP_LIB="$ROOT/bin/lib/issue_loop.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON-shape assertions" >&2; exit 2; }
[ -x "$CMD" ] || { echo "FATAL: $CMD not executable" >&2; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python)"

WORK="$(mktemp -d -t "issue-bootstrap-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

export PYTHONPATH="$ROOT/bin/lib:${PYTHONPATH:-}"

# ── a FAKE pip: records its argv + cwd, honors PIP_MODE (pass|fail), and on a "pass"
#    install TOUCHES a marker in cwd so an evidence command can prove the install ran ──
FAKE_PIP="$WORK/fakepip"
cat > "$FAKE_PIP" <<'PIPEOF'
#!/usr/bin/env bash
# fake pip — records the call, simulates an install by touching a marker in cwd.
{ printf 'cwd=%s\n' "$PWD"; printf 'argv='; printf '%s ' "$@"; printf '\n'; } >> "$PIP_SENTINEL"
if [ "${PIP_MODE:-pass}" = "fail" ]; then
  echo "fake-pip: simulated install failure" >&2
  exit 1
fi
# a real `pip install -r requirements.txt` would land the deps; simulate that with a
# marker the acceptance command checks (proves bootstrap ran BEFORE the gate).
case " $* " in *" install "*) : > "$PWD/.deps_installed" ;; esac
exit 0
PIPEOF
chmod +x "$FAKE_PIP"
export HEIMDALL_PIP_BIN="$FAKE_PIP"

# a throwaway git repo factory (each case gets a clean clone + queue home).
new_repo() {
  # $1 = repo dir. Inits a git repo with a single committed file.
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'module init\n' > "$repo/app.py"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
}

seed_issue() {
  # $1 = repo, $2 = number. Ingests one fixable issue into the repo's queue.
  local repo="$1" num="$2" raw
  raw="$("$PY" -c 'import json,sys; print(json.dumps({"repo":"acme/widget","number":int(sys.argv[1]),"title":"fix the thing","body":"broken","labels":[{"name":"bug"}],"created_at":"2020-06-01T00:00:00Z"}))' "$num")"
  "$ROOT/bin/heimdall-issue-queue" ingest --source github --raw "$raw" --repo "$repo" >/dev/null
}

echo "── (1) BOOTSTRAP-THEN-EVIDENCE: requirements.txt -> pip install -> gate green ──"
R1="$WORK/repo1"; new_repo "$R1"
printf 'somepkg==1.0\n' > "$R1/requirements.txt"
# the acceptance command DEPENDS on the install having run (marker written by fake pip).
cat > "$R1/run_tests.sh" <<'RTEOF'
#!/bin/sh
test -f .deps_installed
RTEOF
chmod +x "$R1/run_tests.sh"
git -C "$R1" add -A && git -C "$R1" commit -qm "add reqs + tests" >/dev/null
export HEIMDALL_HOME="$R1/.heimdall"
export PIP_SENTINEL="$WORK/pip1.log"; : > "$PIP_SENTINEL"
export PIP_MODE=pass
seed_issue "$R1" 1
OUT="$("$CMD" run-once --repo "$R1" --evidence "./run_tests.sh" --print 2>"$WORK/r1.err")" || true
if grep -q 'argv=install -r requirements.txt' "$PIP_SENTINEL"; then
  ok "the loop pip-installed the clone's requirements.txt (fake pip recorded the call)"
else
  bad "no pip install -r requirements.txt was recorded (bootstrap did not fire)"
fi
if printf '%s' "$OUT" | jq -e '.fix.dep_bootstrap.manifest == "requirements.txt" and .fix.dep_bootstrap.installed == true' >/dev/null 2>&1; then
  ok "run result records dep_bootstrap{manifest:requirements.txt, installed:true}"
else
  bad "dep_bootstrap diagnostic missing/incorrect ($(printf '%s' "$OUT" | jq -c '.fix.dep_bootstrap'))"
fi
if printf '%s' "$OUT" | jq -e '.gate.all_passed == true and .state == "PR_OPEN"' >/dev/null 2>&1; then
  ok "evidence ran GREEN after the install -> gate PASS -> PR_OPEN (order proven)"
else
  bad "gate did not pass after bootstrap (state=$(printf '%s' "$OUT" | jq -r '.state'))"
fi
# FALSIFIABILITY: the marker must NOT exist before bootstrap — the evidence's green is
# the install's effect, not a pre-existing file. Prove the marker came from the fake pip.
if grep -q '\.deps_installed' "$PIP_SENTINEL" 2>/dev/null; then :; fi
if [ -f "$R1/.deps_installed" ]; then
  ok "the deps marker was created by the fake pip (evidence green is the install's effect)"
else
  bad "the deps marker is absent — the fake pip install did not run"
fi

echo "── (2) NO MANIFEST -> NO INSTALL (evidence still runs) ────────────────────────"
R2="$WORK/repo2"; new_repo "$R2"   # no requirements/pyproject/setup
export HEIMDALL_HOME="$R2/.heimdall"
export PIP_SENTINEL="$WORK/pip2.log"; : > "$PIP_SENTINEL"
export PIP_MODE=pass
seed_issue "$R2" 2
OUT="$("$CMD" run-once --repo "$R2" --evidence "true" --print 2>"$WORK/r2.err")" || true
if [ ! -s "$PIP_SENTINEL" ]; then
  ok "no manifest -> NO pip call attempted (fake-pip sentinel empty)"
else
  bad "a pip call fired despite no manifest ($(cat "$PIP_SENTINEL"))"
fi
if printf '%s' "$OUT" | jq -e '.fix.dep_bootstrap.attempted == false and .fix.dep_bootstrap.reason == "no-manifest"' >/dev/null 2>&1; then
  ok "dep_bootstrap records attempted=false, reason=no-manifest"
else
  bad "dep_bootstrap did not record the no-manifest outcome ($(printf '%s' "$OUT" | jq -c '.fix.dep_bootstrap'))"
fi
if printf '%s' "$OUT" | jq -e '.gate.all_passed == true and .state == "PR_OPEN"' >/dev/null 2>&1; then
  ok "the gate still ran the evidence with no bootstrap (evidence-independent)"
else
  bad "the gate did not run without a manifest (state=$(printf '%s' "$OUT" | jq -r '.state'))"
fi

echo "── (3) INSTALL FAILURE -> RECORDED, TOLERANT (evidence still attempted) ───────"
R3="$WORK/repo3"; new_repo "$R3"
printf 'somepkg==1.0\n' > "$R3/requirements.txt"
git -C "$R3" add -A && git -C "$R3" commit -qm reqs >/dev/null
export HEIMDALL_HOME="$R3/.heimdall"
export PIP_SENTINEL="$WORK/pip3.log"; : > "$PIP_SENTINEL"
export PIP_MODE=fail   # the fake pip exits 1
seed_issue "$R3" 3
OUT="$("$CMD" run-once --repo "$R3" --evidence "true" --print 2>"$WORK/r3.err")" || true
if grep -q 'argv=install -r requirements.txt' "$PIP_SENTINEL"; then
  ok "the failing install WAS attempted (fake pip recorded the call)"
else
  bad "the install was not attempted on a failure-mode run"
fi
if printf '%s' "$OUT" | jq -e '.fix.dep_bootstrap.attempted == true and .fix.dep_bootstrap.installed == false and .fix.dep_bootstrap.reason == "install-failed"' >/dev/null 2>&1; then
  ok "dep_bootstrap records the failure honestly (attempted, installed=false, install-failed)"
else
  bad "dep_bootstrap did not record the install failure ($(printf '%s' "$OUT" | jq -c '.fix.dep_bootstrap'))"
fi
if printf '%s' "$OUT" | jq -e '.state == "PR_OPEN" and .gate.all_passed == true' >/dev/null 2>&1; then
  ok "a pip failure did NOT crash the loop — the evidence was still attempted (tolerant)"
else
  bad "a pip failure broke the loop (state=$(printf '%s' "$OUT" | jq -r '.state'))"
fi

echo "── (4) UNIT — bootstrap_dependencies() manifest detection + tolerance ─────────"
UNIT_OUT="$("$PY" - "$WORK" <<'PYEOF'
import os, sys, json
import issue_bootstrap as ib

work = sys.argv[1]
calls = []


def rec_runner(argv, repo):
    calls.append(argv)
    return 0, "ok"


def make_repo(name, files):
    d = os.path.join(work, "unit-" + name)
    os.makedirs(d, exist_ok=True)
    for fn, body in files.items():
        with open(os.path.join(d, fn), "w") as fh:
            fh.write(body)
    return d


results = {}

# requirements.txt -> install -r
r = make_repo("req", {"requirements.txt": "pkg==1.0\n"})
calls.clear()
res = ib.bootstrap_dependencies(r, runner=rec_runner)
results["req"] = {"res": res, "argv": list(calls)}

# pyproject.toml -> install -e .
r = make_repo("pyproj", {"pyproject.toml": "[project]\nname='x'\n"})
calls.clear()
res = ib.bootstrap_dependencies(r, runner=rec_runner)
results["pyproj"] = {"res": res, "argv": list(calls)}

# setup.py -> install -e .
r = make_repo("setup", {"setup.py": "from setuptools import setup\n"})
calls.clear()
res = ib.bootstrap_dependencies(r, runner=rec_runner)
results["setup"] = {"res": res, "argv": list(calls)}

# no manifest -> no call
r = make_repo("none", {"README.md": "hi\n"})
calls.clear()
res = ib.bootstrap_dependencies(r, runner=rec_runner)
results["none"] = {"res": res, "argv": list(calls)}

# a runner that RAISES OSError -> tolerant (recorded, never raised)
def boom(argv, repo):
    raise OSError("kaboom")

r = make_repo("boom", {"requirements.txt": "pkg\n"})
try:
    res = ib.bootstrap_dependencies(r, runner=boom)
    results["boom"] = {"res": res, "raised": False}
except Exception as exc:  # noqa: BLE001
    results["boom"] = {"raised": True, "exc": str(exc)}

print(json.dumps(results))
PYEOF
)"
assert_json() { # $1 = jq filter, $2 = label
  if printf '%s' "$UNIT_OUT" | jq -e "$1" >/dev/null 2>&1; then ok "$2"; else bad "$2 :: $UNIT_OUT"; fi
}
assert_json '.req.res.manifest == "requirements.txt" and (.req.argv[0] | index("install")) and (.req.argv[0] | index("-r"))' \
  "requirements.txt -> pip install -r requirements.txt"
assert_json '.pyproj.res.manifest == "pyproject.toml" and (.pyproj.argv[0] | index("install")) and (.pyproj.argv[0] | index("-e"))' \
  "pyproject.toml -> pip install -e ."
assert_json '.setup.res.manifest == "setup.py" and (.setup.argv[0] | index("-e"))' \
  "setup.py -> pip install -e ."
assert_json '.none.res.attempted == false and .none.res.reason == "no-manifest" and (.none.argv | length == 0)' \
  "no manifest -> attempted=false, no pip call"
assert_json '.boom.raised == false and .boom.res.reason == "install-error"' \
  "a runner OSError is recorded (reason install-error), NEVER raised (tolerant)"

echo
echo "── grep: the loop wires bootstrap BEFORE attest (soft-import + call) ──────────"
if grep -q 'import issue_bootstrap' "$LOOP_LIB" \
   && grep -q 'bootstrap_dependencies' "$LOOP_LIB"; then
  ok "issue_loop soft-imports issue_bootstrap and calls bootstrap_dependencies"
else
  bad "issue_loop does not wire the dependency bootstrap"
fi
# the call must precede the attest() call in run_once (bootstrap BEFORE the gate).
BOOT_LN="$(grep -n 'bootstrap_dependencies(repo)' "$LOOP_LIB" | head -1 | cut -d: -f1)"
ATTEST_LN="$(grep -n 'record = attest(repo' "$LOOP_LIB" | head -1 | cut -d: -f1)"
if [ -n "$BOOT_LN" ] && [ -n "$ATTEST_LN" ] && [ "$BOOT_LN" -lt "$ATTEST_LN" ]; then
  ok "bootstrap_dependencies is called BEFORE attest() in run_once (deps ready for the gate)"
else
  bad "bootstrap is not ordered before attest (boot=$BOOT_LN attest=$ATTEST_LN)"
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "issue-bootstrap: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — the ephemeral maintainer bootstraps a clone's deps (pip install -r / -e .)"
echo "BEFORE the SI-2 gate runs, tolerantly; a correct fix's tests can now be PROVEN (bug #24)."
