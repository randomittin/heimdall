// MUTANT session-teams-from-client — INV-LOGIN-2 removed.
//
// The session's team list is taken from the CLIENT at mint instead of being server-derived
// from registered_team(haid) and signed in. A mint request for haid:alice (enrolled in
// team A) can now inject team B into the session's teams. The "L2-tampered-session-teamids"
// attack SUCCEEDS -> team B enters the minted session -> returns ALLOW where the acceptance
// oracle demands DENY -> the oracle goes RED at L2-tampered-session-teamids.
import { evaluateAttack } from "../model.mjs";

const GATES = { sessionTeamsFromClient: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
