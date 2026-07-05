#!/usr/bin/env bash
# test/heimdall-deployed-shape-check.test.sh — acceptance for the deployed-shape static
# preflight (bin/heimdall-deployed-shape-check). autoresearch's keep/discard discipline made
# falsifiable: the checker is KEPT only if it MEASURABLY discriminates the historical buggy
# shapes from their fixed forms. If it cannot (no delta), this test FAILS -> DISCARD.
#
# Hermetic: every fixture is a THROWAWAY .py written under a temp dir. No network, no creds,
# no live bin/lib mutation. The falsifier fixtures are reconstructed MINIMAL pre-fix + fixed
# snippets of the saga's incidents 6, 9, 10, 13.
#
# FALSIFIABLE claims proven:
#   (1) COMPILE — the checker is valid python3 (py_compile clean).
#   (2) RULE slug-path   — bug-13 pre-fix (slug joined onto CWD) is flagged; fixed passes.
#   (3) RULE reserved-env — bug-9 pre-fix (PORT/K_* in an env dict) is flagged; fixed passes.
#   (4) RULE state-read  — bug-10 pre-fix (unguarded .maintainer.enabled read) flagged; fixed passes.
#   (5) RULE silent-stderr — bug-6 pre-fix (captured, ignored stderr) is flagged; fixed passes.
#   (6) MEASURED DELTA (the keep gate) — buggy fixture set flags > 0, fixed set flags == 0,
#       so delta > 0. Were the delta 0 (checker cannot discriminate) this assertion FAILS,
#       which is the DISCARD verdict per skills/self-improve/SKILL.md — no keep on vibes.
#   (7) MARKER ALLOWLIST — a '# deployed-shape-ok: <reason>' suppresses an otherwise-flagged site.
#   (8) WARN-ONLY DEFAULT — findings do NOT change the exit code (exit 0) unless --strict.
#   (9) STRICT — --strict exits 1 iff findings exist, 0 when clean (the promotion path).
#  (10) WIRED WARN-ONLY — deploy-arch-b.sh + go-live.sh invoke the checker and never let it block.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHK="$ROOT/bin/heimdall-deployed-shape-check"
ARCHB="$ROOT/deploy/cloud-run/deploy-arch-b.sh"
GOLIVE="$ROOT/deploy/cloud-run/go-live.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BUGGY="$WORK/buggy"; FIXED="$WORK/fixed"; mkdir -p "$BUGGY" "$FIXED"

# count findings via --json (python3 parses its own output).
count() { python3 "$CHK" "$1" --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])'; }
# does the JSON contain a finding with a given rule?
has_rule() { python3 "$CHK" "$1" --json 2>/dev/null | python3 -c 'import json,sys;fs=json.load(sys.stdin)["findings"];print("1" if any(f["rule"]==sys.argv[1] for f in fs) else "0")' "$2"; }

# ── (1) compile ────────────────────────────────────────────────────────────────
python3 -m py_compile "$CHK" && ok "(1) checker py_compile clean" || bad "(1) checker does NOT compile"

# ── falsifier fixtures — reconstructed minimal pre-fix + fixed snippets ─────────
# bug 13 — planning dir from a slug joined onto the read-only CWD (no clone).
cat > "$BUGGY/b13_slug.py" <<'PY'
import os
def planning_dir(repo_slug):
    return os.path.abspath(os.path.join(os.getcwd(), repo_slug))
PY
cat > "$FIXED/b13_slug.py" <<'PY'
import os
def planning_dir(repo_slug, workspace):
    # deployed-shape-ok: clone target is a writable workspace, not the read-only CWD
    return os.path.join(workspace, repo_slug.split("/")[-1])
PY

# bug 9 — reserved Cloud Run env names in the per-execution env override.
cat > "$BUGGY/b09_reserved.py" <<'PY'
import os
def build_env(base):
    env = dict(base)
    env["PORT"] = os.environ["PORT"]
    return {"K_SERVICE": "svc", "K_REVISION": "r1", "TEAM": base.get("TEAM")}
PY
cat > "$FIXED/b09_reserved.py" <<'PY'
RESERVED = {"PORT", "K_SERVICE", "K_REVISION", "K_CONFIGURATION"}
def build_env(base):
    # deployed-shape-ok: reserved Cloud Run names stripped before the RunJob dispatch
    return {k: v for k, v in base.items() if k not in RESERVED}
PY

# bug 10 — unguarded local .maintainer.enabled gate absent in an ephemeral container.
cat > "$BUGGY/b10_state.py" <<'PY'
import os
def maintainer_enabled():
    return os.path.exists(".maintainer.enabled")
PY
cat > "$FIXED/b10_state.py" <<'PY'
import os
def maintainer_enabled():
    if os.environ.get("HEIMDALL_MAINTAINER_ENABLED") == "1":
        return True
    return os.path.exists(os.path.join(os.environ.get("HOME", "/tmp"), ".maintainer.enabled"))
PY

# bug 6 — subprocess stderr captured then dropped (silent task consumption).
cat > "$BUGGY/b06_stderr.py" <<'PY'
import subprocess
def run_task(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0
PY
cat > "$FIXED/b06_stderr.py" <<'PY'
import subprocess, sys
def run_task(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
    return r.returncode == 0
PY

# ── (2)-(5) per-rule: pre-fix flagged, fixed passes ─────────────────────────────
per_rule() { # <name> <buggy.py> <fixed.py> <rule>
  local name="$1" b="$2" f="$3" rule="$4"
  [ "$(has_rule "$b" "$rule")" = "1" ] && ok "($name) pre-fix flagged [$rule]" || bad "($name) pre-fix NOT flagged [$rule]"
  [ "$(count "$f")" = "0" ] && ok "($name) fixed form passes clean" || bad "($name) fixed form still flags"
}
per_rule "2" "$BUGGY/b13_slug.py"     "$FIXED/b13_slug.py"     "slug-path"
per_rule "3" "$BUGGY/b09_reserved.py" "$FIXED/b09_reserved.py" "reserved-env"
per_rule "4" "$BUGGY/b10_state.py"    "$FIXED/b10_state.py"    "state-read"
per_rule "5" "$BUGGY/b06_stderr.py"   "$FIXED/b06_stderr.py"   "silent-stderr"

# ── (6) MEASURED DELTA — the keep/discard gate ──────────────────────────────────
BUGGY_N="$(count "$BUGGY")"; FIXED_N="$(count "$FIXED")"
DELTA=$((BUGGY_N - FIXED_N))
printf "  \033[90mmeasured: buggy=%s fixed=%s delta=%s\033[0m\n" "$BUGGY_N" "$FIXED_N" "$DELTA"
if [ "$FIXED_N" = "0" ] && [ "$DELTA" -gt 0 ]; then
  ok "(6) measured delta > 0 with a clean fixed baseline -> KEEP (checker discriminates buggy vs fixed)"
else
  bad "(6) NO measured delta (buggy=$BUGGY_N fixed=$FIXED_N) -> DISCARD per the no-delta rule (checker cannot discriminate)"
fi

# ── (7) marker allowlist suppresses an otherwise-flagged site ───────────────────
cat > "$WORK/marked.py" <<'PY'
import os
def planning_dir(repo_slug):
    # deployed-shape-ok: slug is already a cloned workspace path
    return os.path.join(repo_slug, "context.md")
PY
[ "$(count "$WORK/marked.py")" = "0" ] && ok "(7) marker '# deployed-shape-ok' suppresses the finding" || bad "(7) marker did NOT suppress"

# ── (8) warn-only default: findings do NOT change the exit code ──────────────────
python3 "$CHK" "$BUGGY" >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok "(8) warn-only default exits 0 despite findings" || bad "(8) default exit was $rc, expected 0 (warn-only)"

# ── (9) --strict: 1 iff findings, 0 when clean ──────────────────────────────────
python3 "$CHK" "$BUGGY" --strict --quiet >/dev/null 2>&1; rc=$?
[ "$rc" = "1" ] && ok "(9) --strict exits 1 when findings exist" || bad "(9) --strict exit was $rc, expected 1"
python3 "$CHK" "$FIXED" --strict --quiet >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok "(9) --strict exits 0 when clean" || bad "(9) --strict clean exit was $rc, expected 0"

# ── (10) wired WARN-only into both deploy scripts ───────────────────────────────
bash -n "$ARCHB" && ok "(10) deploy-arch-b.sh bash -n clean" || bad "(10) deploy-arch-b.sh syntax error"
bash -n "$GOLIVE" && ok "(10) go-live.sh bash -n clean" || bad "(10) go-live.sh syntax error"
grep -q "heimdall-deployed-shape-check" "$ARCHB" && ok "(10) deploy-arch-b.sh invokes the checker" || bad "(10) deploy-arch-b.sh does NOT invoke the checker"
grep -q "heimdall-deployed-shape-check" "$GOLIVE" && ok "(10) go-live.sh invokes the checker" || bad "(10) go-live.sh does NOT invoke the checker"
# never-block proof: the invocation is guarded with '|| true' (warn-only).
grep -Eq 'heimdall-deployed-shape-check.*\|\| true|python3 "\$\{?DSHAPE_CHECK\}?".*\|\| true' "$ARCHB" \
  && ok "(10) deploy-arch-b.sh checker is warn-only (|| true)" || bad "(10) deploy-arch-b.sh checker not warn-only"
grep -Eq 'python3 "\$\{?DSHAPE_CHECK\}?".*\|\| true' "$GOLIVE" \
  && ok "(10) go-live.sh checker is warn-only (|| true)" || bad "(10) go-live.sh checker not warn-only"

echo
printf "deployed-shape-check acceptance: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
