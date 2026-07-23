// MUTANT skip-session-expiry — INV-LOGIN-3 removed.
//
// The short-TTL check is dropped: an expired/TTL-lapsed session is treated as live instead
// of being rejected (401) before any read. A stale session token keeps reading rosters
// indefinitely. The "L3-expired-session" attack SUCCEEDS -> the lapsed session is honored
// -> returns ALLOW where the acceptance oracle demands DENY -> the oracle goes RED at
// L3-expired-session.
import { evaluateAttack } from "../model.mjs";

const GATES = { skipSessionExpiry: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
