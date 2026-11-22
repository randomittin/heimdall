#!/usr/bin/env bash
# lean-prompt-sections.test.sh -- proves the lean main prompt (lean-core plan T4.3, docs/superpowers/plans/2026-11-12-3x-lean-core.md):
# agents/heimdall-lean.md is agents/heimdall.md minus three procedure sections (2, 4, 5) that moved, byte for byte, into
# skills/heimdall/references/lean-procedures.md, which the lean prompt points to. Nothing else may differ, so a lean session loses no rule,
# only the order in which it reads them.
#
#   1. SHAPE     the frontmatter is the full prompt's except `name: heimdall-lean`; the lean prompt has the same level-2 headings in the same
#                order and stays under 30000 bytes (the plan's acceptance ceiling).
#   2. VERBATIM  the title and intro and every section that did not move (0, Your Design Specification, 1, 3, 4.5, 5.5, 6 to 12) are
#                byte-equal to agents/heimdall.md, separators included.
#   3. POINTERS  sections 2, 4 and 5 keep their heading line; their body is exactly three lines that name the reference, with no
#                sub-heading and none of the procedure left behind.
#   4. MOVED     the reference holds sections 2, 4 and 5 of agents/heimdall.md byte-equal and in order: lean prompt + reference = full prompt.
#   5. FALSIFY   one injected defect per claim, on throwaway copies (a byte of a verbatim section, a dropped section, a changed frontmatter
#                line, the name left as `heimdall`, a changed title, a fourth pointer line, a pointer without the path, a byte of a moved block,
#                a moved block gone from the reference, an oversized lean prompt, a full prompt that drifted), turns the checker RED and names
#                the claim; the same copies unmodified are GREEN.
#
# Editing agents/heimdall.md now means mirroring the edit: in agents/heimdall-lean.md for a section that stayed, in the reference for one that
# moved. This suite is what turns a forgotten mirror into a red test instead of a silent behaviour change in the lean profile.
# bash 3.2 compatible; python3 -I does the byte work (a bash variable cannot hold a trailing newline).
#
# Usage: bash test/lean-prompt-sections.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FULL="$REPO/agents/heimdall.md"
LEAN="$REPO/agents/heimdall-lean.md"
REF="$REPO/skills/heimdall/references/lean-procedures.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "lean-prompt-sections: python3 is required"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lean-sections.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
LPS="$T/lps.py"

echo "lean-prompt-sections (the lean prompt is the full prompt minus sections 2, 4 and 5, which moved verbatim into the reference)"

echo "-- 0. the files --"
for f in "$FULL" "$LEAN" "$REF"; do
  if [ -f "$f" ]; then ok "${f#"$REPO"/} exists"; else bad "${f#"$REPO"/} is missing"; fi
done
if [ "$FAIL" -ne 0 ]; then
  echo
  echo "lean-prompt-sections: $PASS passed, $FAIL failed"
  exit 1
fi

# The checker and the mutation builder. check prints one `ok|label` or `FAIL|label -- why` line per claim and exits 1 on any FAIL;
# mutate writes a copy of SRC with ONE defect of the named kind and exits non-zero when it could not (a defect that changes nothing is no test).
cat > "$LPS" <<'PY'
import sys

SEP = b"\n---\n\n"
REF_PATH = b"skills/heimdall/references/lean-procedures.md"
MOVED = (b"## 2. ", b"## 4. ", b"## 5. ")
POINTER_LINES = 3
CEILING = 30000


def split(data):
    """(everything before the first level-2 heading, one chunk per level-2 heading outside a code fence); the pieces re-join to data."""
    starts, pos, fence = [], 0, False
    for line in data.splitlines(True):
        text = line.rstrip(b"\r\n")
        if text.startswith(b"```"):
            fence = not fence
        elif not fence and text.startswith(b"## "):
            starts.append(pos)
        pos += len(line)
    if not starts:
        return data, []
    bounds = starts + [len(data)]
    return data[:starts[0]], [data[bounds[i]:bounds[i + 1]] for i in range(len(starts))]


def head(chunk):
    return chunk.split(b"\n", 1)[0]


def frontmatter(pre):
    """(the lines between the two --- lines, what follows the closing one); (None, pre) when there is no frontmatter."""
    lines = pre.splitlines(True)
    if lines and lines[0].rstrip(b"\r\n") == b"---":
        for i in range(1, len(lines)):
            if lines[i].rstrip(b"\r\n") == b"---":
                return lines[1:i], b"".join(lines[i + 1:])
    return None, pre


def first_diff(a, b):
    n = min(len(a), len(b))
    i = next((k for k in range(n) if a[k] != b[k]), n)
    return "first difference at byte %d (line %d)" % (i, a[:i].count(b"\n") + 1)


def norm_name(lines):
    return [b"name: _\n" if line.startswith(b"name:") else line for line in lines]


def check(full_path, lean_path, ref_path):
    out = []

    def say(good, label, why=""):
        out.append(("ok|" if good else "FAIL|") + label + ("" if good else " -- " + why))

    with open(full_path, "rb") as fh:
        full = fh.read()
    with open(lean_path, "rb") as fh:
        lean = fh.read()
    with open(ref_path, "rb") as fh:
        ref = fh.read()
    fpre, fsecs = split(full)
    lpre, lsecs = split(lean)
    fheads = [head(c) for c in fsecs]
    lheads = [head(c) for c in lsecs]

    say(len(lean) < CEILING, "lean prompt is %d bytes (ceiling %d, full prompt %d)" % (len(lean), CEILING, len(full)), "not under the ceiling")
    ffm, frest = frontmatter(fpre)
    lfm, lrest = frontmatter(lpre)
    if ffm is None or lfm is None:
        say(False, "both prompts open with a frontmatter block", "full: %s, lean: %s" % (ffm is not None, lfm is not None))
    else:
        say(norm_name(ffm) == norm_name(lfm), "frontmatter identical except the name line", "a frontmatter line differs")
        names = [line.rstrip(b"\r\n") for line in lfm if line.startswith(b"name:")]
        say(names == [b"name: heimdall-lean"], "frontmatter name is heimdall-lean", "found %r" % names)
    say(frest == lrest, "title and intro after the frontmatter are byte-equal", first_diff(frest, lrest))
    say(lheads == fheads, "same level-2 headings in the same order (%d sections)" % len(fheads), "lean has %d, full has %d" % (len(lheads), len(fheads)))

    lean_by_head = {}
    for chunk in lsecs:
        lean_by_head.setdefault(head(chunk), chunk)
    moved_at = []
    for fc in fsecs:
        h = head(fc)
        label = "section '%s'" % h.decode("utf-8", "replace")
        lc = lean_by_head.get(h)
        if lc is None:
            say(False, label + " is in the lean prompt", "its heading is missing")
            continue
        if not h.startswith(MOVED):
            say(lc == fc, label + " is byte-equal", first_diff(fc, lc))
            continue
        body = [line for line in lc.split(b"\n")[1:] if line.strip() and line.strip() != b"---"]
        say(len(body) == POINTER_LINES, label + " is a pointer of %d lines" % POINTER_LINES, "%d lines" % len(body))
        say(REF_PATH in b"\n".join(body), label + " pointer names the reference", "the path is absent")
        say(not any(line.startswith(b"#") for line in body) and lc.endswith(SEP),
            label + " pointer holds no sub-heading and ends with the separator", "a body line opens with # or the --- separator is gone")
        core = fc[:-len(SEP)] if fc.endswith(SEP) else fc
        at = ref.find(core)
        say(at >= 0, label + " is in the reference byte-equal", "not found in the reference")
        if at >= 0:
            moved_at.append(at)
    say(len(moved_at) == len(MOVED) and moved_at == sorted(moved_at), "the reference holds the three moved sections in order", "found at %r" % moved_at)
    return out


def mutate(src, dst, kind, args):
    with open(src, "rb") as fh:
        data = fh.read()
    pre, secs = split(data)

    def pick(prefix):
        for i, chunk in enumerate(secs):
            if chunk.startswith(prefix.encode()):
                return i
        sys.exit("no section starts with %r" % prefix)

    if kind == "body-byte":
        i = pick(args[0])
        lines = secs[i].split(b"\n")
        j = next(k for k in range(1, len(lines)) if lines[k].strip())
        lines[j] = b"X" + lines[j]
        secs[i] = b"\n".join(lines)
    elif kind == "drop-section":
        del secs[pick(args[0])]
    elif kind == "pointer-extra":
        i = pick(args[0])
        secs[i] = secs[i][:-len(SEP)] + b"A fourth line the pointer must not have.\n" + SEP
    elif kind == "pointer-nopath":
        i = pick(args[0])
        secs[i] = secs[i].replace(REF_PATH, b"skills/heimdall/references/elsewhere.md")
    elif kind == "fm-line":
        lines = pre.splitlines(True)
        j = next(k for k in range(min(len(lines), 40)) if lines[k].startswith(args[0].encode()))
        lines[j] = args[1].encode() + b"\n"
        pre = b"".join(lines)
    elif kind == "title-byte":
        lines = pre.splitlines(True)
        j = next(k for k in range(len(lines)) if lines[k].startswith(b"# "))
        lines[j] = lines[j].rstrip(b"\r\n") + b"X\n"
        pre = b"".join(lines)
    elif kind == "grow":
        secs[-1] = secs[-1] + b"z" * int(args[0])
    else:
        sys.exit("unknown mutation %r" % kind)
    new = pre + b"".join(secs)
    if new == data:
        sys.exit("the mutation changed nothing")
    with open(dst, "wb") as fh:
        fh.write(new)


def main(argv):
    if len(argv) == 5 and argv[1] == "check":
        lines = check(argv[2], argv[3], argv[4])
        sys.stdout.buffer.write(("\n".join(lines) + "\n").encode("utf-8"))
        return 1 if any(line.startswith("FAIL|") for line in lines) else 0
    if len(argv) >= 5 and argv[1] == "mutate":
        mutate(argv[2], argv[3], argv[4], argv[5:])
        return 0
    sys.exit("usage: lps.py check FULL LEAN REF | lps.py mutate SRC DST KIND [ARG...]")


sys.exit(main(sys.argv))
PY

echo "-- 1-4. the real files: shape, verbatim sections, pointers, moved text --"
out="$(python3 -I "$LPS" check "$FULL" "$LEAN" "$REF" 2>&1)"
while IFS= read -r line; do
  case "$line" in
    ok\|*) ok "${line#ok|}" ;;
    FAIL\|*) bad "${line#FAIL|}" ;;
    *) bad "checker said: $line" ;;
  esac
done <<EOF
$out
EOF

echo "-- 5. falsify: one injected defect per claim, on copies --"
cp "$FULL" "$T/full.md"; cp "$LEAN" "$T/lean.md"; cp "$REF" "$T/ref.md"
out="$(python3 -I "$LPS" check "$T/full.md" "$T/lean.md" "$T/ref.md" 2>&1)"; rc=$?
case "$out" in
  *FAIL\|*) bad "the unmodified copies are not GREEN: $out" ;;
  *) if [ "$rc" -eq 0 ]; then ok "the unmodified copies are GREEN (so a RED below is the defect's doing)"; else bad "the unmodified copies exit $rc: $out"; fi ;;
esac

# mutant DESC EXPECT WHICH KIND [ARG...]: one defect in the WHICH copy (full, lean or ref); the checker must exit 1 with a FAIL line holding EXPECT.
mutant() {
  local desc="$1" expect="$2" which="$3" kind="$4" f="$T/full.md" l="$T/lean.md" r="$T/ref.md" m="$T/mutant.md" src out rc fails
  shift 4
  case "$which" in full) src="$f" ;; lean) src="$l" ;; ref) src="$r" ;; esac
  if ! python3 -I "$LPS" mutate "$src" "$m" "$kind" "$@" 2>"$T/mutate.err"; then
    bad "mutant '$desc' could not be built: $(head -c 300 "$T/mutate.err")"
    return
  fi
  case "$which" in full) f="$m" ;; lean) l="$m" ;; ref) r="$m" ;; esac
  out="$(python3 -I "$LPS" check "$f" "$l" "$r" 2>&1)"; rc=$?
  fails="$(printf '%s\n' "$out" | grep '^FAIL|')"
  case "$fails" in
    *"$expect"*) if [ "$rc" -eq 1 ]; then ok "RED: $desc"; else bad "mutant '$desc' named but the checker exit is $rc"; fi ;;
    *) bad "mutant '$desc' not caught as '$expect' (exit $rc): $(printf '%s' "$fails" | head -3)" ;;
  esac
}
mutant "a byte of verbatim section 6"                      "## 6. Goal-Driven Execution"  lean body-byte "## 6. "
mutant "verbatim section 5.5 dropped from the lean prompt" "## 5.5 Agent Identity"        lean drop-section "## 5.5 "
mutant "a frontmatter line (tools) changed"                "identical except the name"    lean fm-line "tools:" "tools: Read"
mutant "the name left as heimdall in the lean prompt"      "name is heimdall-lean"        lean fm-line "name:" "name: heimdall"
mutant "the title changed in the lean prompt"              "title and intro"              lean title-byte
mutant "a fourth line in the section 4 pointer"            "## 4. Complexity"             lean pointer-extra "## 4. "
mutant "the section 5 pointer without the reference path"  "## 5. Agent Spawning"         lean pointer-nopath "## 5. "
mutant "a byte of moved section 2 in the reference"        "## 2. Prompt Analysis"        ref  body-byte "## 2. "
mutant "moved section 4 gone from the reference"           "## 4. Complexity"             ref  drop-section "## 4. "
mutant "a lean prompt grown past the ceiling"              "lean prompt is"               lean grow 4000
mutant "the full prompt drifts in verbatim section 7"      "## 7. Quality Gates"          full body-byte "## 7. "
mutant "the full prompt drifts in moved section 4"         "## 4. Complexity"             full body-byte "## 4. "

echo
echo "lean-prompt-sections: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
