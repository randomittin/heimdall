// MUTANT autoteam-public-read-joins — INV-AUTOTEAM(§5) removed.
//
// The auto-join handler drops the PUBLIC-repo write/push threshold — a mere reader on a
// public repo is allowed to auto-join. Because everyone has read access to a public repo,
// this puts the whole world onto the presence wall (RJ's public-threshold policy is gone).
// The "AT4-public-read-only-autojoin" attack SUCCEEDS -> returns ALLOW where the
// acceptance oracle demands DENY -> the oracle goes RED at AT4-public-read-only-autojoin.
import { evaluateAttack } from "../model.mjs";

const GATES = { autoteamPublicReadJoins: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
