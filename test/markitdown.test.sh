#!/usr/bin/env bash
# test/markitdown.test.sh — acceptance test for the document→markdown converter.
#
# Proves, against REAL temp files and the REAL converter tool (no canned output):
#
#   (a) CONVERSION FIDELITY — a sample document converts to markdown with its
#       structure preserved (a heading, a list, and a TABLE survive). Run only
#       when markitdown is importable on the host; otherwise SKIPPED honestly
#       (the security + graceful-skip gates below still run, so the test stays
#       meaningful on a stripped host).
#   (b) SECURITY GATE — a remote-URI input (incl. the 169.254.169.254 cloud
#       metadata SSRF vector) and an unsafe path (a `..` escape and a symlink
#       escaping the allowed root) are REFUSED with the security exit code, NOT
#       fetched / read. This gate runs whether or not markitdown is installed.
#   (c) GRACEFUL SKIP — when markitdown is absent, the converter exits 0 (a
#       missing optional dep must never abort a calling task run), printing a
#       clear install hint rather than crashing.
#
# Exit 0 = every executed assertion passed. Non-zero = a regression.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MD="$ROOT/bin/heimdall-md"
LIB="$ROOT/bin/lib/md_convert.py"

[ -x "$MD" ] || { echo "FATAL: $MD not executable" >&2; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }

PASS=0
FAIL=0
SKIPPED=0
ok()    { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad()   { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
note()  { SKIPPED=$((SKIPPED+1)); printf "  \033[33mSKIP\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "markitdown-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

ROOTDIR="$WORK/root"
OUTSIDE="$WORK/outside"
mkdir -p "$ROOTDIR" "$OUTSIDE"

# ── Discover a python interpreter that can import markitdown (for assertion a).
# Prefer the default python3; if it lacks markitdown, look for a MARKITDOWN_PY
# override (a venv interpreter). The converter itself always uses the default
# python3, so we mirror that: assertion (a) runs the tool with a PATH that makes
# the markitdown-capable interpreter the resolved `python3`.
DEFAULT_PY="$(command -v python3 || command -v python || true)"
[ -n "$DEFAULT_PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

MD_PY=""
if "$DEFAULT_PY" -c "import markitdown" >/dev/null 2>&1; then
  MD_PY="$DEFAULT_PY"
elif [ -n "${MARKITDOWN_PY:-}" ] && "${MARKITDOWN_PY}" -c "import markitdown" >/dev/null 2>&1; then
  MD_PY="${MARKITDOWN_PY}"
fi

# ── (a) CONVERSION FIDELITY (only if markitdown is importable) ─────────────────
SAMPLE="$ROOTDIR/spec.html"
cat > "$SAMPLE" <<'HTML'
<html><body>
<h1>Conversion Spec</h1>
<h2>Requirements</h2>
<ul><li>Alpha requirement</li><li>Beta requirement</li></ul>
<h2>Data Model</h2>
<table>
<tr><th>Field</th><th>Type</th></tr>
<tr><td>id</td><td>int</td></tr>
<tr><td>name</td><td>string</td></tr>
</table>
</body></html>
HTML

if [ -n "$MD_PY" ]; then
  # Run the tool with a PATH whose `python3` is the markitdown-capable one, so we
  # exercise the SAME code path a real host with markitdown installed would.
  CONVBIN="$WORK/convbin"
  mkdir -p "$CONVBIN"
  ln -sf "$MD_PY" "$CONVBIN/python3"
  OUT_MD="$WORK/spec.md"
  set +e
  PATH="$CONVBIN:$PATH" "$MD" "$SAMPLE" --root "$ROOTDIR" --out "$OUT_MD" 2>"$WORK/a.err"
  ARC=$?
  set -e
  if [ "$ARC" -eq 0 ] && [ -f "$OUT_MD" ] \
     && grep -qE '^#[[:space:]]+Conversion Spec' "$OUT_MD" \
     && grep -qE '^(\*|-)[[:space:]]+Alpha requirement' "$OUT_MD" \
     && grep -qE '^\|[[:space:]]*Field[[:space:]]*\|[[:space:]]*Type[[:space:]]*\|' "$OUT_MD" \
     && grep -qE '^\|[[:space:]]*id[[:space:]]*\|[[:space:]]*int[[:space:]]*\|' "$OUT_MD"; then
    ok "(a) document converts to markdown with heading + list + table preserved"
  else
    bad "(a) conversion structure not preserved (rc=$ARC)"
    echo "    --- markdown output ---"; sed 's/^/    /' "$OUT_MD" 2>/dev/null
    echo "    --- stderr ---"; sed 's/^/    /' "$WORK/a.err"
  fi
else
  note "(a) conversion fidelity — markitdown not importable on host (security + skip gates still run)"
fi

# ── (b) SECURITY GATE — remote URI / SSRF / unsafe path are REFUSED ────────────
# A refusal is exit 4 from the converter (a hard security failure, NOT a graceful
# skip). These run regardless of markitdown's presence: the guards execute
# BEFORE any converter import, so a remote input never becomes a fetch.

refuse_check() {
  # $1 label ; $2 input ; runs the converter and asserts exit 4 (REFUSED).
  local label="$1" input="$2" rc
  set +e
  "$MD" "$input" --root "$ROOTDIR" >/dev/null 2>"$WORK/b.err"
  rc=$?
  set -e
  if [ "$rc" -eq 4 ]; then
    ok "(b) refused: $label (exit 4, not fetched/read)"
  else
    bad "(b) NOT refused: $label (exit $rc — expected 4)"; sed 's/^/    /' "$WORK/b.err"
  fi
}

refuse_check "http remote URI"          "http://example.com/payload.pdf"
refuse_check "https remote URI"         "https://example.com/payload.pdf"
refuse_check "file:// URI"              "file:///etc/passwd"
refuse_check "data: URI"                "data:text/html,<b>x</b>"
refuse_check "169.254.169.254 metadata" "http://169.254.169.254/latest/meta-data/"

# unsafe local paths
SECRET="$OUTSIDE/secret.txt"
echo "TOPSECRET-DO-NOT-READ" > "$SECRET"
# a dotdot escape from the allowed root to the sibling outside dir
refuse_check "dotdot path escape"       "../outside/secret.txt"
# a symlink inside the root that points OUTSIDE the root
ln -sf "$SECRET" "$ROOTDIR/evil.txt"
refuse_check "symlink escaping root"    "evil.txt"
# an absolute path entirely outside the root
refuse_check "absolute path outside root" "$SECRET"

# Proof the refusal did NOT leak the secret: the converter must never emit it.
set +e
LEAK="$("$MD" "../outside/secret.txt" --root "$ROOTDIR" 2>&1)"
set -e
if grep -q "TOPSECRET-DO-NOT-READ" <<<"$LEAK"; then
  bad "(b) SECRET LEAKED through a refused path — guard is not actually blocking"
else
  ok "(b) refused path leaked no file content (the guard blocks before any read)"
fi

# ── (c) GRACEFUL SKIP when markitdown is absent ────────────────────────────────
# When markitdown is absent, the converter must exit 0 with a clear install hint
# (a missing optional dep must never abort a calling task run).
if [ -z "$MD_PY" ]; then
  # Host genuinely lacks markitdown — exercise the real absent path directly.
  GOOD="$ROOTDIR/data.csv"
  printf 'name,age\nAda,36\n' > "$GOOD"
  set +e
  SKIP_OUT="$("$MD" "$GOOD" --root "$ROOTDIR" 2>&1)"
  SRC=$?
  set -e
  if [ "$SRC" -eq 0 ] && grep -qi "markitdown" <<<"$SKIP_OUT"; then
    ok "(c) markitdown absent → exits 0 with a clear skip/install hint (no crash)"
  else
    bad "(c) graceful-skip wrong (rc=$SRC)"; printf '%s\n' "$SKIP_OUT" | sed 's/^/    /'
  fi
else
  # markitdown IS present on host; simulate absence with a wrapper python that
  # raises ModuleNotFoundError on the markitdown import, so the lib's lazy import
  # degrades exactly as on a host without the package.
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/python3" <<EOF
#!/usr/bin/env bash
exec "$MD_PY" -c '
import sys, builtins
_orig = builtins.__import__
def _imp(name, *a, **k):
    if name == "markitdown" or name.startswith("markitdown."):
        raise ModuleNotFoundError("No module named \"markitdown\" (test-forced)")
    return _orig(name, *a, **k)
builtins.__import__ = _imp
sys.argv = ["md_convert.py"] + sys.argv[1:]
exec(open("$LIB").read())
' "\$@"
EOF
  chmod +x "$FAKEBIN/python3"
  GOOD="$ROOTDIR/data.csv"
  printf 'name,age\nAda,36\n' > "$GOOD"
  set +e
  SKIP_OUT="$(PATH="$FAKEBIN:$PATH" "$MD" "$GOOD" --root "$ROOTDIR" 2>&1)"
  SRC=$?
  set -e
  if [ "$SRC" -eq 0 ] && grep -qi "markitdown" <<<"$SKIP_OUT"; then
    ok "(c) markitdown absent (simulated) → exits 0 with skip/install hint (no crash)"
  else
    bad "(c) graceful-skip wrong (rc=$SRC)"; printf '%s\n' "$SKIP_OUT" | sed 's/^/    /'
  fi
fi

# ── (d) DoS bound — an oversize input is REFUSED before any read (audit #3) ──
# Decompression-bomb / huge-file defense: a file exceeding HEIMDALL_MD_MAX_BYTES
# is refused with the security exit code, before the converter opens it.
BIG="$ROOTDIR/big.html"
head -c 4096 /dev/zero | tr '\0' a > "$BIG"
set +e
OVER_OUT="$(HEIMDALL_MD_MAX_BYTES=100 "$MD" "$BIG" --root "$ROOTDIR" 2>&1)"
OVER_RC=$?
set -e
if [ "$OVER_RC" -eq 4 ] && grep -qi 'oversize\|too large' <<<"$OVER_OUT"; then
  ok "(d) oversize input refused (exit 4) before read — DoS size cap holds"
else
  bad "(d) oversize not refused (rc=$OVER_RC): $(printf '%s' "$OVER_OUT" | head -1)"
fi

# ── (e) EMBEDDED-RESOURCE SSRF — the offline session kills ALL egress (audit #1) ──
# convert_local is local for the top-level file, but a malicious HTML/SVG can embed
# remote refs (<img src=169.254.169.254...>). The injected offline requests.Session
# must raise on EVERY outbound request regardless of the installed converter.
set +e
EGRESS="$(python3 -c '
import sys; sys.path.insert(0,"'"$ROOT"'/bin/lib"); import md_convert as m
s = m.build_offline_session()
try:
    s.get("http://169.254.169.254/latest/meta-data/", timeout=2)
    print("EGRESS-NOT-BLOCKED")
except Exception as e:
    print("BLOCKED:" + type(e).__name__)
' 2>&1)"
set -e
if grep -q '^BLOCKED:' <<<"$EGRESS"; then
  ok "(e) embedded-URL egress killed: offline session raises ($EGRESS) — no fetch primitive"
else
  bad "(e) offline session did not block egress: $EGRESS"
fi

# ── (f) TIMEOUT — a slow conversion is interrupted, refused cleanly (audit #3) ──
set +e
TMO="$(python3 -c '
import sys, time; sys.path.insert(0,"'"$ROOT"'/bin/lib"); import md_convert as m
try:
    m._run_with_timeout(lambda: time.sleep(5), 1)
    print("NO-TIMEOUT")
except m.ConversionTimeout:
    print("TIMEOUT-REFUSED")
except Exception as e:
    print("OTHER:" + type(e).__name__)
' 2>&1)"
set -e
if grep -q 'TIMEOUT-REFUSED' <<<"$TMO"; then
  ok "(f) slow conversion interrupted + refused cleanly — DoS timeout holds"
else
  bad "(f) timeout did not fire: $TMO"
fi

echo
echo "  markitdown tests: $PASS passed, $FAIL failed, $SKIPPED skipped"
[ "$FAIL" -eq 0 ]
