#!/usr/bin/env bash
# hmd-subagent-statusline.sh — Heimdall watchman for Claude Code subagentStatusLine.
# Subagent lines are ONE line: a single watchman glyph (eye-colored by the live
# gate verdict) + the subagent role label + the current gate verdict word.
# Reads CC JSON on stdin. Zero context cost. Survives empty stdin, exits 0 always.
#
#   echo '{}' | hmd-subagent-statusline.sh        → ◉ watching   (sane fallback)
#   …with .heimdall/statusline.json verdict=deny  → ◉ … ✗ BIFRÖST (red)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export HMD_SIGIL_DIR="$HERE"

# Slurp stdin (may be empty); hand it to python as argv so the heredoc owns stdin.
JSON="$(cat 2>/dev/null || true)"

HMD_JSON="$JSON" python3 - <<'PY' 2>/dev/null || { printf '\033[38;2;34;211;238m◉\033[0m \033[38;2;90;100;114mwatching\033[0m\n'; exit 0; }
import os, json, importlib.util

HERE = os.environ["HMD_SIGIL_DIR"]
spec = importlib.util.spec_from_file_location("hmd_sigil", os.path.join(HERE, "hmd_sigil.py"))
SIG = importlib.util.module_from_spec(spec); spec.loader.exec_module(SIG)

CY="\033[38;2;34;211;238m"; GR="\033[38;2;34;197;94m"; RD="\033[38;2;239;68;68m"
AM="\033[38;2;245;158;11m"; DIM="\033[38;2;90;100;114m"; B="\033[1m"; X="\033[0m"

try:
    data = json.loads(os.environ.get("HMD_JSON") or "{}")
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}

cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or os.getcwd()
model = (data.get("model") or {}).get("display_name") or "Claude"
haid = os.environ.get("HMD_HAID") or os.environ.get("USER") or "you"

# role label: env first (subagent identity), else the model name.
label = (os.environ.get("HMD_AGENT_LABEL") or os.environ.get("HMD_SUBAGENT")
         or os.environ.get("CLAUDE_AGENT_NAME") or os.environ.get("CLAUDE_SUBAGENT_TYPE")
         or os.environ.get("AGENT_NAME") or model)

# live gate verdict
p = os.environ.get("HEIMDALL_STATE") or os.path.join(cwd, ".heimdall", "statusline.json")
try:
    with open(p) as f: st = json.load(f)
except Exception:
    st = {}
verdict = st.get("verdict", "watching")

VERDICT = {  # verdict -> (eye rgb, ansi col, glyph, word)
 "pass":     ((34,197,94),  GR, "✓", "pass"),
 "deny":     ((239,68,68),  RD, "✗", "BIFRÖST"),
 "scanning": ((245,158,11), AM, "◦", "scanning"),
 "watching": ((34,211,238), CY, "◦", "watching"),
}
if verdict not in VERDICT: verdict = "watching"
eye_rgb, vcol, vglyph, vword = VERDICT[verdict]

# the watchman's single eye glows the current verdict
g = SIG.glyph(haid, eye_override=eye_rgb)
cnt = ""
if st.get("passed") is not None and st.get("total") is not None:
    cnt = f" {vcol}{st['passed']}/{st['total']}{X}"

print(f"{g} {DIM}{label}{X} {vcol}{B}{vglyph} {vword}{X}{cnt}")
PY
