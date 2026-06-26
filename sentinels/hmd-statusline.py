#!/usr/bin/env python3
"""
hmd-statusline.py — Heimdall watchman statusline v2 for Claude Code.
Full-width. Personal sigil anchors the left; gate verdict pins the right; the
team watch wall fills the bottom row when teammates are live. Reads CC JSON on
stdin. Zero context cost. Falls back gracefully with no state and no team.

Ships via plugin settings.json:
  "statusLine": {"type":"command","command":"python3 ${CLAUDE_PLUGIN_ROOT}/sentinels/hmd-statusline.py","refreshInterval":3}

Modes:
  --widget   emit only the watchman+verdict segment (ccstatusline coexistence)
"""
import sys, os, json, time, re, hashlib, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("hmd_sigil", os.path.join(HERE, "hmd_sigil.py"))
SIG = importlib.util.module_from_spec(spec); spec.loader.exec_module(SIG)

# palette
CY="\033[38;2;34;211;238m"; GR="\033[38;2;34;197;94m"; RD="\033[38;2;239;68;68m"
AM="\033[38;2;245;158;11m"; DIM="\033[38;2;90;100;114m"; FAINT="\033[38;2;58;65;77m"
BOLD="\033[1m"; X="\033[0m"
SEP=f"{FAINT} │ {X}"
ANSI = re.compile(r"\033\[[0-9;]*m")
def vis(s): return len(ANSI.sub("", s))

def read_json():
    try: return json.load(sys.stdin)
    except Exception: return {}

def gate_state(cwd):
    p = os.environ.get("HEIMDALL_STATE", os.path.join(cwd, ".heimdall", "statusline.json"))
    try:
        with open(p) as f: return json.load(f)
    except Exception: return {}

def team_presence(cwd, ttl=30):
    """Read .heimdall/team/*.json — each running hmd heartbeats its own file."""
    d = os.path.join(cwd, ".heimdall", "team"); out = []
    try: names = os.listdir(d)
    except Exception: return out
    now = time.time()
    for n in names:
        if not n.endswith(".json"): continue
        try:
            with open(os.path.join(d, n)) as f: t = json.load(f)
        except Exception: continue
        if now - t.get("ts", 0) > ttl: continue   # gone stale → agent left
        out.append(t)
    out.sort(key=lambda t: t.get("name", ""))
    return out

VERDICT = {  # verdict -> (eye color rgb, ansi col, glyph, word)
 "pass":     ((34,197,94),  GR, "✓", "GATE"),
 "deny":     ((239,68,68),  RD, "✗", "BIFRÖST CLOSED"),
 "scanning": ((245,158,11), AM, "◦", "scanning"),
 "watching": ((34,211,238), CY, "◦", "watching"),
}

def main():
    data = read_json()
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or os.getcwd()
    model = (data.get("model") or {}).get("display_name", "Claude")
    cw = data.get("context_window") or {}
    pct = int(cw.get("used_percentage") or 0)
    repo = ((data.get("workspace") or {}).get("repo") or {}).get("name") or os.path.basename(cwd)
    haid = os.environ.get("HMD_HAID") or os.environ.get("USER") or "you"

    st = gate_state(cwd)
    verdict = st.get("verdict", "watching")
    if verdict not in VERDICT: verdict = "watching"
    eye_rgb, vcol, vglyph, vword = VERDICT[verdict]
    passed, total = st.get("passed"), st.get("total")
    cols = int(os.environ.get("COLUMNS") or 120)
    RMARGIN = 6  # right safety gutter: clears Claude Code's scrollbar + edge padding so the verdict never clips off-screen

    # ── animation: the watchman keeps a bright WHITE eye glint so the face
    # always reads. The verdict is shown by the right block + bar + bifröst
    # text — NOT by recoloring the eyes: a verdict-colored eye washes into a
    # same-hue body (e.g. cyan 'watching' eyes on a teal sigil) and erases the
    # face. Blink shuts the eyes one frame every ~5s; scanning gives a dim
    # pulse. (The dramatic red deny-flash lives in hmd-gate-anim.sh, not here.)
    t = int(time.time())
    blink = (t % 5 == 0)
    eye = (38, 44, 53) if blink else None        # None -> default white glint
    if verdict == "scanning" and (t % 2 == 0): eye = (120, 80, 6)  # dim pulse

    if "--widget" in sys.argv:
        eyes = {"pass":"^ ^","deny":"O O","scanning":". .","watching":"• •"}[verdict]
        cnt = f" {passed}/{total}" if passed is not None else ""
        sys.stdout.write(f"{CY}▐{X}{vcol}{eyes}{X}{CY}▌{X} {vcol}{vglyph} {vword}{cnt}{X}")
        return

    # ── sigil anchor (verdict colors the eyes; blink animates) ──
    sig = SIG.render(haid, eye_override=eye, pad="")  # 4 rows, 9 cols
    SW = 9
    ANCHOR = SW + 2  # sigil(9 cols) + 2-space gutter, prefixed on EVERY row

    # context bar
    bcol = RD if pct >= 90 else AM if pct >= 70 else GR
    fill = pct // 10
    bar = f"{bcol}{'▓'*fill}{FAINT}{'░'*(10-fill)}{X} {bcol}{pct}%{X}"

    # token gauge (honest: absolute input tokens from CC, else derived from %×size)
    def human(n):
        if not n: return None
        return f"{n//1000}k" if n >= 1000 else str(n)
    tin = cw.get("total_input_tokens")
    size = cw.get("context_window_size")
    if not tin and pct and size: tin = int(size * pct / 100)
    toks = human(tin)
    tok_seg = f"{SEP}{DIM}↓{toks}{X}" if toks else ""

    # ledger claim count (live coordination signal — count claim files, no subprocess)
    def ledger_claims(p):
        d = os.path.join(p, ".planning", "ledger", "claims")
        try: return sum(1 for n in os.listdir(d) if n.endswith(".json"))
        except Exception: return 0
    claims = ledger_claims(cwd)
    claim_seg = f" {FAINT}·{X} {DIM}ledger {claims} claim{'s' if claims != 1 else ''}{X}" if claims else ""

    # inline eye bracket — the watchman's eyes, verdict-colored, anchoring the name
    eye_glyph = {"pass": "●", "deny": "✗", "scanning": "◦", "watching": "●"}.get(verdict, "●")
    eyes_inline = f"{CY}▐{X}{vcol}{eye_glyph} {eye_glyph}{X}{CY}▌{X}"

    # right-aligned verdict block
    r1 = f"{vcol}{BOLD}{vglyph} {vword}{X}" + (f" {vcol}{passed}/{total}{X}" if passed is not None else "")
    bifrost = (f"{GR}bifröst open{X}" if verdict=="pass" else
               f"{RD}bifröst closed{X}" if verdict=="deny" else f"{DIM}watching{X}")
    r2 = f"{bifrost}{claim_seg}"

    # left info rows
    l1 = f"{eyes_inline} {CY}{BOLD}HEIMDALL{X}{SEP}{DIM}{haid}{X}{SEP}{DIM}{model}{X}"
    l2 = f"{bar}{SEP}{AM}{repo}:main{X}{tok_seg}"

    # team wall (only when teammates present) — cap at the 6 most-recently
    # active so a big team can't overflow the row; surplus shows as "+N more".
    team = team_presence(cwd)
    wall_segs = []
    if team:
        team = sorted(team, key=lambda t: t.get("ts", 0), reverse=True)
        extra = max(0, len(team) - 6)
        team = sorted(team[:6], key=lambda t: t.get("name", ""))
        wall_segs.append(f"{FAINT}── watch ──{X}")
        for m in team:
            v = m.get("verdict", "working")
            col = {"pass":GR,"done":GR,"deny":RD,"working":AM,"watching":CY}.get(v, CY)
            ergb = {"pass":(34,197,94),"done":(34,197,94),"deny":(239,68,68),"working":(245,158,11)}.get(v)
            g = SIG.glyph(m.get("name","?"), eye_override=ergb)
            state = ({"pass":"✓","done":"✓","deny":"✗","working":"⚡"}.get(v,"◦"))
            f = m.get("file","")
            label = f"{m.get('name','?')} {col}{state}{(' '+f) if f else ''}{X}"
            seg = f"{g} {label}"
            if v == "deny":  # the moment — make it pop
                seg = f"{RD}▕{X}{g} {RD}{BOLD}{m.get('name','?')} ✗ BIFRÖST{(' '+f) if f else ''}{X}{RD}▏{X}"
            wall_segs.append(seg)
        if extra:
            wall_segs.append(f"{DIM}+{extra} more{X}")
        # your own watchman closes the wall
        you_state = {"pass": "✓", "deny": "✗", "scanning": "◦"}.get(verdict, "⚡")
        you_word  = {"pass": "proven", "deny": "blocked", "scanning": "scanning"}.get(verdict, "working")
        wall_segs.append(f"{SIG.glyph(haid)} {BOLD}you{X} {DIM}{you_state} {you_word}{X}")

    def line(left, right):
        # account for the sigil anchor prefixed on every row AND a right safety
        # gutter, so the right block pins inside the usable width — Claude Code
        # reserves the far-right edge (scrollbar + padding) and clips anything
        # rendered at exactly COLUMNS.
        gap = cols - ANCHOR - RMARGIN - vis(left) - vis(right)
        return left + (" " * max(1, gap)) + right

    out = []
    out.append(f"{_sig(sig,0,CY)}  " + line(l1, r1))
    out.append(f"{_sig(sig,1,CY)}  " + line(l2, r2))
    if wall_segs:
        wall = "  ".join(wall_segs)
        out.append(f"{_sig(sig,2,CY)}  " + wall)
        out.append(f"{_sig(sig,3,CY)}  ")
    else:
        out.append(f"{_sig(sig,2,CY)}  ")
        out.append(f"{_sig(sig,3,CY)}  ")
    sys.stdout.write("\n".join(out) + "\n")

def _sig(rows, i, fallback):
    return rows[i] if i < len(rows) else "         "

if __name__ == "__main__":
    main()
