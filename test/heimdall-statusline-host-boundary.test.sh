#!/usr/bin/env bash
#
# heimdall-statusline-host-boundary.test.sh — the watchman's `--host-boundary` mode.
#
# bin/heimdall-statusline used to correct the host payload AROUND the watchman with three
# separate python launches (render_width_chars probe, Cursor host-label normalizer, CTX-honesty
# post-process) — ~210ms of the ~750ms render, every render, for work the watchman's own
# process already had the parsed JSON for. Those three corrections now run INSIDE the
# watchman, behind one flag the wrapper passes. This suite drives the watchman DIRECTLY
# (no wrapper) to pin both halves of that contract:
#   - WITH --host-boundary: the three corrections apply, with the exact precedence the shell
#     code had (Cursor's render_width_chars beats a stale $COLUMNS and skips the 4-cell
#     Claude Code reserve unless the caller set HMD_STATUSLINE_RESERVE; a null/absent
#     used_percentage never renders "CTX 0%"; a blank Cursor display_name is labelled Cursor).
#   - WITHOUT it: the watchman is byte-for-byte what every other suite that drives it
#     directly already expects ($COLUMNS - reserve, "CTX 0%", the "Claude" default) — the
#     corrections belong to the wrapper's boundary, not to the renderer.
# The wrapper-level behaviour (the same corrections through bin/heimdall-statusline, byte
# identical to before) stays locked by heimdall-statusline-cursor-payload.test.sh and
# heimdall-statusline-parity.test.sh.
#
# FALSIFIER: make `HOST_BOUNDARY` permanently False in sentinels/hmd-statusline.py -> every
# "WITH" case goes RED; make it permanently True -> every "WITHOUT" case goes RED.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 unavailable"
  echo "heimdall-statusline-host-boundary: 0 passed, 0 failed (SKIPPED — python3 unavailable)"
  exit 0
}
[ -f "$SL" ] || { echo "FATAL: $SL missing"; echo "heimdall-statusline-host-boundary: 0 passed, 1 failed"; exit 1; }

WS="$(mktemp -d)"; HOMED="$(mktemp -d)"; TMPD="$(mktemp -d)"
trap 'rm -rf "$WS" "$HOMED" "$TMPD"' EXIT
mkdir -p "$WS/.heimdall"
printf '{"handle":"rj","seed":"rj","created":0}\n' > "$WS/.heimdall/identity.json"
printf '{"verdict":"pass","passed":3,"total":3}\n'  > "$WS/.heimdall/statusline.json"
: > "$WS/.heimdall/.beat-stamp"
: > "$WS/.heimdall/.wall-cache.json.lock"

# render <json> <extra env assignment or -> <extra argv...>  -> stdout.  Hermetic env -i, fixed clock.
render() {
  local json="$1" envx="$2"; shift 2
  [ "$envx" = "-" ] && envx="X_UNUSED=1"
  printf '%s' "$json" | env -i PATH="$PATH" HOME="$HOMED" LANG=en_US.UTF-8 \
      HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID=rj HMD_NOW=1752410000 \
      HEIMDALL_CP_URL="http://127.0.0.1:1" TERM=xterm-256color \
      HMD_STATUSLINE_TMP="$TMPD" HEIMDALL_STATUSLINE_MODE=truecolor "$envx" \
      python3 "$SL" --color "$@" 2>/dev/null
}

# the set of visible row widths (ANSI stripped, wide-glyph aware) — same ruler as the parity suite
row_widths() {
  python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
def w(l):
  s=A.sub("",l); n=0
  for ch in s:
    o=ord(ch)
    if o in (0x200B,0x200D,0xFE0F) or 0x0300<=o<=0x036F: continue
    n += 2 if (o==0x26A1 or 0x1100<=o<=0x115F or 0x2E80<=o<=0x303E or 0x3041<=o<=0x33FF or 0x3400<=o<=0x4DBF or 0x4E00<=o<=0x9FFF or 0xAC00<=o<=0xD7A3 or 0x1F000<=o<=0x1FAFF) else 1
  return n
ws=sorted(set(w(l) for l in sys.stdin.read().split(chr(10)) if l!=""))
print(",".join(str(x) for x in ws))'
}
strip_ansi() { python3 -c 'import sys,re; sys.stdout.write(re.sub(r"\033\[[0-9;]*m","",sys.stdin.read()))'; }

CURSOR_88="{\"session_id\":\"hb1\",\"transcript_path\":\"/x\",\"autorun\":false,\"cwd\":\"$WS\",\"workspace\":{\"current_dir\":\"$WS\"},\"render_width_chars\":88,\"model\":{\"display_name\":\"Composer\"},\"context_window\":{\"used_percentage\":30}}"

echo "== 1) WIDTH: Cursor's render_width_chars beats a stale \$COLUMNS, with no CC reserve =="
W="$(render "$CURSOR_88" COLUMNS=200 --host-boundary | row_widths)"
[ "$W" = "88" ] && ok "WITH: render_width_chars=88 beats COLUMNS=200 -> rows are exactly 88 wide (got {$W})" \
                || bad "WITH: expected rows of exactly 88, got {$W}"
W="$(render "$CURSOR_88" COLUMNS=200 | row_widths)"
[ "$W" = "196" ] && ok "WITHOUT: the flag off -> the legacy \$COLUMNS-4 width (196), render_width_chars ignored" \
                 || bad "WITHOUT: expected 196 (COLUMNS=200 minus the 4-cell reserve), got {$W}"
W="$(render "$CURSOR_88" HMD_STATUSLINE_RESERVE=10 --host-boundary | row_widths)"
[ "$W" = "78" ] && ok "WITH: a caller-set HMD_STATUSLINE_RESERVE=10 still applies to render_width_chars -> 78" \
                || bad "WITH: caller's HMD_STATUSLINE_RESERVE=10 not honoured, got {$W} (want 78)"
ZERO_J="$(printf '%s' "$CURSOR_88" | sed 's/"render_width_chars":88/"render_width_chars":0/')"
W="$(render "$ZERO_J" COLUMNS=100 --host-boundary | row_widths)"
[ "$W" = "96" ] && ok "WITH: render_width_chars=0 falls through to COLUMNS (100-4=96), never a collapsed width" \
                || bad "WITH: render_width_chars=0 collapsed the layout, got {$W} (want 96)"
CC_J="{\"session_id\":\"hb2\",\"cwd\":\"$WS\",\"workspace\":{\"current_dir\":\"$WS\"},\"model\":{\"display_name\":\"Opus\"},\"context_window\":{\"used_percentage\":30}}"
W="$(render "$CC_J" COLUMNS=120 --host-boundary | row_widths)"
[ "$W" = "116" ] && ok "WITH: a Claude Code payload (no render_width_chars) keeps COLUMNS-4 (116)" \
                 || bad "WITH: Claude Code width changed under the flag, got {$W} (want 116)"

echo "== 2) HOST LABEL: a blank Cursor display_name is labelled Cursor, only under the flag =="
NOMODEL_J="{\"session_id\":\"hb3\",\"transcript_path\":\"/x\",\"autorun\":false,\"cwd\":\"$WS\",\"workspace\":{\"current_dir\":\"$WS\"},\"context_window\":{\"used_percentage\":30}}"
OUT="$(render "$NOMODEL_J" COLUMNS=200 --host-boundary | strip_ansi)"
case "$OUT" in *"· Cursor"*) ok "WITH: Cursor-shaped payload with no model -> '· Cursor'" ;; *) bad "WITH: no Cursor label for a Cursor-shaped payload with no model" ;; esac
OUT="$(render "$NOMODEL_J" COLUMNS=200 | strip_ansi)"
case "$OUT" in *"· Claude"*) ok "WITHOUT: the flag off -> the legacy '· Claude' default" ;; *) bad "WITHOUT: expected the legacy '· Claude' default" ;; esac
OUT="$(render "$CURSOR_88" COLUMNS=200 --host-boundary | strip_ansi)"
case "$OUT" in *"· Composer"*) ok "WITH: a real display_name (Composer) is never overwritten" ;; *) bad "WITH: a populated display_name was overwritten" ;; esac
OUT="$(render "$CC_J" COLUMNS=200 --host-boundary | strip_ansi)"
case "$OUT" in *"· Opus"*) ok "WITH: a Claude Code payload (no transcript_path/autorun) is untouched" ;; *) bad "WITH: Claude Code payload label changed" ;; esac

echo "== 3) CTX HONESTY: null/absent used_percentage is 'unavailable', never 'CTX 0%' =="
NULL_J="{\"session_id\":\"hb4\",\"cwd\":\"$WS\",\"workspace\":{\"current_dir\":\"$WS\"},\"model\":{\"display_name\":\"Opus\"},\"context_window\":{\"used_percentage\":null}}"
OUT="$(render "$NULL_J" COLUMNS=200 --host-boundary | strip_ansi)"
case "$OUT" in *"– CTX unavailable"*) ok "WITH: null used_percentage -> '– CTX unavailable'" ;; *) bad "WITH: null used_percentage did not render the unavailable marker" ;; esac
case "$OUT" in *"CTX 0%"*) bad "WITH: a fabricated 'CTX 0%' survived" ;; *) ok "WITH: no fabricated 'CTX 0%'" ;; esac
OUT="$(render "$NULL_J" COLUMNS=200 | strip_ansi)"
case "$OUT" in *"CTX 0%"*) ok "WITHOUT: the flag off -> the watchman's legacy 'CTX 0%' (corrections live at the wrapper boundary)" ;; *) bad "WITHOUT: expected the legacy 'CTX 0%'" ;; esac
REAL_J="$(printf '%s' "$NULL_J" | sed 's/"used_percentage":null/"used_percentage":42/')"
OUT="$(render "$REAL_J" COLUMNS=200 --host-boundary | strip_ansi)"
case "$OUT" in *"CTX 42%"*) ok "WITH: a real reading (42) renders unchanged" ;; *) bad "WITH: a real reading was swallowed" ;; esac
ZERO_P="$(printf '%s' "$NULL_J" | sed 's/"used_percentage":null/"used_percentage":0/')"
OUT="$(render "$ZERO_P" COLUMNS=200 --host-boundary | strip_ansi)"
case "$OUT" in *"CTX 0%"*) ok "WITH: a genuine zero reading still renders 'CTX 0%' (distinct from unavailable)" ;; *) bad "WITH: a genuine 0 was turned into unavailable" ;; esac

echo
echo "heimdall-statusline-host-boundary: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
