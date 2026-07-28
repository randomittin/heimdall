// MUTANT autoteam-honors-wire-teamid — INV-1 removed inside auto-join.
//
// The auto-join handler resolves the operative team_id from a caller-supplied body/query
// team_id instead of the server-side repo->team binding (cp_repoteam). A caller can now
// steer the join at any partition by naming a wire team_id — INV-1 (server-derived team,
// never a wire field) is violated for auto-join. The "AT3-autojoin-wire-team-id" attack
// SUCCEEDS -> returns ALLOW where the acceptance oracle demands DENY -> the oracle goes
// RED at AT3-autojoin-wire-team-id.
import { evaluateAttack } from "../model.mjs";

const GATES = { autoteamHonorsWireTeamId: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
