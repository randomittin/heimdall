// MUTANT autoteam-skips-collab-check — INV-AUTOTEAM(B) removed.
//
// The auto-join handler skips the Stratum-B collaborator/permission check
// (GET /repos/{repo}/collaborators/{gh_user}/permission) — every caller is treated as
// having access. A user with NO access to the bound repo is now granted the binding, so
// the "only someone with GitHub access may auto-join" invariant collapses. The
// "AT1-noncollaborator-autojoin" attack SUCCEEDS -> returns ALLOW where the acceptance
// oracle demands DENY -> the oracle goes RED at AT1-noncollaborator-autojoin.
import { evaluateAttack } from "../model.mjs";

const GATES = { autoteamSkipsCollabCheck: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
