// MUTANT accept-request-team-id — INV-1 removed.
//
// The operative team_id is read from the REQUEST BODY instead of the caller's verified
// enroll binding (cp_auth.registered_team). Team A can now set "team_id": B and operate
// inside team B's partition. The spoof attack SUCCEEDS -> attack "A1-spoof-team-id"
// returns ALLOW (the partition crossed into B) where the acceptance oracle demands DENY
// -> the oracle goes RED at A1-spoof-team-id (the same dropped gate also opens
// enqueue-cross-partition; A1-spoof-team-id is first in the fixed sequence).
import { evaluateAttack } from "../model.mjs";

const GATES = { acceptRequestTeamId: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
