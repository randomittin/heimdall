// MUTANT god-accepts-forged-iap — the IAP owner-bridge VERIFICATION removed.
//
// The IAP-gated god web surface trusts the PRESENCE of an IAP assertion instead of VERIFYING
// it (the ES256 signature against Google's keys + the issuer + the configured audience + the
// owner email). With the verify gone, a FORGED / absent / wrong-email IAP JWT mints an
// owner-equivalent identity — the "trust the edge" foot-gun cp_iap exists to prevent (a
// misconfigured or bypassed IAP layer must never grant owner; the app layer re-verifies). The
// "G5-god-forged-iap" attack SUCCEEDS -> the forged JWT mints owner -> returns ALLOW where the
// acceptance oracle demands DENY -> the oracle goes RED at G5-god-forged-iap.
import { evaluateAttack } from "../model.mjs";

const GATES = { godAcceptsForgedIap: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
