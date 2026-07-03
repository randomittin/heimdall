// MUTANT drop-cred-partition-key — INV-2 (cred) removed.
//
// The model credential is resolved from a GLOBAL secret instead of the per-team keyed
// store (cp_team_creds.env_for_team(team_id)). Team A's job now runs on a cred that is
// not A's own — the cross-tenant cred read SUCCEEDS -> attack "A2-cred-read" returns
// ALLOW where the acceptance oracle demands DENY -> the oracle goes RED at A2-cred-read.
import { evaluateAttack } from "../model.mjs";

const GATES = { dropCredPartitionKey: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
