// MUTANT autoteam-trusts-claimed-ghuser — INV-AUTOTEAM(A) removed.
//
// The auto-join handler trusts the client-claimed gh_user instead of re-deriving the real
// login server-side from the forwarded gh_proof (GET /user). A forger can now name a
// victim collaborator's username and be believed — the Stratum-A caller<->gh_user binding
// is gone. The "AT2-forged-gh-identity" attack SUCCEEDS -> returns ALLOW where the
// acceptance oracle demands DENY -> the oracle goes RED at AT2-forged-gh-identity.
import { evaluateAttack } from "../model.mjs";

const GATES = { autoteamTrustsClaimedGhUser: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
