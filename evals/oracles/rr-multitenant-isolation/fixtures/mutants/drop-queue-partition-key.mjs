// MUTANT drop-queue-partition-key — INV-2/3 (queue) removed.
//
// The task queue is keyed by repo ONLY (the team_id partition segment is dropped from
// cp_team_queue's teamq/<team_id>/… layout). A queue read for a repo name now returns
// every team's rows, so team A reads and drains team B's tasks. The cross-tenant queue
// drain SUCCEEDS -> attack "A3-queue-drain" returns ALLOW where the acceptance oracle
// demands DENY -> the oracle goes RED at A3-queue-drain.
import { evaluateAttack } from "../model.mjs";

const GATES = { dropQueuePartitionKey: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
