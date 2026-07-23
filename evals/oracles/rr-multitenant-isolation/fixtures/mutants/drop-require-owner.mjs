// MUTANT drop-require-owner — INV-GOD removed (gated /god/* owner gate).
//
// The _require_owner gate on the GATED control-plane /god/roster route is dropped:
// requireOwner always returns true. A legitimately SIGNED non-owner key (valid PKI
// signature, IAM-authorized, but identity.owner=false) now passes the owner gate and
// reaches the cross-tenant aggregate instead of getting 401 not_owner. The
// "G3-nonowner-god" attack SUCCEEDS -> returns ALLOW where the acceptance oracle demands
// DENY -> the oracle goes RED at G3-nonowner-god.
import { evaluateAttack } from "../model.mjs";

const GATES = { dropRequireOwner: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
