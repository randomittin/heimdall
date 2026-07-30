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
//   * publicSurfaceRoute    <- cp_publicsurface route allowlist; /god/* is NEVER on the
//                              public surface (INV-GOD / G1 god-on-public, G2 team-secret-god)
//   * requireOwner          <- gated /god/* owner gate: identity.owner + valid signature
//                              + IAM (INV-GOD / G3 nonowner-god)
//   * godEnumeratePartitions<- the owner aggregate enumerates partitions SERVER-SIDE from
//                              the team registry, never a caller-supplied team_id
//                              (INV-1 holds even for the owner aggregate / G4 god-cross-partition)
//   * iapGrantsOwner        <- the IAP-gated god WEB surface's owner bridge: cp_iap.iap_identity
//                              accepts a Google IAP JWT as owner IFF the ES256 signature +
//                              issuer + configured audience VERIFY and email == the owner email
//                              (INV-GOD / G5 god-forged-iap — verify the assertion, never the edge)
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

// ─────────────────────────────────────────────────────────────────────────────────────
// INV-GOD — the cross-tenant "god mode" monitoring aggregate (owner-only /god/roster).
//
// The god aggregate is the direct INVERSE of multi-tenant isolation: it reads presence
// across ALL teams. It is therefore gated the hardest — reachable ONLY on the GATED
// control-plane service, ONLY with owner PKI + valid signature + IAM authorization, and
// it is 404 on the PUBLIC surface for every caller and every team secret. Formally:
//   * a request to the PUBLIC surface with any team secret S returns ONLY partition
//     derive_team_id(S); /god/* returns 404 on the PUBLIC surface for all S;
//   * /god/* on the GATED service returns data IFF identity.owner AND valid signature
//     AND IAM-authorized;
//   * even for the owner, the aggregate enumerates its partition set SERVER-SIDE — it
//     never honors a caller-supplied team_id (INV-1 holds for /god/* too).
// This model authors the ORACLE only; the real GET /god/roster handler is implemented
// later and must PASS this gate.
// ─────────────────────────────────────────────────────────────────────────────────────

// The PUBLIC surface route allowlist. Enqueue-only + presence. /god/* is NEVER here —
// mirrors cp_publicsurface's PUBLIC_ROUTES; anything not on it 404s on the public surface.
const PUBLIC_ROUTES = ["/enqueue", "/presence", "/roster/team"];

// Identities reaching the GATED control-plane service carry a PKI signature, an owner
// flag, and an IAM grant. The owner is cross-tenant (no single team partition); a
// non-owner is a legitimately enrolled teammate bound to one team.
const OWNER = {
  identity: "owner",
  owner: true,
  signature: "valid",
  iam: true,
  team_id: null, // the owner is cross-tenant; not a single team partition.
};
const NONOWNER = {
  identity: "teammate",
  owner: false,
  signature: "valid", // legitimately SIGNED, but NOT the owner.
  iam: true,
  team_id: TEAM_A.team_id,
};

// ── INV-GOD (public boundary): does a path resolve on the internet-facing PUBLIC
//    surface? /god/* is NOT on the allowlist, so it MUST 404 there — for anonymous
//    callers and for team-secret bearers alike. ──
export function publicSurfaceRoute(gates, path) {
  if (gates.godInPublicAllowlist && path.startsWith("/god/")) {
    return true; // MUTANT: /god/roster added to PUBLIC_ROUTES => resolves (no 404) on public.
  }
  return PUBLIC_ROUTES.includes(path); // GOLDEN: /god/* absent => 404 on the public surface.
}

// ── INV-GOD (owner gate): the gated /god/* route's _require_owner check. Data is
//    served IFF the identity is the owner AND the request is validly signed (and IAM
//    authorizes it — checked at the call site). A signed non-owner gets 401 not_owner. ──
export function requireOwner(gates, identity) {
  if (gates.dropRequireOwner) return true; // MUTANT: owner gate removed => any signed key passes.
  return identity.signature === "valid" && identity.owner === true; // GOLDEN: owner PKI only.
}

// ── INV-1 (inside the owner aggregate): the god aggregate enumerates its partition set
//    SERVER-SIDE from the team registry, NEVER from a caller-supplied team_id. The owner
//    can read all teams, but only the teams the server registry knows — never a
//    caller-forged partition selector. ──
export function godEnumeratePartitions(gates, req) {
  if (gates.godAcceptsBodyTeamId && req.body && req.body.team_id) {
    return [req.body.team_id]; // MUTANT: trusts the caller-supplied team_id (INV-1 dropped).
  }
  return Object.keys(TEAMS); // GOLDEN: server-enumerated registry only.
}

// ── INV-GOD (IAP owner bridge): the IAP-gated god-serving WEB surface accepts a Google IAP
//    JWT (X-Goog-IAP-JWT-Assertion) as an OWNER-EQUIVALENT identity IFF the app layer VERIFIES
//    it — the ES256 signature against Google's published keys, iss == the IAP issuer, aud ==
//    the configured backend audience — AND its email == the configured owner email. A browser
//    can neither PKI-sign nor do GCP IAM, so this is the ONLY browser path to /god/*; it is a
//    NEW owner-auth path ALONGSIDE the owner PKI, scoped to /god/* on the god surface only. The
//    gate is the app-layer VERIFY, never the mere presence of an IAP header (trusting the edge
//    is the foot-gun). Mirrors cp_iap.iap_identity + verify_iap_jwt. ──
const GOD_OWNER_EMAIL = "rj@heimdall.example"; // the configured owner (env HEIMDALL_GOD_OWNER_EMAIL).
const GOD_IAP_AUDIENCE = "/projects/123/global/backendServices/456"; // env HEIMDALL_GOD_IAP_AUDIENCE.
export function iapGrantsOwner(gates, assertion) {
  if (gates.godAcceptsForgedIap) return true; // MUTANT: skips the verify -> ANY assertion mints owner.
  return !!assertion
    && assertion.sig_valid === true                       // ES256 signature verified (not the edge).
    && assertion.iss === "https://cloud.google.com/iap"   // the IAP issuer.
    && assertion.aud === GOD_IAP_AUDIENCE                  // the configured backend audience.
    && assertion.email === GOD_OWNER_EMAIL;               // GOLDEN: a VERIFIED IAP JWT for the owner.
}

// ─────────────────────────────────────────────────────────────────────────────────────
// INV-LOGIN — the dashboard team-login session (Option B: local hmd + HAID + gh
// device-flow — docs/analysis/dashboard-login-design.md).
//
// A dashboard login session is minted after a local hmd signs a canonical assertion
// binding {github-user ↔ HAID ↔ device_code} with the enrolled Ed25519 HAID key, riding
// the EXISTING verify_identity chokepoint. The session is a team-READ capability scoped
// to the caller's OWN teams — the team_ids are SERVER-DERIVED at mint via
// registered_team(haid) and signed into the session; they are NEVER trusted from the
// client. The session is short-TTL, and it ALWAYS mints Identity.owner=false: owner
// authority stays rooted in owner-PKI + IAP and is never delegatable through a login
// session (dashboard-login-design.md "God mode stays separate").
//
// Formally, for a login session minted for HAID H enrolled in registered_team(H):
//   * a read is scoped to the session's server-derived teams ONLY — a body/query
//     team_id is never honored (INV-LOGIN-1);
//   * the session's team list is fixed server-side at mint from registered_team(H) and
//     signed in — a client-tampered team list is never trusted (INV-LOGIN-2);
//   * an expired/TTL-lapsed session is rejected (401) before any read (INV-LOGIN-3);
//   * a mint request whose HAID signature fails verification issues NO session
//     (INV-LOGIN-4);
//   * a login session is ALWAYS Identity.owner=false; it never passes an owner/god gate
//     (INV-LOGIN-5).
// This model authors the ORACLE only; the real /dashboard/session mint + poll routes and
// the `hmd dashboard login` CLI are implemented later and must PASS this gate.
// ─────────────────────────────────────────────────────────────────────────────────────

// The two enrolled login callers. Each HAID is enrolled in exactly ONE team via
// registered_team(haid) — the same server-derived binding INV-1 uses. A login session
// reads ONLY that team's roster.
const HAID_A = { haid: "haid:alice", team_id: TEAM_A.team_id };
const HAID_B = { haid: "haid:bob", team_id: TEAM_B.team_id };

// registered_team(haid) — the server-derived team binding at mint. Mirrors
// cp_auth.registered_team: derived from the verified enroll binding, never the client.
function registeredTeam(haid) {
  if (haid === HAID_A.haid) return HAID_A.team_id;
  if (haid === HAID_B.haid) return HAID_B.team_id;
  return null;
}

// A login session as minted by the CP: `teams` are the SERVER-DERIVED team_ids from
// registeredTeam(haid) at mint time, signed into the token; `owner` is ALWAYS false for
// a login session; `exp` is the short TTL; `haid` binds the session to the enrolled key.
function mintLoginSession(haid, serverDerivedTeams, exp) {
  return { haid, teams: serverDerivedTeams, owner: false, exp };
}

// ── INV-LOGIN-1: a read scopes to the session's SERVER-DERIVED teams, never a
//    caller-supplied body/query team_id. Mirrors the /dashboard-data read gate:
//    "returns roster/observe for ONLY the session's server-computed team_ids. Never
//    trusts a client team_id." ──
export function sessionReadTeams(gates, session, req) {
  if (gates.sessionHonorsBodyTeam && req.body && req.body.team_id) {
    return [req.body.team_id]; // MUTANT (INV-LOGIN-1 dropped): read trusts the wire team_id.
  }
  return session.teams; // GOLDEN: the session's server-derived teams only.
}

// ── INV-LOGIN-2: the session's team list is fixed SERVER-SIDE at mint from
//    registeredTeam(haid) and signed into the token. A client-tampered team list (a team
//    the HAID is not enrolled in, injected at mint) is never trusted. ──
export function sessionMintTeams(gates, haid, req) {
  if (gates.sessionTeamsFromClient && req.body && req.body.teams) {
    return req.body.teams; // MUTANT (INV-LOGIN-2 dropped): teams taken from the client.
  }
  const t = registeredTeam(haid);
  return t ? [t] : []; // GOLDEN: server-derived from the enroll binding at mint.
}

// ── INV-LOGIN-3: an expired/TTL-lapsed session is rejected (401) before any read. The
//    short TTL is enforced; a lapsed `exp` is not honored. ──
export function sessionIsLive(gates, session, now) {
  if (gates.skipSessionExpiry) return true; // MUTANT (INV-LOGIN-3 dropped): TTL never checked.
  return session.exp > now; // GOLDEN: reject once the short TTL has lapsed.
}

// ── INV-LOGIN-4: a mint request rides verify_identity — the HAID signature MUST verify
//    or NO session is issued. Mirrors cp_auth.verify: a bad signature is rejected at the
//    single chokepoint before any session is minted. ──
export function mintVerifiesSignature(gates, assertion) {
  if (gates.mintSkipsSigVerify) return true; // MUTANT (INV-LOGIN-4 dropped): mint skips sig verify.
  return assertion.signature === "valid"; // GOLDEN: only a verified HAID signature mints.
}

// ── INV-LOGIN-5: a login session is ALWAYS Identity.owner=false; only owner-PKI + IAP
//    grants owner. A login session must never pass an owner/god gate — owner authority is
//    not delegatable through a dashboard session. ──
export function loginSessionPassesOwnerGate(gates, session) {
  if (gates.loginSessionGrantsOwner) return true; // MUTANT (INV-LOGIN-5 dropped): login mints owner.
  return session.owner === true; // GOLDEN: a login session is never owner (always false).
}

// ─────────────────────────────────────────────────────────────────────────────────────
// INV-CHAT — the chat-ops identity binding (chat-ops P2 §2: a chat handle is never trusted
// bare). A chat message's operative team is resolved SERVER-SIDE from the persisted
// {chat_id <-> HAID <-> team} binding (bin/lib/chat_link.resolve), NEVER from the chat_id
// itself. An UNBOUND / forged chat_id has no binding, so it resolves to NO team and gets the
// link instruction — it returns NO team data. This is the direct chat-surface analogue of
// INV-1 (server-derived team, never a wire value): the chat_id is a bare, attacker-suppliable
// handle, exactly like a request team_id.
//
// This model authors the ORACLE only; the real chat_link.resolve + the status/investigate/
// report verbs (bin/lib/chat_verbs.py) are implemented in P2 and must PASS this gate.
// ─────────────────────────────────────────────────────────────────────────────────────

// The persisted chat-binding registry: the ONLY bound chat handle maps to team A. Every other
// chat_id (unbound / forged) has no binding. Mirrors chat_link's {chat_id -> team} store.
const CHAT_BINDINGS = { "chat:alice": TEAM_A.team_id };

// ── INV-CHAT: resolve a chat_id to its team from the persisted binding ONLY. An unbound /
//    forged chat_id resolves to null (no team) — the verb then refuses with the link
//    instruction and returns no data. Mirrors chat_link.resolve. ──
export function chatResolveTeam(gates, chatId) {
  if (gates.chatTrustsBareChatId) {
    // MUTANT (INV-CHAT dropped): trusts a bare chat_id as an identity, handing an unbound /
    // forged handle a team (here team A's partition) instead of refusing -> the forged chat
    // reads team data it was never bound to.
    return TEAM_A.team_id;
  }
  return CHAT_BINDINGS[chatId] || null; // GOLDEN: only a persisted binding resolves a team.
}

// ─────────────────────────────────────────────────────────────────────────────────────
// INV-AUTOTEAM — zero-touch team formation (auto-initiate + auto-join,
// docs/analysis/zero-touch-team-formation.md). The membership proof moves from "holds
// the team secret" to "has GitHub access to the repo," enforced SERVER-SIDE. A HAID is
// bound to a repo's team_id via POST /team/auto IFF the server independently verifies:
//   (A) the caller controls `gh_user` — the forwarded gh_proof's real GET /user login
//       equals the claimed gh_user (Stratum A: identity re-derived, never trusted);
//   (B) `gh_user` holds >= the repo's required permission on `repo` (Stratum B: a repo
//       collaborator, at or above the visibility-dependent threshold);
// where `repo -> team_id` is a SERVER-SIDE binding and the operative team_id is resolved
// from `repo`, NEVER a wire field (INV-1 holds for auto-join too). First-runner
// auto-INITIATE (no binding yet) additionally requires the caller to hold admin/push —
// only someone who controls the repo may mint + bind repo->team.
//
// This model authors the ORACLE only; the real POST /team/auto handler
// (cp_autoteam / cp_ghverify / cp_repoteam) is implemented later by a separate agent and
// MUST pass this gate. Each gate below is dropped by EXACTLY ONE mutant, flipping EXACTLY
// its own AT* attack DENY->ALLOW; the five gates are disjoint from every A*/G*/L*/C* gate
// (no existing mutant flips an AT* row, and no AT* mutant flips an existing row).
// ─────────────────────────────────────────────────────────────────────────────────────

// GitHub permission levels, ranked. The auto-team thresholds compare against these:
// private repo => read (any collaborator) suffices; PUBLIC repo => write/push required
// (the actual committing team, not drive-by readers). Mirrors the levels
// GET /repos/{repo}/collaborators/{gh_user}/permission returns.
const PERMISSION_RANK = { none: 0, read: 1, write: 2, admin: 3 };

// The server-side repo -> team_id binding registry (the new cp_repoteam source of truth).
// alice/webapp is a PRIVATE repo bound to team A; carol/opensource is a PUBLIC repo bound
// to team C. dave/fresh is deliberately ABSENT (unbound) — no team to resolve.
const REPO_TEAM_BINDINGS = {
  "alice/webapp": TEAM_A.team_id,
  "carol/opensource": "cccc3333cccc3333cccc3333cccc3333",
};

// Repo visibility (GET /repos/{repo}.private). Drives the auto-join threshold: PUBLIC repos
// demand write/push so the whole world's read access can't join the presence wall.
const REPO_VISIBILITY = {
  "alice/webapp": "private",
  "carol/opensource": "public",
  "dave/fresh": "public",
};

// The server-authoritative collaborator map (Stratum B: the install-token-scoped
// GET /repos/{repo}/collaborators/{gh_user}/permission result). Only listed logins have
// any access; a login absent from a repo's map has permission `none`.
const REPO_COLLABORATORS = {
  "alice/webapp": { alice: "admin" },
};

// The enrolled HAID -> registered Ed25519 pubkey registry (the same enroll binding the
// rest of the control-plane verifies against — cp_auth's per-HAID public key). A HAID that
// appears here is already enrolled with a known key; `haid:victim` is a victim whose HAID an
// attacker with admin/push on some OTHER repo may LEARN but whose Ed25519 private key the
// attacker does NOT hold. A possession assertion binds only if its signature verifies under
// the claimed HAID's registered pubkey — the attacker's own key (`pk:mallory`) is not it.
const HAID_ENROLLED_KEYS = {
  "haid:victim": "pk:victim",
};

// ── INV-AUTOTEAM(B) — Stratum-B collaborator check: does `gh_user` have ANY qualifying
//    access to `repo`? A caller with NO access (not a collaborator) can never auto-join.
//    Mirrors the server-side permission lookup; the DENY is refuse + no binding written. ──
export function autoteamHasRepoAccess(gates, repo, ghUser) {
  if (gates.autoteamSkipsCollabCheck) return true; // MUTANT: skip Stratum-B => any caller "has access".
  const perms = REPO_COLLABORATORS[repo] || {};
  return Object.prototype.hasOwnProperty.call(perms, ghUser); // GOLDEN: only a real collaborator.
}

// ── INV-AUTOTEAM(A) — Stratum-A caller<->gh_user binding: the forwarded gh_proof's REAL
//    login (server-derived via GET /user) MUST equal the claimed gh_user. A username claim
//    is never trusted; a forger cannot name a victim collaborator's login. ──
export function autoteamVerifyCaller(gates, ghProof, claimedGhUser) {
  if (gates.autoteamTrustsClaimedGhUser) return true; // MUTANT: trust the claim, skip GET /user re-derive.
  return !!ghProof && ghProof.token_login === claimedGhUser; // GOLDEN: real login must equal the claim.
}

// ── INV-1 (auto-join) — the operative team_id is resolved SERVER-SIDE from the repo->team
//    binding, NEVER a caller-supplied wire team_id. A body/query team_id must be ignored. ──
export function autoteamResolveTeam(gates, repo, req) {
  if (gates.autoteamHonorsWireTeamId && req.body && req.body.team_id) {
    return req.body.team_id; // MUTANT (INV-1 dropped): honors the wire team_id instead of the binding.
  }
  return REPO_TEAM_BINDINGS[repo] || null; // GOLDEN: server-derived from the repo->team binding only.
}

// ── INV-AUTOTEAM(§5) — the PUBLIC-repo write threshold. private => read suffices; PUBLIC =>
//    write/push required, so a mere reader on a public repo is excluded (RJ's public-threshold
//    policy — kept a clean single gate so the threshold is swappable). ──
export function autoteamMeetsThreshold(gates, repo, permission) {
  if (gates.autoteamPublicReadJoins) return true; // MUTANT: drop the public write-threshold => read joins.
  const required = REPO_VISIBILITY[repo] === "public" ? "write" : "read"; // GOLDEN: public demands write/push.
  return PERMISSION_RANK[permission] >= PERMISSION_RANK[required];
}

// ── INV-AUTOTEAM (initiate) — first-runner auto-INITIATE on an UNBOUND repo requires the
//    caller to hold admin/push. Only someone who controls the repo may mint + bind
//    repo->team; a read-only non-initiator can never invent a team. ──
export function autoteamCanInitiate(gates, repo, permission) {
  if (gates.autoteamAnyCallerInitiates) return true; // MUTANT: any caller initiates an unbound repo.
  return PERMISSION_RANK[permission] >= PERMISSION_RANK["write"]; // GOLDEN: admin/push required to initiate.
}

// ── INV-AUTOTEAM (haid possession) — a /team/auto request that binds `haid=V` must be SIGNED
//    by V's enrolled Ed25519 key: a canonical key-POSSESSION assertion. The server verifies the
//    possession signature against the REGISTERED pubkey of the claimed haid (HAID_ENROLLED_KEYS),
//    so only the actual key-holder can bind their OWN haid. A missing signature, a forged one, or
//    a signature that verifies under a DIFFERENT key (the attacker's) proves no possession and
//    binds nothing — an admin/push holder on some repo who merely KNOWS a victim's HAID cannot
//    bind that victim's haid into their team (residual vector §3c). Mirrors cp_autoteam's
//    per-HAID possession check riding the enrolled-key verify chokepoint. ──
export function autoteamVerifiesHaidPossession(gates, haid, possessionSig) {
  if (gates.autoteamSkipsHaidPossession) return true; // MUTANT: skip possession => any caller binds any known HAID.
  const registeredPubkey = HAID_ENROLLED_KEYS[haid];
  if (!registeredPubkey) return false; // an unknown/unenrolled haid has no registered key to verify against.
  // GOLDEN: the possession assertion's signature must verify under the claimed haid's REGISTERED
  // pubkey — the attacker's own key does not verify, and a missing/forged sig verifies under nothing.
  return !!possessionSig && possessionSig.verifies_under === registeredPubkey;
}

// ─────────────────────────────────────────────────────────────────────────────────────
// INV-AUTOTEAM (repo convergence) — one repo_slug ⇒ ONE team_id. The server repo->team
// binding (cp_repoteam.repo_slug canonicalizes; bind_repo_team is first-writer-wins) is
// the authority; the client resolver for a github repo that is online MUST converge on
// it through ANY of the 3 client resolution models (a committed-secret team.json, the
// /team/auto server binding, or an auto-solo mint). The SPLIT BUG (TEAM-SPLIT-BUG.md): a
// committed secret or an auto-solo mint PRE-EMPTS /team/auto, so two HAIDs on the SAME
// repo_slug derive DIFFERENT team_ids (sha256(secret) vs the server binding) and cannot
// see each other — same-repo teammates land in different partitions (private repos), and
// public repos explode into a per-machine solo team. Converging every model on the
// server-derived repo->team id is INV-1 for repo membership.
//
// This model authors the ORACLE only; the real client resolver (bin/heimdall-presence
// _resolve_team_for_wire + bin/heimdall-team _resolve) is fixed later (WAVE 2) and MUST
// pass this gate. The gate below is dropped by EXACTLY ONE mutant, flipping EXACTLY its
// own AT7 row DENY->ALLOW; it is disjoint from every A*/G*/L*/C*/AT1-6 gate (no existing
// mutant flips AT7, and the AT7 mutant flips no existing row).
// ─────────────────────────────────────────────────────────────────────────────────────

// The server-side repo_slug -> team_id binding (cp_repoteam, first-writer-wins). One
// entry: the rally repo the split bug was found on. This is the SINGLE authority every
// client model must converge on.
const SERVER_REPO_TEAM = { "randomittin/rally": "5eff00d5eff00d5eff00d5eff00d5eff" };
function deriveTeamId(secret) { return "sha256:" + secret; }             // mirrors cp_auth.derive_team_id.
function serverRepoTeam(slug) { return SERVER_REPO_TEAM[slug] || null; } // cp_repoteam.get/mint_team_for_repo.

// ── INV-AUTOTEAM (repo convergence) — the client resolves the operative team_id for a
//    github repo. GOLDEN (fixed): every resolution model returns the server repo->team
//    binding, so all machines on one repo_slug converge. MUTANT (the CURRENT pre-fix
//    client): a committed secret / auto-solo mint pre-empts /team/auto, deriving
//    sha256(secret) instead — so the SAME repo_slug splits into different team_ids. ──
export function clientResolveTeamId(gates, model, slug, ctx) {
  if (gates.clientPreemptsServerBinding) {                 // MUTANT = the CURRENT (pre-fix) client.
    if (model === "committed-secret") return deriveTeamId(ctx.committedSecret);
    if (model === "auto-solo")        return deriveTeamId(ctx.soloSecret);
    return serverRepoTeam(slug);                           // only the /team/auto path hits the server.
  }
  return serverRepoTeam(slug);                             // GOLDEN (fixed): the server binding is THE authority.
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
    case "G1-god-on-public": {
      // INV-GOD. An anonymous / public caller hits GET /god/roster on the internet-facing
      // PUBLIC surface. It MUST 404 — /god/* is not on the public route allowlist.
      // Resolving the route (reaching the aggregate) on the public surface is the ALLOW.
      return publicSurfaceRoute(gates, "/god/roster") ? "ALLOW" : "DENY";
    }
    case "G2-team-secret-god": {
      // INV-GOD. A holder of a valid team secret S points it at /god/roster. A team
      // secret is a PUBLIC-surface bearer ONLY — it never reaches the gated CP service,
      // so it hits the public router, where /god/* 404s and returns only derive_team_id(S)
      // routes. Reaching the cross-tenant aggregate with a team secret is the ALLOW.
      const teamSecretRequest = { secret: TEAM_A.cred_secret, path: "/god/roster" };
      const reachedAggregate = publicSurfaceRoute(gates, teamSecretRequest.path);
      return reachedAggregate ? "ALLOW" : "DENY";
    }
    case "G3-nonowner-god": {
      // INV-GOD. A legitimately SIGNED non-owner key hits the GATED /god/roster: valid
      // PKI signature, IAM-authorized, but identity.owner=false => must 401 not_owner.
      // Passing the owner gate (reaching the aggregate) is the ALLOW.
      const identity = NONOWNER;
      const iamOk = identity.iam === true; // IAM authorizes; only the owner gate should stop it.
      const passedOwnerGate = iamOk && requireOwner(gates, identity);
      return passedOwnerGate ? "ALLOW" : "DENY";
    }
    case "G4-god-cross-partition": {
      // INV-1 inside the owner aggregate. The OWNER calls the gated /god/roster but
      // supplies a FORGED body team_id that is NOT a server-registered partition. Even
      // for the owner, INV-1 holds: partitions are enumerated SERVER-SIDE and the
      // caller-supplied team_id must be ignored. The forged id appearing in the
      // enumerated set (the aggregate honoring the wire team_id) is the ALLOW.
      const FORGED_TEAM_ID = "cccc2222cccc2222cccc2222cccc2222";
      const req = { caller: OWNER, body: { team_id: FORGED_TEAM_ID } };
      // owner PKI + valid signature + IAM already satisfied for the owner; the only
      // question is whether the aggregate trusts the caller-supplied team_id.
      const partitions = godEnumeratePartitions(gates, req);
      return partitions.includes(FORGED_TEAM_ID) ? "ALLOW" : "DENY";
    }
    case "G5-god-forged-iap": {
      // INV-GOD (IAP owner bridge). A browser hits the IAP-gated god surface with a FORGED IAP
      // JWT (the ES256 signature does NOT verify). The app-layer verify (cp_iap.iap_identity)
      // MUST reject it — owner is minted ONLY when the JWT's signature verifies AND its email ==
      // the configured owner. The SAME gate rejects an absent JWT and a valid JWT for any other
      // Google identity. Minting owner from a forged/absent/wrong-email JWT (trusting the IAP
      // edge instead of verifying the assertion) is the ALLOW.
      const forgedJwt = {
        sig_valid: false,               // the signature does NOT verify (forged / tampered).
        iss: "https://cloud.google.com/iap",
        aud: GOD_IAP_AUDIENCE,
        email: GOD_OWNER_EMAIL,
      };
      return iapGrantsOwner(gates, forgedJwt) ? "ALLOW" : "DENY";
    }
    case "L1-session-cross-team": {
      // INV-LOGIN-1. A VALID login session minted for team A (server-derived from
      // registeredTeam(haid:alice)) is presented to /dashboard-data with a body team_id=B
      // to read team B's roster. The read MUST stay scoped to the session's server-derived
      // teams; team B appearing in the read set (the read honoring the wire team_id) is the
      // ALLOW.
      const session = mintLoginSession(HAID_A.haid, [registeredTeam(HAID_A.haid)], 9999);
      const req = { body: { team_id: TEAM_B.team_id } };
      const readTeams = sessionReadTeams(gates, session, req);
      return readTeams.includes(TEAM_B.team_id) ? "ALLOW" : "DENY";
    }
    case "L2-tampered-session-teamids": {
      // INV-LOGIN-2. A mint request for haid:alice (enrolled in team A) carries a
      // client-tampered `teams` list that adds team B. Teams are server-derived at mint
      // from registeredTeam(haid) and signed in — the tampered team B must NOT enter the
      // session. Team B appearing in the minted session (the mint trusting the client
      // team list) is the ALLOW.
      const req = { body: { teams: [TEAM_A.team_id, TEAM_B.team_id] } };
      const teams = sessionMintTeams(gates, HAID_A.haid, req);
      return teams.includes(TEAM_B.team_id) ? "ALLOW" : "DENY";
    }
    case "L3-expired-session": {
      // INV-LOGIN-3. A session whose short TTL has lapsed (exp in the past) is presented
      // for a read. It MUST be rejected (401) before any read. The lapsed session being
      // treated as live (the read proceeding) is the ALLOW.
      const NOW = 1000;
      const expired = mintLoginSession(HAID_A.haid, [registeredTeam(HAID_A.haid)], NOW - 1);
      return sessionIsLive(gates, expired, NOW) ? "ALLOW" : "DENY";
    }
    case "L4-bad-signature-mint": {
      // INV-LOGIN-4. A mint request whose HAID signature fails verification. verify_identity
      // MUST reject it and issue NO session. The mint proceeding on an invalid signature
      // (a session issued) is the ALLOW.
      const assertion = { haid: HAID_A.haid, device_code: "dev-123", signature: "forged" };
      return mintVerifiesSignature(gates, assertion) ? "ALLOW" : "DENY";
    }
    case "L5-session-is-owner": {
      // INV-LOGIN-5. A login session (always Identity.owner=false) is pointed at an
      // owner/god route. It MUST NOT pass the owner gate — only owner-PKI + IAP grants
      // owner. The login session passing the owner gate is the ALLOW.
      const session = mintLoginSession(HAID_A.haid, [registeredTeam(HAID_A.haid)], 9999);
      return loginSessionPassesOwnerGate(gates, session) ? "ALLOW" : "DENY";
    }
    case "C1-unbound-chat": {
      // INV-CHAT. An UNBOUND (forged) chat_id hits a read verb (status/investigate/report).
      // With no {chat_id<->HAID<->team} binding it MUST resolve to NO team and get the link
      // instruction — never team data. Resolving a team (and thus returning data) for an
      // unbound/forged chat_id is the ALLOW.
      const UNBOUND_CHAT_ID = "chat:mallory"; // never bound; a bare, attacker-suppliable handle.
      const team = chatResolveTeam(gates, UNBOUND_CHAT_ID);
      return team ? "ALLOW" : "DENY";
    }
    case "AT1-noncollaborator-autojoin": {
      // INV-AUTOTEAM(B). Mallory has a real GitHub identity but is NOT a collaborator on the
      // bound repo alice/webapp. She hits POST /team/auto to auto-join. The Stratum-B
      // permission check MUST refuse — no binding written, the team stays invisible. Being
      // granted access with no collaborator entry (the check skipped) is the ALLOW.
      const req = { claimed_gh_user: "mallory", repo: "alice/webapp", gh_proof: { token_login: "mallory" } };
      return autoteamHasRepoAccess(gates, req.repo, req.claimed_gh_user) ? "ALLOW" : "DENY";
    }
    case "AT2-forged-gh-identity": {
      // INV-AUTOTEAM(A). The caller CLAIMS gh_user=alice (a real collaborator on alice/webapp)
      // but the forwarded gh_proof's true GET /user login is mallory. Stratum A re-derives the
      // login server-side and MUST refuse when it != the claim — a username claim is never
      // trusted. Minting the binding on a claim whose token login disagrees is the ALLOW.
      const req = { claimed_gh_user: "alice", gh_proof: { token_login: "mallory" } };
      return autoteamVerifyCaller(gates, req.gh_proof, req.claimed_gh_user) ? "ALLOW" : "DENY";
    }
    case "AT3-autojoin-wire-team-id": {
      // INV-1 (auto-join). A valid auto-join for the bound repo alice/webapp (-> team A)
      // carries a body team_id=B. The operative team MUST be resolved SERVER-SIDE from the
      // repo->team binding (team A), never the wire value. The wire team_id=B becoming the
      // operative team (the server honoring it) is the ALLOW.
      const req = { repo: "alice/webapp", body: { team_id: TEAM_B.team_id } };
      const team = autoteamResolveTeam(gates, req.repo, req);
      return team === TEAM_B.team_id ? "ALLOW" : "DENY";
    }
    case "AT4-public-read-only-autojoin": {
      // INV-AUTOTEAM(§5). carol/opensource is a PUBLIC repo; the caller holds only READ. The
      // public threshold is write/push (drive-by readers excluded), so a mere reader MUST be
      // refused. A read-only caller clearing the public threshold (the threshold dropped) is
      // the ALLOW.
      const req = { repo: "carol/opensource", permission: "read" };
      return autoteamMeetsThreshold(gates, req.repo, req.permission) ? "ALLOW" : "DENY";
    }
    case "AT5-unbound-repo-autojoin": {
      // INV-AUTOTEAM (initiate). dave/fresh has NO repo->team binding, and the caller holds
      // only READ (below admin/push). Auto-INITIATE requires admin/push — only someone who
      // controls the repo may mint + bind a team. A non-initiator inventing a team on an
      // unbound repo (any caller allowed to initiate) is the ALLOW.
      const req = { repo: "dave/fresh", permission: "read" };
      const bound = REPO_TEAM_BINDINGS[req.repo] != null;
      const initiated = !bound && autoteamCanInitiate(gates, req.repo, req.permission);
      return initiated ? "ALLOW" : "DENY";
    }
    case "AT6-haid-possession": {
      // INV-AUTOTEAM (haid possession). Mallory holds admin/push on a repo she controls and has
      // LEARNED a victim's already-enrolled HAID (haid:victim). She hits POST /team/auto binding
      // haid=victim to griefing-bind the victim into her team (cross-team visibility). The request
      // carries a possession assertion, but it is signed by MALLORY's key (pk:mallory), NOT the
      // victim's registered Ed25519 key (pk:victim). Only a request whose possession signature
      // verifies under the REGISTERED pubkey of the claimed haid may bind that haid, so the
      // signature-under-a-different-key (equally: a missing/forged sig) must be refused. Binding
      // haid=victim without a signature that verifies under the victim's registered key is the ALLOW.
      const req = { haid: "haid:victim", possessionSig: { verifies_under: "pk:mallory" } };
      return autoteamVerifiesHaidPossession(gates, req.haid, req.possessionSig) ? "ALLOW" : "DENY";
    }
    case "AT7-same-repo-one-team": {
      // INV-AUTOTEAM (repo convergence). Three machines, three distinct HAIDs, the SAME
      // repo_slug, all online+github, EACH entering through a DIFFERENT client resolution
      // model (a committed-secret team.json, a fresh /team/auto, an auto-solo mint). They
      // MUST resolve the SAME team_id — converge on the server repo->team binding. The
      // client pre-empting that binding (a committed secret / auto-solo mint winning over
      // /team/auto) so the models resolve DIFFERENT ids — same-repo teammates invisible to
      // each other, public repos exploding into per-machine solo teams — is the ALLOW.
      const slug = "randomittin/rally";
      const t1 = clientResolveTeamId(gates, "committed-secret", slug, { committedSecret: "S-rally" });
      const t2 = clientResolveTeamId(gates, "team-auto",        slug, {});
      const t3 = clientResolveTeamId(gates, "auto-solo",        slug, { soloSecret: "S-solo" });
      const converged = (t1 === t2) && (t2 === t3);
      return converged ? "DENY" : "ALLOW";
    }
    default:
      throw new Error("unknown attack id: " + attackId);
  }
}
