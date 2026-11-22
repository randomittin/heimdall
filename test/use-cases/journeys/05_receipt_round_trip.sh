#!/usr/bin/env bash
# Journey 05 -- a signed receipt of a verdict, checked later by anyone with the public key (README "Receipts", docs/RECEIPTS.md).
#
#   A developer wants proof that a verdict happened, not just a printout of it:
#     1. an attack without --receipt leaves no receipt and no store behind (a signing key in the machine is not consent to write)
#     2. `hmd receipt keygen` makes their signing key: secret 0600, public 0644, the secret never printed, an existing key never overwritten
#     3. `hmd attack --receipt` DENIES the planted bug (exit 1 still) and issues a signed receipt: receipt_url set, the file stored, its path reported
#     4. the receipt commits to the finding by digest and carries no counterexample text, repro command or path
#     5. `hmd receipt verify <id>` accepts it (exit 0)
#     6. a ONE-BYTE edit of the stored file is refused (exit 1), whichever byte, and restoring the byte makes it verify again
#     7. a receipt is trusted only against a key the verifier pinned: someone else's public key refuses it (exit 1), never "ok"
#
# Engines reused: test/runhmd-receipt.test.sh [V] verify and [A] attack --receipt.
# Mutants (test/use-cases/mutants.list): the signature check always passes, a world-readable secret key, --receipt ignored.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 05_receipt_round_trip
uc_need_node
uc_need_crypto
uc_tree
uc_fakebin
uc_sandbox receipt

HH="$UC_ROOT/receipt/heimdall-home"
mkdir -p "$HH"
: > "$HH/setup-done"
PROJ="$UC_WORK/webhook-service"
cp -R "$UC_TREE/fixtures/attack/buggy-webhook" "$PROJ"
STORE="$HH/runhmd/receipts"                 # the documented default store; nothing here sets RUNHMD_RECEIPT_DIR or a key file
hmd() { uc_run "$UC_HOME" "$UC_WORK" HEIMDALL_HOME="$HH" -- "$UC_TREE/bin/hmd" "$@"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# 1. no receipt unless asked
hmd attack webhook-service --json --yes
uc_rc "an attack without --receipt still DENIES the planted bug" 1
uc_jq "…and issues no receipt: receipt_url stays null" '.verdict == "DENIED" and .receipt_url == null' "$UC_OUT"
if [ ! -e "$STORE" ]; then uc_ok "…and no receipt store was created"; else uc_bad "an attack without --receipt created a receipt store"; fi

# 2. the developer's own signing key
hmd receipt keygen
uc_rc "keygen makes the signing key" 0
KEY="$HH/signing/runhmd-receipt.key"; PUB="$HH/signing/runhmd-receipt.pub"
if [ -f "$KEY" ] && [ -f "$PUB" ]; then uc_ok "the key pair is in \$HEIMDALL_HOME/signing"; else uc_bad "keygen wrote no key pair under \$HEIMDALL_HOME/signing"; fi
if [ "$(mode_of "$KEY")" = 600 ]; then uc_ok "the secret key is mode 0600"; else uc_bad "the secret key is mode $(mode_of "$KEY"), want 600"; fi
if [ "$(mode_of "$PUB")" = 644 ]; then uc_ok "the public key is mode 0644"; else uc_bad "the public key is mode $(mode_of "$PUB"), want 644"; fi
SEED="$(tr -d '\n' < "$KEY" 2>/dev/null)"
if [ -n "$SEED" ] && ! grep -qF -- "$SEED" "$UC_OUT" "$UC_ERR"; then uc_ok "keygen never prints the secret"; else uc_bad "keygen printed the secret key (or wrote none)"; fi
before_key="$(shasum -a 256 "$KEY" | awk '{print $1}')"
hmd receipt keygen
uc_rc "a second keygen refuses to overwrite the key" 2
if [ "$before_key" = "$(shasum -a 256 "$KEY" | awk '{print $1}')" ]; then uc_ok "…and leaves it byte-identical"; else uc_bad "a second keygen changed the secret key"; fi

# 3. attack with --receipt
hmd attack webhook-service --json --yes --receipt
uc_rc "attacking with --receipt still exits with the verdict (DENIED)" 1
ID="$(jq -r '.id' "$UC_OUT" 2>/dev/null)"
RECEIPT="$STORE/$ID.json"
uc_jq "the verdict names its receipt: https://runhmd.dev/r/<id>" ".verdict == \"DENIED\" and .receipt_url == \"https://runhmd.dev/r/$ID\"" "$UC_OUT"
if [ -f "$RECEIPT" ]; then uc_ok "the receipt is stored as <store>/<id>.json"; else uc_bad "no receipt file at $RECEIPT"; fi
uc_has "the receipt's path is reported on stderr" "$UC_ERR" "receipt: .*$ID\\.json"

# 4. what is in the receipt, and what never is
uc_jq "the receipt is signed, private by default, and records the DENIED verdict" '.schema == "runhmd.receipt/1" and .verdict == "DENIED" and .visibility == "private" and (.signature | length) > 40 and (.key_id | length) > 0' "$RECEIPT"
uc_jq "each finding is committed to by digest" '(.findings | length) >= 1 and all(.findings[]; .digest | startswith("sha256:"))' "$RECEIPT"
for leak in minimal_input deliveries repro_cmd counterexample webhook-service; do
  uc_lacks "the receipt carries no \"$leak\"" "$RECEIPT" "$leak"
done

# 5. verify
hmd receipt verify "$ID"
uc_rc "hmd receipt verify <id> accepts the receipt the attack just issued" 0
uc_has "…and says which verdict it vouches for" "$UC_OUT" "^ok $ID DENIED"

# 6. one byte changed, anywhere, and it is refused
cp "$RECEIPT" "$UC_ROOT/receipt.original"
perl -0pi -e 's/("created_at":"[^"]*?)([0-9])(Z")/$1.(($2+1)%10).$3/e' "$RECEIPT"
if ! cmp -s "$RECEIPT" "$UC_ROOT/receipt.original"; then uc_ok "(setup) one digit of created_at was changed: a schema-valid edit"; else uc_bad "(setup) the tamper changed nothing"; fi
hmd receipt verify "$ID"
uc_rc "a one-digit edit of the stored receipt is refused" 1
uc_has "…as a bad signature" "$UC_ERR" 'bad_signature'
cp "$UC_ROOT/receipt.original" "$RECEIPT"
size="$(wc -c < "$RECEIPT" | tr -d ' ')"
for off in $((size / 2)) $((size - 80)); do
  cp "$UC_ROOT/receipt.original" "$RECEIPT"
  python3 -c 'import sys; p, i = sys.argv[1], int(sys.argv[2]); b = bytearray(open(p, "rb").read()); b[i] ^= 1; open(p, "wb").write(b)' "$RECEIPT" "$off"
  hmd receipt verify "$ID"
  uc_rc "flipping the byte at offset $off is refused" 1
done
cp "$UC_ROOT/receipt.original" "$RECEIPT"
hmd receipt verify "$ID"
uc_rc "control: with the original bytes restored it verifies again" 0

# 7. trust is the verifier's key, never the receipt's say-so
hmd receipt keygen --dir "$UC_ROOT/someone-elses-keys"
uc_rc "(setup) someone else makes a key pair" 0
hmd receipt verify "$ID" --pubkey "$UC_ROOT/someone-elses-keys/runhmd-receipt.pub"
uc_rc "a receipt checked against another person's public key is refused" 1
uc_has "…as signed by an unknown key" "$UC_ERR" 'unknown_key'

if [ ! -s "$UC_CLAUDE_LOG" ] && [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "no model session and no keychain access in the whole journey"; else uc_bad "the journey called claude or the keychain" "$(cat "$UC_CLAUDE_LOG" "$UC_SECURITY_LOG" | head -c 200)"; fi

uc_finish
