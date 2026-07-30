#!/usr/bin/env bash
#
# heimdall-statusline-crossbranch.test.sh — CROSS-BRANCH TEAM VISIBILITY (RJ).
#
# Same repo == same team surface: a teammate on a DIFFERENT git branch of the SAME repo is
# STILL on your statusline roster (the roster is repo-scoped, never branch-scoped), and their
# branch renders on the line UNDER their name (`⎇<branch>` in the faint branch hue) so you can
# see, at a glance, who is off on another branch. A SAME-branch teammate is unchanged — their
# Row4 stays the state segment (no branch line), so single-user / same-branch never regresses.
#
# It drives the REAL SUT (sentinels/hmd-statusline.py + the ledger reader) at 120 cols with a
# status.json team[] of TWO teammates — `mira` on branch `wip` (differs from self `main`) and
# `kai` on branch `main` (same as self) — and asserts, FALSIFIABLY:
#
#   1. VISIBLE     both teammates render (mira AND kai) — the roster is not branch-filtered.
#   2. BRANCH-LINE mira's branch (`⎇wip`) appears on Row4, the line directly UNDER her name
#                  (Row3). (RED if the branch data is dropped or the line is missing.)
#   3. SAME-BRANCH kai (== self branch) shows NO branch line (`⎇main` absent) — Row4 keeps the
#                  state segment; same-branch rendering is not regressed.
#   4. CONTROL     with BOTH teammates on `main` (all same-branch), NO `⎇` marker appears at all
#                  — proving the branch line is CONDITIONED on a differing branch (falsifiable:
#                  a bug that always/never draws it flips this or #2 RED).
#   5. ROW-EXACT   every emitted row is EXACTLY 120 visible cells (the branch line respects the
#                  team-zone width discipline), exit 0, empty stderr.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

ROOT="$ROOT" SL="$SL" python3 - <<'PY'
import os, sys, re, json, tempfile, shutil, subprocess

SL = os.environ["SL"]
ANSI = re.compile(r"\x1b\[[0-9;]*m")

_p = 0; _f = 0
def ok(m):
    global _p; _p += 1; print("  ok   " + m)
def bad(m):
    global _f; _f += 1; print("  FAIL " + m)

def _wide(o):
    return (o == 0x26A1 or 0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0x303E or
            0x3041 <= o <= 0x33FF or 0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or
            0xAC00 <= o <= 0xD7A3 or 0x1F000 <= o <= 0x1FAFF)
def vis(s):
    s = ANSI.sub("", s); n = 0
    for ch in s:
        o = ord(ch)
        if o in (0x200B, 0x200D, 0xFE0F) or 0x0300 <= o <= 0x036F:
            continue
        n += 2 if _wide(o) else 1
    return n
def strip(s):
    return ANSI.sub("", s)

# hermetic render of the REAL statusline: a throwaway HOME (ledger status.json), workspace
# (identity + legacy verdict), fixed clock + identity, CP pointed at a dead port. `self_branch`
# rides the stdin repo.branch; each teammate carries its own `branch` in the ledger team[].
def render(cols, self_branch, teammates, now=7000):
    home = tempfile.mkdtemp(); cwd = tempfile.mkdtemp(); tmp = tempfile.mkdtemp()
    os.makedirs(os.path.join(cwd, ".heimdall"), exist_ok=True)
    os.makedirs(os.path.join(home, ".heimdall", "ledger"), exist_ok=True)
    with open(os.path.join(cwd, ".heimdall", "identity.json"), "w") as f:
        f.write('{"handle":"rj","seed":"rj","created":0}\n')
    with open(os.path.join(cwd, ".heimdall", "statusline.json"), "w") as f:
        f.write('{"verdict":"pass","passed":3,"total":3}\n')
    status = {"daemon": True,
              "gates": [{"id": "tests", "state": "pass", "detail": "41/41"}],
              "team": [dict(m, ts=now - 30 * (i + 1)) for i, m in enumerate(teammates)]}
    with open(os.path.join(home, ".heimdall", "ledger", "status.json"), "w") as f:
        json.dump(status, f)
    data = {"workspace": {"current_dir": cwd,
                          "repo": {"name": "heimdall", "branch": self_branch}},
            "model": {"display_name": "Opus 4.8"},
            "context_window": {"used_percentage": 42, "total_input_tokens": 128000},
            "cost": {"total_cost_usd": 0.87, "total_duration_ms": 3840000},
            "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": now + 7200},
                            "seven_day": {"used_percentage": 12}},
            "session_id": "xb-%s" % self_branch}
    env = {"PATH": os.environ.get("PATH", ""), "HOME": home, "LANG": "en_US.UTF-8",
           "HEIMDALL_HOME": os.path.join(home, ".heimdall"),
           "HEIMDALL_IDENTITY_DIR": os.path.join(cwd, ".heimdall"), "HMD_HAID": "rj",
           "HMD_NOW": str(now), "HEIMDALL_CP_URL": "http://127.0.0.1:1", "COLUMNS": str(cols),
           "HMD_STATUSLINE_TMP": tmp, "HEIMDALL_STATUSLINE_MODE": "truecolor",
           "HMD_STATUSLINE_RESERVE": "0"}
    r = subprocess.run([sys.executable, SL, "--color"], input=json.dumps(data).encode(),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    out = r.stdout.decode("utf-8", "replace"); err = r.stderr.decode("utf-8", "replace")
    shutil.rmtree(home, ignore_errors=True); shutil.rmtree(cwd, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)
    return [l for l in out.split("\n") if l != ""], r.returncode, err

# distinct REAL HAIDs → distinct auto-assigned heroes; mira differs in branch, kai matches self.
MIRA = {"user": "mira", "haid": "haid:mira.mbp-3c4d", "state": "pass"}
KAI  = {"user": "kai",  "haid": "haid:kai.mbp-9z8y",  "state": "running"}

# ── the CROSS-BRANCH render: self on `main`, mira on `wip`, kai on `main` ──
rs, rc, err = render(120, "main",
                     [dict(MIRA, branch="wip"), dict(KAI, branch="main")])
plain = [strip(r) for r in rs]
joined = "\n".join(plain)

# 1. VISIBLE — both teammates render (roster is NOT branch-filtered).
(ok if ("mira" in joined and "kai" in joined) else bad)(
    "VISIBLE: cross-branch teammate `mira` AND same-branch `kai` both on the roster")

# 2. BRANCH-LINE — mira's branch on Row4, the line UNDER her name (Row3). Names ride Row3
#    (index 2), the branch/state ride Row4 (index 3) — assert the marker is on Row4 AND that
#    Row3 carries the name it sits under.
name_row = plain[2] if len(plain) > 2 else ""
branch_row = plain[3] if len(plain) > 3 else ""
(ok if ("mira" in name_row and "⎇wip" in branch_row) else bad)(
    "BRANCH-LINE: `⎇wip` on Row4 directly under mira's name on Row3")

# 3. SAME-BRANCH — kai (== self) shows NO branch line; `⎇main` never rendered.
(ok if "⎇main" not in joined else bad)(
    "SAME-BRANCH: kai (self branch) shows NO `⎇main` line (Row4 keeps the state)")

# 4. CONTROL — both teammates on `main` (all same-branch) → NO `⎇` marker anywhere.
rs2, rc2, err2 = render(120, "main",
                        [dict(MIRA, branch="main"), dict(KAI, branch="main")])
(ok if all("⎇" not in strip(r) for r in rs2) else bad)(
    "CONTROL: all teammates same-branch → NO `⎇` marker (branch line is differ-conditioned)")

# 5. ROW-EXACT — every row EXACTLY 120 cells, exit 0, empty stderr (both renders).
widths = sorted(set(vis(r) for r in rs))
(ok if widths == [120] and rc == 0 and not err else bad)(
    "ROW-EXACT: cross-branch render → every row == 120 (widths=%s rc=%d err=%r)"
    % (widths, rc, err[:60]))
widths2 = sorted(set(vis(r) for r in rs2))
(ok if widths2 == [120] and rc2 == 0 and not err2 else bad)(
    "ROW-EXACT: control render → every row == 120 (widths=%s rc=%d)" % (widths2, rc2))

print()
print("%d passed, %d failed" % (_p, _f))
sys.exit(1 if _f else 0)
PY
