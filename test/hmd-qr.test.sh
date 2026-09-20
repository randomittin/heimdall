#!/usr/bin/env bash
# test/hmd-qr.test.sh
#
# Oracle for bin/lib/hmd_qr.py -- a stdlib-only (zero third-party runtime
# deps) QR Code encoder + terminal renderer, built so `hmd app connect` can
# print a scannable QR of the pairing URL (Wave 1.2,
# .planning/plans/PLAN-hmd-app-connect.md).
#
# Independent checks, named per case so it is always clear which one ran:
#   - golden literal matrix (case 1): captured from the encoder this cycle
#     and differentially validated, at authoring time, bit-for-bit against
#     the `qrcode` PyPI package (a dev-time oracle only -- never a runtime
#     dependency of bin/lib/hmd_qr.py itself). Case 1b re-runs that same
#     cross-check LIVE whenever `qrcode` happens to be importable on the
#     machine running this suite, and prints an explicit SKIP line naming
#     why when it is not, per the brief's "record which check was actually
#     available, or say none".
#   - structural invariants (case 2): re-derived directly from ISO/IEC 18004
#     (finder geometry 6.3.4, timing 6.3.5, dark module 6.3.8, format-info
#     BCH(15,5) Annex C) in plain Python written into THIS file -- nothing
#     here imports bin/lib/hmd_qr.py's internals, so a passing case means the
#     output matches the published spec, not merely itself.
#   - real decode-based scanning (cv2.QRCodeDetector, pyzbar/libzbar,
#     zbarimg/qrencode CLIs): explored during development (see task notes);
#     NOT wired into this automated suite because cv2/PIL/numpy are not part
#     of this repo's stdlib-only contract and pulling them in here would
#     make the test suite depend on exactly the kind of third-party stack
#     bin/lib/hmd_qr.py itself is built to avoid. Recorded transparently
#     rather than silently omitted.
#
# Cases:
#   0.  python3 -m py_compile bin/lib/hmd_qr.py is clean
#   1.  golden matrix: "hmd" ECC L == known-good 21x21 grid (+ live qrcode
#       cross-check, case 1b, when the package happens to be importable)
#   2.  structural invariants at two versions (v1 and v5): 3 finder
#       patterns, timing alternation, dark module, format-info BCH(15,5)
#       re-derivation + decoded ECC level, size == 17 + 4*version
#   3.  capacity: a ~100-char pairing-style URL selects version <=6 at ECC L;
#       300 'x' characters errors cleanly (nonzero exit, names the capacity)
#   4.  determinism: same input run twice -> byte-identical output, for the
#       default half-block render, --ascii, and --matrix
#   5.  CLI edge cases: no text and explicit empty text both error cleanly;
#       non-UTF8-safe argv bytes never produce an uncaught traceback;
#       --ascii renders without error
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QR="$REPO/bin/lib/hmd_qr.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
note() { printf '       %s\n' "$1"; }

echo "hmd-qr (stdlib QR encoder + ASCII render, Wave 1.2 oracle)"

# ── preconditions: a not-yet-landed author is an explicit SKIP, never a crash ─
if [ ! -f "$QR" ]; then
  printf '  SKIP %s is absent -- Wave 1.2 has not landed\n' "$QR"
  printf '\n0 passed, 0 failed, 1 skipped (hmd-qr: author not landed)\n'
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf '  FAIL required tool missing: python3\n'
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

# ── sandbox ─────────────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ═══ 0. compiles clean ══════════════════════════════════════════════════════
if python3 -m py_compile "$QR" 2>"$TMPROOT/pycompile.err"; then
  ok "0. python3 -m py_compile bin/lib/hmd_qr.py is clean"
else
  bad "0. py_compile failed:"
  sed 's/^/       | /' "$TMPROOT/pycompile.err"
fi

# ═══ 1. golden matrix fixture: "hmd" ECC L ══════════════════════════════════
# Frozen 21x21 grid, captured from bin/lib/hmd_qr.py and diffed bit-for-bit
# against the `qrcode` PyPI package (dev-time oracle) before being pinned
# here. version=1, mask=0, size=21=17+4*1.
GOLDEN_HMD_V1L='111111100101101111111
100000100111001000001
101110101101101011101
101110100101001011101
101110100010101011101
100000100000101000001
111111101010101111111
000000001101100000000
111011111111011000100
101001001000001000111
111101110110100011111
111011010010001000010
010011101100101010000
000000001011010100011
111111101111011100111
100000101001110111001
101110101011011100101
101110100110001000110
101110101100100010001
100000101000001000110
111111101110101010111'

GOT_HMD="$(python3 "$QR" "hmd" --ecc L --matrix 2>"$TMPROOT/case1.err")"
if [ "$GOT_HMD" = "$GOLDEN_HMD_V1L" ]; then
  ok "1. 'hmd' ECC L matches the known-good 21x21 grid (captured + qrcode-cross-checked at authoring time)"
else
  bad "1. 'hmd' ECC L matrix drifted from the frozen golden grid; diff (golden < / got >):"
  diff <(printf '%s' "$GOLDEN_HMD_V1L") <(printf '%s' "$GOT_HMD") | head -10 | sed 's/^/       | /'
fi

if python3 -c "import qrcode" >/dev/null 2>&1; then
  cat > "$TMPROOT/oracle_check.py" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import hmd_qr
import qrcode
import qrcode.constants

qr = hmd_qr.encode_qr("hmd", ecc="L")
ref = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L, box_size=1, border=0)
ref.add_data("hmd")
ref.make(fit=True)
ref_matrix = [[bool(v) for v in row] for row in ref.get_matrix()]

if qr.matrix == ref_matrix:
    print("MATCH")
    sys.exit(0)
print(f"MISMATCH: hmd_qr version={qr.version} mask={qr.mask} size={qr.size}; "
      f"qrcode version={ref.version}")
sys.exit(1)
PYEOF
  if python3 "$TMPROOT/oracle_check.py" "$REPO/bin/lib" >"$TMPROOT/case1b.out" 2>"$TMPROOT/case1b.err"; then
    ok "1b. LIVE independent check: encode_qr('hmd','L').matrix == the 'qrcode' PyPI package's own matrix, bit for bit"
  else
    bad "1b. live qrcode-package cross-check mismatched:"
    sed 's/^/       | /' "$TMPROOT/case1b.out" "$TMPROOT/case1b.err"
  fi
else
  note "1b. SKIP live qrcode-package cross-check -- 'qrcode' is not importable on this machine"
  note "    (the case-1 golden literal was still validated against it at authoring time; no other"
  note "    independent QR oracle -- zbarimg, qrencode, pyzbar's native libzbar -- is available here)"
fi

# ═══ 2. structural invariants, re-derived from ISO/IEC 18004 directly ═══════
# Deliberately does not import bin/lib/hmd_qr.py: this checks the OUTPUT
# against the published spec, not against the module's own internals.
cat > "$TMPROOT/check_structural.py" <<'PYEOF'
import sys

version = int(sys.argv[1])
expected_ecc_bits = {"L": 0b01, "M": 0b00, "Q": 0b11, "H": 0b10}[sys.argv[2]]
lines = [line for line in sys.stdin.read().splitlines() if line]
size = len(lines)
grid = [[c == "1" for c in row] for row in lines]
errors = []

expected_size = 17 + 4 * version
if size != expected_size:
    errors.append(f"size {size} != 17+4*{version}={expected_size}")

def finder_ok(top, left):
    for r in range(7):
        for c in range(7):
            expect = (r in (0, 6) or c in (0, 6)) or (2 <= r <= 4 and 2 <= c <= 4)
            if grid[top + r][left + c] != expect:
                return False, (r, c, expect)
    return True, None

for name, top, left in (("top-left", 0, 0), ("top-right", 0, size - 7), ("bottom-left", size - 7, 0)):
    okf, where = finder_ok(top, left)
    if not okf:
        errors.append(f"finder {name} wrong at offset {where}")

for i in range(8, size - 8):
    if grid[6][i] != (i % 2 == 0):
        errors.append(f"timing row6 wrong at col {i}")
    if grid[i][6] != (i % 2 == 0):
        errors.append(f"timing col6 wrong at row {i}")

dark_r, dark_c = 4 * version + 9, 8
if not grid[dark_r][dark_c]:
    errors.append(f"dark module ({dark_r},{dark_c}) is not dark")

def bit(r, c):
    return 1 if grid[r][c] else 0

copy1 = [None] * 15
for i in range(6):
    copy1[i] = bit(i, 8)
copy1[6] = bit(7, 8)
copy1[7] = bit(8, 8)
copy1[8] = bit(8, 7)
for i in range(9, 15):
    copy1[i] = bit(8, 14 - i)

masked = 0
for i, b in enumerate(copy1):
    masked |= (b << i)
unmasked = masked ^ 0b101010000010010          # Annex C XOR mask (0x5412)
data5 = (unmasked >> 10) & 0b11111
ecc10 = unmasked & 0b1111111111

def bch_remainder(value, ecc_bits, generator):
    dividend = value << ecc_bits
    gen_len = generator.bit_length()
    while dividend.bit_length() > ecc_bits:
        dividend ^= generator << (dividend.bit_length() - gen_len)
    return dividend

recomputed_ecc = bch_remainder(data5, 10, 0b10100110111)   # Annex C generator (0x537)
if recomputed_ecc != ecc10:
    errors.append(
        f"format info BCH(15,5) invalid: data5={data5:05b} stored_ecc={ecc10:010b} "
        f"recomputed={recomputed_ecc:010b}"
    )

decoded_ecc_level_bits = (data5 >> 3) & 0b11
if decoded_ecc_level_bits != expected_ecc_bits:
    errors.append(f"format info ECC-level field {decoded_ecc_level_bits:02b} != expected {expected_ecc_bits:02b}")

if errors:
    print("FAIL: " + "; ".join(errors))
    sys.exit(1)
print("OK")
PYEOF

python3 "$QR" "hmd" --ecc L --matrix 2>"$TMPROOT/case2a.err" \
  | python3 "$TMPROOT/check_structural.py" 1 L >"$TMPROOT/case2a.out" 2>&1
if [ "$?" -eq 0 ] && [ "$(cat "$TMPROOT/case2a.out")" = "OK" ]; then
  ok "2a. v1-L 'hmd': finder x3, timing alternation, dark module, format-info BCH(15,5), size=21 (independently re-derived from ISO/IEC 18004)"
else
  bad "2a. structural invariant failure at v1-L: $(cat "$TMPROOT/case2a.out")"
fi

A80="$(python3 -c 'print("a" * 80)')"
python3 "$QR" "$A80" --ecc L --matrix 2>"$TMPROOT/case2b.err" \
  | python3 "$TMPROOT/check_structural.py" 5 L >"$TMPROOT/case2b.out" 2>&1
if [ "$?" -eq 0 ] && [ "$(cat "$TMPROOT/case2b.out")" = "OK" ]; then
  ok "2b. v5-L (80 'a' chars, forces version 5 -- V4 ECC-L capacity is 78): same invariants hold, size=37"
else
  bad "2b. structural invariant failure at v5-L: $(cat "$TMPROOT/case2b.out")"
fi

# ═══ 3. capacity: minimal-version selection + clean overflow error ══════════
URL100="$(python3 -c 'print(("https://my-host.tailnet-1234.ts.net/?token=" + "a" * 100)[:100])')"
if [ "${#URL100}" -ne 100 ]; then
  bad "3. harness bug: URL100 fixture is ${#URL100} chars, not 100"
else
  ROWS="$(python3 "$QR" "$URL100" --ecc L --matrix 2>"$TMPROOT/case3a.err" | wc -l | tr -d ' ')"
  if [ -n "$ROWS" ] && [ "$((( ROWS - 17) % 4))" -eq 0 ]; then
    VERSION=$(( (ROWS - 17) / 4 ))
    if [ "$VERSION" -le 6 ] && [ "$VERSION" -ge 1 ]; then
      ok "3. a 100-char pairing-style URL at ECC L selects version $VERSION (<=6, size $ROWS)"
    else
      bad "3. 100-char URL selected version $VERSION, expected <=6 (size $ROWS)"
    fi
  else
    bad "3. could not derive a version from CLI output (rows=$ROWS):"
    sed 's/^/       | /' "$TMPROOT/case3a.err"
  fi
fi

X300="$(python3 -c 'print("x" * 300)')"
ERR300="$TMPROOT/case3b.err"
if python3 "$QR" "$X300" --ecc L >/dev/null 2>"$ERR300"; then
  bad "3b. 300 'x' characters at ECC L was ACCEPTED (expected a clean, nonzero-exit capacity error)"
else
  if grep -qi 'too long' "$ERR300" && grep -q '271' "$ERR300"; then
    ok "3b. 300 chars at ECC L errors cleanly, nonzero exit, names the version-10 capacity (271 bytes): $(head -c 160 "$ERR300")"
  else
    bad "3b. 300-char input errored but message doesn't name the capacity clearly: $(head -c 200 "$ERR300")"
  fi
fi

# ═══ 4. determinism: same input twice -> byte-identical output ═════════════
OUT_A="$(python3 "$QR" "hmd fixture text" --ecc M)"
OUT_B="$(python3 "$QR" "hmd fixture text" --ecc M)"
if [ "$OUT_A" = "$OUT_B" ] && [ -n "$OUT_A" ]; then
  ok "4a. default half-block render is deterministic across two runs"
else
  bad "4a. default render differs across two runs on identical input"
fi

MTX_A="$(python3 "$QR" "hmd fixture text" --ecc M --matrix)"
MTX_B="$(python3 "$QR" "hmd fixture text" --ecc M --matrix)"
if [ "$MTX_A" = "$MTX_B" ] && [ -n "$MTX_A" ]; then
  ok "4b. --matrix output is deterministic across two runs"
else
  bad "4b. --matrix output differs across two runs on identical input"
fi

ASC_A="$(python3 "$QR" "hmd fixture text" --ecc M --ascii)"
ASC_B="$(python3 "$QR" "hmd fixture text" --ecc M --ascii)"
if [ "$ASC_A" = "$ASC_B" ] && [ -n "$ASC_A" ]; then
  ok "4c. --ascii output is deterministic across two runs"
else
  bad "4c. --ascii output differs across two runs on identical input"
fi

# ═══ 5. CLI edge cases ═══════════════════════════════════════════════════════
ERR_NOARG="$TMPROOT/case5a.err"
if python3 "$QR" >/dev/null 2>"$ERR_NOARG"; then
  bad "5a. no positional text argument was ACCEPTED (expected a clean empty-input error)"
else
  if grep -qi 'empty' "$ERR_NOARG"; then
    ok "5a. no text argument -> nonzero exit, error names empty input"
  else
    bad "5a. no text argument errored but message doesn't mention empty input: $(head -c 160 "$ERR_NOARG")"
  fi
fi

ERR_EMPTYSTR="$TMPROOT/case5b.err"
if python3 "$QR" "" >/dev/null 2>"$ERR_EMPTYSTR"; then
  bad "5b. an explicit empty-string argument was ACCEPTED"
else
  if grep -qi 'empty' "$ERR_EMPTYSTR"; then
    ok "5b. explicit empty-string argument -> nonzero exit, error names empty input"
  else
    bad "5b. empty-string argument errored but message doesn't mention empty input: $(head -c 160 "$ERR_EMPTYSTR")"
  fi
fi

# Non-UTF8-safe argv bytes (a lone 0xff 0xfe pair is not valid UTF-8 on its
# own): Python's POSIX argv decoding round-trips these via surrogateescape,
# and encode_qr() is documented to re-encode the same way, so this must
# either render cleanly or fail with a clean ValueError -- never an uncaught
# traceback.
RAW_ARG=$'\xff\xfe-non-utf8-safe'
OUT_RAW="$TMPROOT/case5c.out"
ERR_RAW="$TMPROOT/case5c.err"
python3 "$QR" "$RAW_ARG" --ecc L >"$OUT_RAW" 2>"$ERR_RAW"
RC_RAW=$?
if [ "$RC_RAW" -le 1 ] && ! grep -q 'Traceback' "$ERR_RAW"; then
  ok "5c. non-UTF8-safe argv bytes handled cleanly (exit $RC_RAW, no Python traceback)"
else
  bad "5c. non-UTF8-safe argv bytes caused an unclean failure (exit $RC_RAW):"
  sed 's/^/       | /' "$ERR_RAW"
fi

if python3 "$QR" "ascii fallback check" --ascii >"$TMPROOT/case5d.out" 2>"$TMPROOT/case5d.err" \
   && [ -s "$TMPROOT/case5d.out" ] && grep -q '#' "$TMPROOT/case5d.out"; then
  ok "5d. --ascii renders non-empty ##/space output"
else
  bad "5d. --ascii render failed or produced no '#' characters:"
  sed 's/^/       | /' "$TMPROOT/case5d.err"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
