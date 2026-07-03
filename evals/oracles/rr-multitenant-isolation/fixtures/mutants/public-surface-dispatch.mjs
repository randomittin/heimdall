// MUTANT public-surface-dispatch — INV-6 removed.
//
// The internet-facing public surface is given a credential and a dispatch capability
// instead of being enqueue-only (cp_publicsurface writes a team-scoped row and STOPS).
// A compromise of the public surface now leaks a credential and can dispatch arbitrary
// cycles. The popped-surface attack SUCCEEDS -> attack "A10-public-dispatch" returns
// ALLOW where the acceptance oracle demands DENY -> the oracle goes RED at A10-public-dispatch.
import { evaluateAttack } from "../model.mjs";

const GATES = { publicSurfaceDispatch: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
