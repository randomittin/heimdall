// candidate.mjs — the GOLDEN isolation candidate. Every gate is wired STRONG (all
// flags falsy), so the whole fixed cross-tenant attack sequence is DENIED. This is the
// load-bearing multi-tenant story as a single subject: two tenants set up their own
// creds/installation/queue, and team A cannot dispatch B's repo (INV-11), read B's
// cred (INV-2), drain B's queue (INV-2/3), swap B's installation (A5), spoof a request
// team_id (INV-1), enqueue into B's partition (INV-1), or dispatch/read a cred through
// the popped public surface (INV-6). run.sh grades default(attackId) against the fixed
// all-DENY acceptance oracle; the golden passes because every attack returns DENY.
import { evaluateAttack } from "../model.mjs";

const GATES = {}; // all isolation gates STRONG.

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
