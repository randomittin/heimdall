// MUTANT client-preempts-server-binding — INV-AUTOTEAM (repo convergence) removed.
//
// The CURRENT (pre-fix) client resolver as a mutant: a committed secret / auto-solo mint
// PRE-EMPTS /team/auto, so one repo_slug splits into MULTIPLE team_ids. Two HAIDs on the
// SAME repo_slug entering via different resolution models derive DIFFERENT ids
// (sha256(secret) vs the server repo->team binding) and cannot see each other — private
// repos put same-repo teammates in different partitions, public repos explode into
// per-machine solo teams (TEAM-SPLIT-BUG.md). The "AT7-same-repo-one-team" attack
// SUCCEEDS -> returns ALLOW where the acceptance oracle demands DENY -> the oracle goes
// RED at AT7-same-repo-one-team.
import { evaluateAttack } from "../model.mjs";

const GATES = { clientPreemptsServerBinding: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
