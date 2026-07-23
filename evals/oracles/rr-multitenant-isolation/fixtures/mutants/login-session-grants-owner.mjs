// MUTANT login-session-grants-owner — INV-LOGIN-5 removed.
//
// A login session is allowed to pass the owner/god gate instead of always being
// Identity.owner=false. Owner authority (§7 gate override) becomes delegatable through a
// dashboard login session, when it must stay rooted in owner-PKI + IAP alone. The
// "L5-session-is-owner" attack SUCCEEDS -> the login session passes the owner gate ->
// returns ALLOW where the acceptance oracle demands DENY -> the oracle goes RED at
// L5-session-is-owner.
import { evaluateAttack } from "../model.mjs";

const GATES = { loginSessionGrantsOwner: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
