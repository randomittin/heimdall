// MUTANT god-accepts-body-team-id — INV-1 removed inside the owner aggregate.
//
// The god aggregate honors a caller-supplied body/query team_id instead of enumerating
// partitions SERVER-SIDE from the team registry. Even the owner-only aggregate must
// derive its partition set server-side (INV-1 holds for /god/* too); trusting the wire
// team_id lets a caller steer the aggregate at a forged, non-registered partition. The
// "G4-god-cross-partition" attack SUCCEEDS -> the forged team_id appears in the
// enumerated set -> returns ALLOW where the acceptance oracle demands DENY -> the oracle
// goes RED at G4-god-cross-partition.
import { evaluateAttack } from "../model.mjs";

const GATES = { godAcceptsBodyTeamId: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
