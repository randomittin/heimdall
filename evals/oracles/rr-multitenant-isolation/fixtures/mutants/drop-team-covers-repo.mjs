// MUTANT drop-team-covers-repo — INV-11 (the keystone) removed.
//
// The repo<->team authorization gate (cp_ghinstall.team_covers_repo) is dropped:
// team_covers_repo always returns true. Team A naming team B's repo slug is now
// authorized, so the App would open a PR on B's repo using A's dispatch. The A1/A5
// IDOR-via-repo-slug attack SUCCEEDS -> attack "A1-idor-repo" returns ALLOW where the
// acceptance oracle demands DENY -> the oracle goes RED at A1-idor-repo.
import { evaluateAttack } from "../model.mjs";

const GATES = { dropTeamCoversRepo: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
