// MUTANT autoteam-skips-haid-possession — INV-AUTOTEAM (haid possession) removed.
//
// The auto-team handler binds the request's `haid` WITHOUT verifying a key-possession
// assertion against that HAID's registered Ed25519 pubkey — the `sig` is accepted (or
// ignored) rather than verified. Any caller who merely KNOWS a victim's already-enrolled
// HAID can now bind that victim's HAID into a team they control (griefing / cross-team
// visibility — the residual vector §3c). The "AT6-haid-possession" attack SUCCEEDS ->
// returns ALLOW where the acceptance oracle demands DENY -> the oracle goes RED at
// AT6-haid-possession.
import { evaluateAttack } from "../model.mjs";

const GATES = { autoteamSkipsHaidPossession: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
