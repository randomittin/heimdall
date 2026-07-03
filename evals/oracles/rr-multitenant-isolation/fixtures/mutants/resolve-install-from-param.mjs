// MUTANT resolve-install-from-param — A5 removed.
//
// The GitHub installation_id is resolved from a REQUEST PARAM instead of server-side
// from the team's install map (cp_ghinstall.get_installation(team_id)). Team A can now
// supply team B's installation_id and mint a token scoped to B's installation to PR on
// B's repo. The installation-swap attack SUCCEEDS -> attack "A5-install-swap" returns
// ALLOW where the acceptance oracle demands DENY -> the oracle goes RED at A5-install-swap.
import { evaluateAttack } from "../model.mjs";

const GATES = { resolveInstallFromParam: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
