#!/usr/bin/env bash
# test/receipts-worker-contract.test.sh -- RP3 hosted receipts: the Python half of the cross-language
# contract between bin/lib/runhmd_receipt.py and receipts-worker/ (the Cloudflare Worker).
#
# receipts-worker/contract/vectors.json records what the Python reference does: the canonical bytes
# (or the refusal) for 130+ JSON texts, and the verify outcome for 65 would-be receipt files.
# receipts-worker/test/vectors.spec.ts replays it against the Worker's JavaScript (npm test in that
# directory, workerd, no network). THIS suite replays it against the Python, so the recorded
# outcomes cannot rot, and checks the pieces that must stay in lockstep without a Node toolchain.
#
#   [V] VECTORS    every canonical case gives the recorded bytes, every receipt the recorded outcome;
#                  the replay is falsifiable: four tampered copies of the file must each go red
#   [G] GENERATOR  scripts/gen-vectors.py still runs, and records the same names with the same
#                  outcomes (they do not depend on its throwaway signing key)
#   [S] SCHEMAS    receipts-worker/schema/* are byte-identical to docs/schemas/* (the single source)
#   [W] WORKER     the package's shape: bindings, migrations, no key or token material, nothing the
#                  Workers runtime cannot run
#   [T] CLI        the real `hmd receipt verify` (bin/heimdall-receipt) gives the matching verdict on
#                  the same bytes: what the Worker accepts verifies, what it refuses does not
#
# Hermetic: no network, no deploy, no key outside memory and a throwaway dir.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
W="$REPO/receipts-worker"
VECTORS="$W/contract/vectors.json"
PYLIB="$REPO/bin/lib"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

command -v jq      >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }
python3 -c 'import cryptography' >/dev/null 2>&1 || python3 -c 'import nacl' >/dev/null 2>&1 || { echo "an Ed25519 backend (cryptography or pynacl) is required" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/receipts-worker-contract-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/replay.py" <<'PY'
"""replay.py PYLIB VECTORS: replay a vectors file against bin/lib/runhmd_receipt.py. Exit 0 iff every
recorded value holds; every mismatch is printed."""
import base64, json, sys

sys.path.insert(0, sys.argv[1])
import runhmd_receipt as rr

doc = json.load(open(sys.argv[2], encoding="utf-8"))
bad = []
if doc.get("max_receipt_bytes") != rr.MAX_RECEIPT_BYTES:
    bad.append("max_receipt_bytes %r != %r" % (doc.get("max_receipt_bytes"), rr.MAX_RECEIPT_BYTES))
for case in doc["canonical"]:
    try:
        got = rr.canonical(json.loads(case["json"])).hex()
    except ValueError:
        got = None
    if got != case["hex"]:
        bad.append("canonical %s: got %r, recorded %r" % (case["name"], got, case["hex"]))
trust = {rr.key_id_of(anchor): anchor for anchor in doc["anchors"]}
for case in doc["receipts"]:
    raw = base64.b64decode(case["raw_b64"])
    if case.get("pad_to"):
        raw += b" " * (case["pad_to"] - len(raw))
    try:
        rr.verify_bytes(raw, trust)
        got = "ok"
    except rr.ReceiptError as exc:
        got = exc.kind
    if got != case["outcome"]:
        bad.append("receipt %s: got %s, recorded %s" % (case["name"], got, case["outcome"]))
for line in bad:
    print(line)
print("%d canonical, %d receipt vectors, %d mismatches" % (len(doc["canonical"]), len(doc["receipts"]), len(bad)))
sys.exit(1 if bad else 0)
PY

# ══════════════════════════════════════════════════════════════════════════════
echo "[V] vectors replayed against bin/lib/runhmd_receipt.py"
[ -f "$VECTORS" ] && ok "receipts-worker/contract/vectors.json exists" || bad "receipts-worker/contract/vectors.json exists"
check "the vectors file is JSON with anchors, canonical[] and receipts[]" \
  jq -e '(.anchors|length)>=1 and (.canonical|length)>=100 and (.receipts|length)>=60' "$VECTORS"
check "the recorded outcomes span ok, not_json, schema, not_canonical, unknown_key and bad_signature" \
  jq -e '([.receipts[].outcome]|unique) == ["bad_signature","not_canonical","not_json","ok","schema","unknown_key"]' "$VECTORS"
check "some canonical cases are refusals (null) and some are written" \
  jq -e '([.canonical[]|select(.hex==null)]|length)>=8 and ([.canonical[]|select(.hex!=null)]|length)>=100' "$VECTORS"
OUT="$(python3 "$TMP/replay.py" "$PYLIB" "$VECTORS" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "Python gives every recorded canonical byte string and verify outcome ($(printf '%s' "$OUT" | tail -1))" \
  || bad "Python disagrees with the recorded vectors: $(printf '%s' "$OUT" | head -5 | tr '\n' '|')"

mutant() {  # mutant <description> <jq filter>: the replay must go red on the tampered copy
  local desc="$1" filter="$2" f="$TMP/mutant.$RANDOM.json"
  jq "$filter" "$VECTORS" >"$f"
  if python3 "$TMP/replay.py" "$PYLIB" "$f" >/dev/null 2>&1; then bad "mutant not caught: $desc"; else ok "mutant caught: $desc"; fi
}
mutant "a receipt's recorded outcome changed (ok -> bad_signature)"  '(.receipts[0].outcome)="bad_signature"'
mutant "a canonical vector's recorded bytes changed"                  '(.canonical[0].hex)="00"'
mutant "a receipt's bytes replaced while its outcome stays ok"        '(.receipts[0].raw_b64)="e30="'
mutant "the trust anchor removed"                                     '.anchors=[]'

# ══════════════════════════════════════════════════════════════════════════════
echo "[G] the generator still records the same cases"
if python3 "$W/scripts/gen-vectors.py" --out "$TMP/regen.json" >"$TMP/regen.log" 2>&1; then
  ok "scripts/gen-vectors.py runs ($(tail -1 "$TMP/regen.log" | cut -c1-70))"
else
  bad "scripts/gen-vectors.py fails: $(tail -3 "$TMP/regen.log" | tr '\n' '|')"
fi
check "the regenerated file replays clean against the Python (a fresh key, the same behaviour)" \
  python3 "$TMP/replay.py" "$PYLIB" "$TMP/regen.json"
SHAPE='[.receipts[]|[.name,.outcome]], [.canonical[]|select(.name|startswith("random-")|not)|[.name,.hex]]'
if [ "$(jq -c "$SHAPE" "$VECTORS")" = "$(jq -c "$SHAPE" "$TMP/regen.json")" ]; then
  ok "regenerating records the same receipt names and outcomes, and the same hand-written canonical bytes"
else
  bad "regenerating changes the recorded cases: run scripts/gen-vectors.py and review the diff"
fi
check "the committed anchor differs from the regenerated one (the signing key is never kept)" \
  bash -c '[ "$(jq -r ".anchors[0]" "$1")" != "$(jq -r ".anchors[0]" "$2")" ]' _ "$VECTORS" "$TMP/regen.json"

# ══════════════════════════════════════════════════════════════════════════════
echo "[S] schema copies"
for name in runhmd.receipt.v1.json runhmd.verdict.v1.json; do
  check "receipts-worker/schema/$name is byte-identical to docs/schemas/$name" cmp -s "$REPO/docs/schemas/$name" "$W/schema/$name"
done
cp "$W/schema/runhmd.receipt.v1.json" "$TMP/drift.json"; printf ' ' >>"$TMP/drift.json"
check "control: the comparison does fail on a one-byte difference" bash -c '! cmp -s "$1" "$2"' _ "$REPO/docs/schemas/runhmd.receipt.v1.json" "$TMP/drift.json"

# ══════════════════════════════════════════════════════════════════════════════
echo "[W] package shape"
check "wrangler.toml binds the RECEIPT and THROTTLE Durable Objects" \
  bash -c 'grep -q "^name = \"RECEIPT\"" "$1" && grep -q "^name = \"THROTTLE\"" "$1"' _ "$W/wrangler.toml"
check "wrangler.toml migrates both classes as SQLite classes" \
  bash -c 'grep -q "new_sqlite_classes = \[\"ReceiptDO\", \"ThrottleDO\"\]" "$1"' _ "$W/wrangler.toml"
check "wrangler.toml carries no key, token or secret value (only the public vars)" \
  bash -c '! grep -Eiq "^(RECEIPT_PUBKEYS|API_TOKEN_SHA256S|[A-Z_]*SECRET[A-Z_]*|[A-Z_]*TOKEN[A-Z_]*) *=" "$1"' _ "$W/wrangler.toml"
check ".gitignore keeps .dev.vars and node_modules out of the tree" \
  bash -c 'grep -qx "\.dev\.vars" "$1" && grep -qx "node_modules" "$1"' _ "$W/.gitignore"
check "no .dev.vars or node_modules file is tracked" \
  bash -c '[ -z "$(git -C "$1" ls-files receipts-worker | grep -E "(^|/)(\.dev\.vars|node_modules)(/|$)")" ]' _ "$REPO"
check "no private key block, seed or signing secret is committed in receipts-worker/ (outside node_modules)" \
  bash -c '! grep -rEIl "BEGIN [A-Z ]*PRIVATE KEY|\"seed\"" "$1" --exclude-dir=node_modules --exclude-dir=.wrangler' _ "$W"
check "the vectors file holds only the public anchor: no seed or secret field" \
  bash -c '! grep -Eiq "seed|secret|private" "$1"' _ "$VECTORS"
check "the Worker source imports nothing from node: (it runs on workerd)" \
  bash -c '! grep -rEn "from \"node:|require\(" "$1/src"' _ "$W"
check "npm test checks the schema copies before running vitest" \
  jq -e '.scripts.test | startswith("node scripts/sync-schemas.mjs --check && vitest run")' "$W/package.json"
check "the Worker has no runtime dependency (everything is the platform's)" \
  jq -e '(.dependencies // {}) == {}' "$W/package.json"
check "bin/lib/runhmd_receipt.py and the Worker agree on the size limit" \
  bash -c 'py=$(sed -n "s/^MAX_RECEIPT_BYTES = \(.*\)$/\1/p" "$1/bin/lib/runhmd_receipt.py" | head -1); js=$(sed -n "s/^export const MAX_RECEIPT_BYTES = \(.*\);$/\1/p" "$2/src/receipt.ts"); [ "$py" = "1024 * 1024" ] && [ "$js" = "1024 * 1024" ]' _ "$REPO" "$W"

# ══════════════════════════════════════════════════════════════════════════════
echo "[T] the real CLI agrees: hmd receipt verify on the bytes the Worker would serve"
python3 - "$TMP" "$VECTORS" <<'PY'
import base64, json, sys
tmp, path = sys.argv[1], sys.argv[2]
doc = json.load(open(path, encoding="utf-8"))
open(tmp + "/anchor.pub", "w").write("# vector anchor\n" + doc["anchors"][0] + "\n")
for case in doc["receipts"]:
    open("%s/v-%s.json" % (tmp, case["name"]), "wb").write(base64.b64decode(case["raw_b64"]))
PY
cli() { HEIMDALL_HOME="$TMP/home" "$REPO/bin/heimdall-receipt" verify "$TMP/v-$1.json" --pubkey "$TMP/anchor.pub" --json </dev/null 2>&1; }
OUTV="$(cli denied-canonical-lf)"; RCV=$?
[ "$RCV" -eq 0 ] && ok "a vector receipt the Worker accepts verifies with the CLI (exit 0)" || bad "CLI rejects an accepted receipt (rc=$RCV: $(printf '%s' "$OUTV" | head -c 160))"
for pair in "tampered-cost:bad_signature" "tampered-id:bad_signature" "signature-first-char:bad_signature" "stranger-signer:unknown_key" \
            "crlf-ending:not_canonical" "pretty-printed:not_canonical" "unsigned:schema" "extra-member:schema" "not-json:not_json"; do
  name="${pair%%:*}"; kind="${pair##*:}"
  OUTV="$(cli "$name")"; RCV=$?
  if [ "$RCV" -eq 1 ] && printf '%s' "$OUTV" | grep -q "$kind"; then ok "the CLI refuses $name with exit 1 ($kind), as the Worker answers 4xx"
  else bad "CLI on $name (rc=$RCV, want 1 + $kind): $(printf '%s' "$OUTV" | head -c 160)"; fi
done

echo
printf 'receipts-worker-contract: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
