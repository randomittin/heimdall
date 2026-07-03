// model.mjs — a faithful, executable model of the rr multi-tenant ISOLATION gates.
//
// This is the single codebase the golden candidate and every mutant share — exactly
// the shape of the real system, where there is ONE control-plane and a mutant is that
// codebase with ONE isolation gate removed. The gates below mirror the SHIPPED
// enforcement, cited so the model stays honest against the contract
// (docs/specs/2026-07-03-rr-isolation-invariants.md):
//
//   * teamCoversRepo        <- cp_ghinstall.team_covers_repo        (INV-11 / A1,A5)
//   * serverDerivedTeam     <- cp_auth.registered_team + the allowlist that refuses a
//                              wire team_id (INV-1 / A1 spoof, A14, enqueue-cross)
//   * resolveCredSecret     <- cp_team_creds.env_for_team (team_id-keyed) (INV-2 / A2)
//   * queueRead             <- cp_team_queue.pick/list ((team_id,repo) key) (INV-2/3 / A3)
//   * resolveInstallationId <- cp_ghinstall.get_installation (server-side) (A5)
//   * publicSurface         <- cp_publicsurface enqueue-only boundary (INV-6 / A10)
//
// A `gates` object selects each gate's behavior. The golden wires EVERY flag falsy =>
// every gate STRONG. A mutant sets EXACTLY ONE flag true => that gate is dropped, the
// real cross-tenant attack it stops then SUCCEEDS, and the oracle (run.sh) sees the
// ALLOW where the acceptance table demands DENY. The reference (acceptance.json, a
// fixed all-DENY table) is INDEPENDENT of this model — it is the truth the diff grades
// against, so golden and mutants sharing model code is correct, not tautological.

// ── Two tenants. team_id is the non-secret partition handle (derive_team_id shape:
//    32 hex). The secret entropy is elsewhere; team_id at rest is just a selector. ──
export const TEAM_A = {
  team_id: "aaaa0000aaaa0000aaaa0000aaaa0000",
  repos: ["alice/webapp"],
  installation_id: 1001,
  cred_secret: "heimdall-tc-aaaa0000aaaa0000aaaa0000aaaa0000-model-api-key",
  queue: [{ id: "A-1", repo: "alice/webapp", task: "bump deps" }],
};

export const TEAM_B = {
  team_id: "bbbb1111bbbb1111bbbb1111bbbb1111",
  repos: ["bob/service"],
  installation_id: 2002,
  cred_secret: "heimdall-tc-bbbb1111bbbb1111bbbb1111bbbb1111-model-api-key",
  queue: [{ id: "B-1", repo: "bob/service", task: "rotate token" }],
};

const TEAMS = { [TEAM_A.team_id]: TEAM_A, [TEAM_B.team_id]: TEAM_B };

// A cred NOT owned by any single team — what a dropped partition key collapses to.
const GLOBAL_CRED_SECRET = "heimdall-global-model-api-key";

// ── INV-1: the operative team_id is ALWAYS server-derived from the caller's verified
//    binding, NEVER a request field. Mirrors cp_auth.registered_team(haid); the
//    allowlist already refuses an extra `team_id` param, so there is no wire channel. ──
export function serverDerivedTeam(gates, req) {
  if (gates.acceptRequestTeamId && req.body && req.body.team_id) {
    return req.body.team_id; // MUTANT (INV-1 dropped): trusts the wire team_id.
  }
  return req.caller.team_id; // GOLDEN: from the verified enroll binding only.
}

// ── INV-11 (keystone): a caller may dispatch ONLY against a repo its team_id owns.
//    Exact-match authz — cp_ghinstall.team_covers_repo(team_id, repo). ──
export function teamCoversRepo(gates, team_id, repo) {
  if (gates.dropTeamCoversRepo) return true; // MUTANT (INV-11 dropped): any repo authorized (IDOR).
  const t = TEAMS[team_id];
  return !!t && t.repos.includes(repo); // GOLDEN: exact-match against the team's own install map.
}

// ── INV-2 (cred): every cred access is keyed by the caller's team_id. There is NO
//    function that returns another team's cred — cp_team_creds.env_for_team(team_id). ──
export function resolveCredSecret(gates, team_id) {
  if (gates.dropCredPartitionKey) return GLOBAL_CRED_SECRET; // MUTANT: global cred, not per-team.
  const t = TEAMS[team_id];
  return t ? t.cred_secret : null; // GOLDEN: this team's own secret name only.
}

// ── A5: installation_id is resolved SERVER-SIDE from team_id, NEVER a wire param.
//    cp_ghinstall.get_installation(team_id); installation_id is not an allowlist param. ──
export function resolveInstallationId(gates, team_id, req) {
  if (gates.resolveInstallFromParam && req.body && req.body.installation_id) {
    return req.body.installation_id; // MUTANT (A5): honors a wire-supplied installation_id.
  }
  const t = TEAMS[team_id];
  return t ? t.installation_id : null; // GOLDEN: from the team's install map only.
}

// ── INV-2/3 (queue): the task queue is (team_id, repo)-keyed. A read for a team
//    returns ONLY that team's partition; another team's rows are invisible.
//    cp_team_queue keys on teamq/<team_id>/… — a different team_id addresses a
//    different record, so no op crosses the partition. ──
export function queueRead(gates, team_id, repo) {
  if (gates.dropQueuePartitionKey) {
    // MUTANT: repo-keyed only (team_id dropped) => returns EVERY team's rows for the
    // repo name, so team A drains team B's tasks.
    return Object.values(TEAMS).flatMap((t) => t.queue.filter((r) => r.repo === repo));
  }
  const t = TEAMS[team_id]; // GOLDEN: this team's partition only.
  return t ? t.queue.filter((r) => r.repo === repo) : [];
}

// ── INV-6 (A10): the public surface is ENQUEUE-ONLY. It holds NO credential and has
//    NO dispatch capability — cp_publicsurface writes a team-scoped row and STOPS. ──
export function publicSurface(gates) {
  if (gates.publicSurfaceDispatch) {
    return { canDispatch: true, holdsCred: true }; // MUTANT: a popped surface can act.
  }
  return { canDispatch: false, holdsCred: false }; // GOLDEN: enqueue-only, credential-free.
}

// ── The fixed cross-tenant attack sequence. Each returns "DENY" (attack stopped) or
//    "ALLOW" (attack SUCCEEDED — a tenant touched another's resource). The acceptance
//    oracle demands DENY for every one; a mutant flips exactly its own gate's attack
//    to ALLOW, and run.sh reports that attack as the first_divergence. ──
export function evaluateAttack(gates, attackId) {
  switch (attackId) {
    case "A1-idor-repo": {
      // Team A signs a dispatch naming team B's repo slug (IDOR via repo slug).
      const req = { caller: TEAM_A, body: { repo: TEAM_B.repos[0] } };
      const team = serverDerivedTeam(gates, req);
      return teamCoversRepo(gates, team, TEAM_B.repos[0]) ? "ALLOW" : "DENY";
    }
    case "A1-spoof-team-id": {
      // Team A dispatches its OWN repo but spoofs body team_id=B to operate as B.
      // The operative partition MUST stay A; crossing into B is the ALLOW.
      const req = { caller: TEAM_A, body: { team_id: TEAM_B.team_id, repo: TEAM_A.repos[0] } };
      const team = serverDerivedTeam(gates, req);
      return team === TEAM_A.team_id ? "DENY" : "ALLOW";
    }
    case "A2-cred-read": {
      // Team A's job resolves a model cred. Resolving anything but A's own is the ALLOW.
      const req = { caller: TEAM_A, body: {} };
      const team = serverDerivedTeam(gates, req);
      const secret = resolveCredSecret(gates, team);
      return secret === TEAM_A.cred_secret ? "DENY" : "ALLOW";
    }
    case "A3-queue-drain": {
      // Team A reads the queue for B's repo name, trying to drain B's tasks.
      const req = { caller: TEAM_A, body: { repo: TEAM_B.repos[0] } };
      const team = serverDerivedTeam(gates, req);
      const rows = queueRead(gates, team, TEAM_B.repos[0]);
      const sawB = rows.some((r) => TEAM_B.queue.some((b) => b.id === r.id));
      return sawB ? "ALLOW" : "DENY";
    }
    case "A5-install-swap": {
      // Team A supplies B's installation_id as a param to PR on B's repo. Ending up
      // wielding B's installation_id is the ALLOW.
      const req = {
        caller: TEAM_A,
        body: { installation_id: TEAM_B.installation_id, repo: TEAM_B.repos[0] },
      };
      const team = serverDerivedTeam(gates, req);
      const inst = resolveInstallationId(gates, team, req);
      return inst === TEAM_B.installation_id ? "ALLOW" : "DENY";
    }
    case "A10-public-dispatch": {
      // The internet-facing public surface is popped and tries to dispatch / read a cred.
      const surf = publicSurface(gates);
      return surf.canDispatch || surf.holdsCred ? "ALLOW" : "DENY";
    }
    case "enqueue-cross-partition": {
      // Team A enqueues into B's partition (spoofs body team_id=B on the enqueue).
      const req = { caller: TEAM_A, body: { team_id: TEAM_B.team_id } };
      const team = serverDerivedTeam(gates, req);
      return team === TEAM_A.team_id ? "DENY" : "ALLOW";
    }
    default:
      throw new Error("unknown attack id: " + attackId);
  }
}
