// MUTANT session-honors-body-team — INV-LOGIN-1 removed.
//
// The /dashboard-data read trusts a caller-supplied body/query team_id instead of the
// login session's SERVER-DERIVED teams (registered_team(haid), signed into the session).
// A valid session for team A can now read team B's roster by naming team_id=B on the
// read. The "L1-session-cross-team" attack SUCCEEDS -> team B enters the read set ->
// returns ALLOW where the acceptance oracle demands DENY -> the oracle goes RED at
// L1-session-cross-team.
import { evaluateAttack } from "../model.mjs";

const GATES = { sessionHonorsBodyTeam: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
