// MUTANT autoteam-any-caller-initiates — INV-AUTOTEAM (initiate) removed.
//
// The auto-INITIATE path drops the admin/push requirement — any caller can mint + bind a
// team for an UNBOUND repo. Someone who does not control the repo can now invent a team
// for it, defeating "only an admin/push holder may auto-initiate." The
// "AT5-unbound-repo-autojoin" attack SUCCEEDS -> returns ALLOW where the acceptance oracle
// demands DENY -> the oracle goes RED at AT5-unbound-repo-autojoin.
import { evaluateAttack } from "../model.mjs";

const GATES = { autoteamAnyCallerInitiates: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
