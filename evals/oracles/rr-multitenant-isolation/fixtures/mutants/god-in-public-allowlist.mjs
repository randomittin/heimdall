// MUTANT god-in-public-allowlist — INV-GOD removed (public-surface allowlist gate).
//
// /god/roster is added to the PUBLIC surface route allowlist (PUBLIC_ROUTES) instead of
// being 404 on the internet-facing surface. The god cross-tenant aggregate — reachable
// ONLY with owner PKI + IAM on the GATED control-plane service — now resolves on the
// PUBLIC surface. Two cross-tenant attacks SUCCEED with this one gate gone:
//   * "G1-god-on-public"   — an anonymous public caller reaches GET /god/roster (no 404);
//   * "G2-team-secret-god" — a valid team secret S (a public-surface bearer only) now
//                            reaches the aggregate that team secrets must never touch.
// Both return ALLOW where the acceptance oracle demands DENY. run.sh reports the FIRST in
// the fixed sequence (G1-god-on-public) as first_divergence — the same shape as
// accept-request-team-id, whose one dropped gate also opens two attacks.
import { evaluateAttack } from "../model.mjs";

const GATES = { godInPublicAllowlist: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
