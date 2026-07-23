// MUTANT mint-skips-sig-verify — INV-LOGIN-4 removed.
//
// The mint route skips HAID signature verification instead of riding verify_identity: a
// mint request with a forged signature now issues a session. Anyone can mint a login
// session for any HAID without holding the enrolled Ed25519 key. The "L4-bad-signature-mint"
// attack SUCCEEDS -> the unverified mint issues a session -> returns ALLOW where the
// acceptance oracle demands DENY -> the oracle goes RED at L4-bad-signature-mint.
import { evaluateAttack } from "../model.mjs";

const GATES = { mintSkipsSigVerify: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
