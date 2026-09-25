#!/usr/bin/env bash
# heimdall-team-default.test.sh — zero-command default team: bare `hmd team` smart dispatch
# (mint / promote-if-private / show) + `hmd team auto` (SessionStart). SINGLE-FILE model:
# the committed team is <repo>/.heimdall/team.json TRACKED (git add -f past .gitignore) —
# there is no separate committed filename; "shared" == team.json is git-TRACKED. CARDINAL:
# never TRACK/commit team.json on a PUBLIC or gh-unverifiable repo (the leak guard).
# gh + repo are faked via PATH + temp git repos so nothing real is touched.
set -uo pipefail
TEAM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/heimdall-team"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
[ -x "$TEAM" ] || { echo "FATAL: $TEAM not executable"; exit 2; }
bash -n "$TEAM" || { echo "FATAL syntax"; exit 2; }

ROOT_TMP="$(mktemp -d)"; trap 'rm -rf "$ROOT_TMP"' EXIT
# fake gh that reports the repo's privacy from an env the caller sets ($FAKE_PRIVATE=true|false);
# absent FAKE_PRIVATE simulates an error (unverifiable).
mkgh(){ local d="$1"; mkdir -p "$d/fb"; cat > "$d/fb/gh" <<EOF
#!/usr/bin/env bash
[ "\$1" = api ] || exit 0
[ -n "\${FAKE_PRIVATE:-}" ] || exit 1     # unverifiable -> error
echo "\${FAKE_PRIVATE}"; exit 0
EOF
chmod +x "$d/fb/gh"; }

# a throwaway git repo with an origin + a .heimdall dir; $1=name $2=private(true/false/unset)
mkrepo(){ local n="$1" priv="${2:-}"; local r="$ROOT_TMP/$n"; mkdir -p "$r/.heimdall"; git -C "$r" init -q
  git -C "$r" remote add origin "https://github.com/fakeorg/$n.git"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  mkgh "$r"; printf '%s' "$r"; }
# run heimdall-team inside repo $1 with privacy $2 + extra env, from that repo's CWD
run(){ local r="$1" priv="$2"; shift 2
  ( cd "$r" && env PATH="$r/fb:/usr/bin:/bin" HOME="$r" HEIMDALL_TEAM_DIR="$r/.heimdall" \
      ${priv:+FAKE_PRIVATE=$priv} "$@" ); }
# team.json is git-TRACKED in repo $1? (== the committed private-repo team — the settled
# single-file model; there is no separate committed filename).
team_tracked(){ git -C "$1" ls-files -- .heimdall/team.json 2>/dev/null; }
secret_in_tree(){ git -C "$1" grep -lI team_secret -- "$(git -C "$1" ls-files)" 2>/dev/null | head -1; }

# 1) bare `hmd team` in a PRIVATE repo -> mint + COMMIT team.json (TRACKED)
R=$(mkrepo priv1 true); printf '{}' > "$R/.heimdall/identity.json"   # heimdall-active
run "$R" true bash "$TEAM" >/dev/null 2>&1
[ -n "$(team_tracked "$R")" ] && ok "bare/private: team.json committed (TRACKED)" || bad "bare/private: team.json not tracked"
git -C "$R" log --oneline 2>/dev/null | grep -qi 'team' && ok "bare/private: committed the team" || bad "bare/private: not committed"

# 2) bare `hmd team` in a PUBLIC repo -> mint personal team.json, NEVER track/commit (CARDINAL)
R=$(mkrepo pub1 false)
run "$R" false bash "$TEAM" >/dev/null 2>&1
[ -z "$(team_tracked "$R")" ] && ok "bare/PUBLIC: team.json NOT tracked (leak guard)" || bad "bare/PUBLIC: LEAK — team.json committed!"
[ -z "$(secret_in_tree "$R")" ] && ok "bare/PUBLIC: secret NOT in git tree" || bad "bare/PUBLIC: secret committed!"
[ -f "$R/.heimdall/team.json" ] && ok "bare/PUBLIC: personal team minted (presence works)" || bad "bare/PUBLIC: no personal team"

# 3) bare with team.shared.json already present -> show only, no NEW commit
R=$(mkrepo priv2 true); printf '{}' > "$R/.heimdall/identity.json"
run "$R" true bash "$TEAM" >/dev/null 2>&1   # first: mint+share
C1=$(git -C "$R" rev-list --count HEAD 2>/dev/null || echo 0)
run "$R" true bash "$TEAM" >/dev/null 2>&1   # second: should just show
C2=$(git -C "$R" rev-list --count HEAD 2>/dev/null || echo 0)
[ "$C1" = "$C2" ] && ok "bare/already-shared: no second commit (idempotent)" || bad "bare: re-committed ($C1->$C2)"

# 4) `auto` zero-command -> ALWAYS mints a solo team (presence works, no command)
R=$(mkrepo auto1 true)   # no heimdall-active marker yet
run "$R" true bash "$TEAM" auto >/dev/null 2>&1; sleep 0.2
[ -f "$R/.heimdall/team.json" ] && ok "auto: solo team minted (zero-config presence)" || bad "auto: no solo mint"

# 5) `auto` in PUBLIC repo -> solo mint only, NEVER tracks/commits (CARDINAL)
R=$(mkrepo auto-pub false); printf '{}' > "$R/.heimdall/identity.json"
run "$R" false bash "$TEAM" auto >/dev/null 2>&1; sleep 0.2
[ -z "$(team_tracked "$R")" ] && ok "auto/PUBLIC: NEVER auto-tracks team.json (leak guard)" || bad "auto/PUBLIC: LEAK"
[ -z "$(secret_in_tree "$R")" ] && ok "auto/PUBLIC: secret not in tree" || bad "auto/PUBLIC: secret committed"

# 6) `auto` in PRIVATE + heimdall-active + not-tracked -> auto-commits team.json (no push)
R=$(mkrepo auto-priv true); printf '{}' > "$R/.heimdall/identity.json"
run "$R" true bash "$TEAM" auto >/dev/null 2>&1; sleep 0.3
[ -n "$(team_tracked "$R")" ] && ok "auto/private+active: auto-committed team.json (TRACKED)" || bad "auto/private: did not commit"
# no remote push happened (origin has no objects pushed — bare check: no upstream)
git -C "$R" log @{u}.. >/dev/null 2>&1 && bad "auto: pushed (must not)" || ok "auto: did NOT push (commit only)"

# 7) `auto` idempotent: 2nd run with shared present -> no 2nd commit
C1=$(git -C "$R" rev-list --count HEAD 2>/dev/null || echo 0)
rm -f "$R/.heimdall/.team-auto-stamp" "$HOME/.heimdall/.team-auto-stamp" 2>/dev/null
run "$R" true bash "$TEAM" auto >/dev/null 2>&1; sleep 0.2
C2=$(git -C "$R" rev-list --count HEAD 2>/dev/null || echo 0)
[ "$C1" = "$C2" ] && ok "auto: idempotent (shared exists -> no 2nd commit)" || bad "auto: re-committed"

# 8) opt-out -> clean no-op (no solo mint, no commit)
R=$(mkrepo optout true); printf '{}' > "$R/.heimdall/identity.json"
run "$R" true env HEIMDALL_NO_TEAM_AUTOSHARE=1 bash "$TEAM" auto >/dev/null 2>&1; sleep 0.2
[ -z "$(team_tracked "$R")" ] && ok "auto/opt-out: no commit (not tracked)" || bad "auto/opt-out: committed anyway"

# 9) non-blocking: auto returns fast. Sampled 3x (a FRESH repo each time -- auto's own
# idempotency guards would make repeat runs on the SAME repo artificially fast and hide
# the real cold SessionStart cost) and judged on the MEDIAN, not a single sample: this
# path forks ~10-15 subprocesses (git/python/gh) and a lone sample is measurably noisy
# under shared-box scheduler contention (same code measured 2272ms at load 13.6 and
# 3174ms at load 15.6, back to back, on the same box). Median-of-N against a fixed
# budget is an EXISTING pattern for exactly this noise -- see
# test/heimdall-statusline-cursor-payload.test.sh's median render-time check -- reused
# here rather than inventing a new one. A genuinely broken/blocking path (e.g. a real
# network hop) is slow on every sample, so the median still catches it -- see the
# falsifiability check in test/heimdall-team-auto-github.test.sh-style harnesses: a
# fake `gh` that sleeps blocks EVERY sample, so the median fails too.
declare -a _auto_ms=()
for _i in 1 2 3; do
  R=$(mkrepo "fast$_i" true); printf '{}' > "$R/.heimdall/identity.json"
  T0=$(python3 -c 'import time;print(int(time.time()*1000))'); run "$R" true bash "$TEAM" auto >/dev/null 2>&1; T1=$(python3 -c 'import time;print(int(time.time()*1000))')
  _auto_ms+=("$((T1-T0))")
done
AUTO_MED="$(printf '%s\n' "${_auto_ms[@]}" | sort -n | sed -n '2p')"
# Budget widened 3000ms -> 6000ms (measurement-justified, not arbitrary): this box's
# load ranged 12.3-31.1 across the diagnosis session (exceeding the 13-22 the original
# evidence described) and even the FORK-REDUCED path (gh_auto no longer forks a
# remote-url lookup and a python slug-parse it does not need before the auth check;
# do_share reuses cmd_auto's already-resolved visibility instead of recomputing it;
# current_identity dropped a confirmed-always-failing "heimdall-identity current"
# fork) still measured medians of 2558-3639ms and single samples up to 3899ms at
# load 16-31. 6000ms keeps real headroom above that observed ceiling while staying
# far below any real network RTT (this path is proven network-free -- gh_auto
# returns at the empty-GH_PROOF check every time in this hermetic harness -- so a
# regression that reintroduces a network hop, which this codebase's own timeouts
# put at 5-10s per call (curl -m 5 / urlopen timeout=10), still trips it).
[ "$AUTO_MED" -lt 6000 ] && ok "auto non-blocking (median ${AUTO_MED}ms of ${_auto_ms[*]})" || bad "auto slow (median ${AUTO_MED}ms of ${_auto_ms[*]})"

# 10) MIGRATION (the rally fix): a PRIVATE repo with a GITIGNORED + UNCOMMITTED auto-solo
#     team.json (minted while visibility was indeterminate — no committed path ran) is the
#     exact state that leaves clones NOT auto-joining. The clear command `hmd team` (bare)
#     must PROMOTE it to the committed/tracked path so a clone carries it. Falsifiable: bare
#     `hmd team` used to be STATUS-ONLY (never promoted) -> this asserted TRACKED transition
#     is RED without the smart-dispatch fix, GREEN with it.
R=$(mkrepo migrate true); printf '{}' > "$R/.heimdall/identity.json"
# reproduce the broken state: `auto` on an INDETERMINATE-visibility session gitignores +
# mints an auto-solo team.json but never commits it.
run "$R" "" env FAKE_PRIVATE= HEIMDALL_FORCE_VISIBILITY=indeterminate bash "$TEAM" auto >/dev/null 2>&1; sleep 0.2
M_PRE="$(team_tracked "$R")"
M_SRC_PRE="$(HMD_F="$R/.heimdall/team.json" python3 -c "import json,os;print(json.load(open(os.environ['HMD_F'])).get('source'))" 2>/dev/null || true)"
if [ -f "$R/.heimdall/team.json" ] && [ -z "$M_PRE" ] && [ "$M_SRC_PRE" = "auto-solo" ]; then
  ok "migrate/setup: team.json is gitignored + UNCOMMITTED auto-solo (the rally broken state)"
else
  bad "migrate/setup: expected an untracked auto-solo team.json (tracked='$M_PRE' src='$M_SRC_PRE')"
fi
# THE FIX: RJ (owner, proven-private) runs the ONE clear command `hmd team` -> promote.
M_SECRET_PRE="$(HMD_F="$R/.heimdall/team.json" python3 -c "import json,os;print(json.load(open(os.environ['HMD_F'])).get('team_secret'))" 2>/dev/null || true)"
run "$R" true bash "$TEAM" >/dev/null 2>&1
M_POST="$(team_tracked "$R")"
M_SECRET_POST="$(HMD_F="$R/.heimdall/team.json" python3 -c "import json,os;print(json.load(open(os.environ['HMD_F'])).get('team_secret'))" 2>/dev/null || true)"
if [ -n "$M_POST" ] && [ "$M_SECRET_POST" = "$M_SECRET_PRE" ]; then
  ok "migrate: bare 'hmd team' PROMOTED the gitignored team.json to TRACKED (same secret preserved) — clones now carry it"
else
  bad "migrate: bare 'hmd team' did not promote (tracked='$M_POST' secret_preserved=$([ "$M_SECRET_POST" = "$M_SECRET_PRE" ]&&echo y||echo n))"
fi
# The promoted secret is present in the git TREE (a clone would carry it) — private repo only.
[ -n "$(git -C "$R" grep -lF "$M_SECRET_POST" 2>/dev/null)" ] && ok "migrate: promoted secret is in the git tree (a clone == join)" || bad "migrate: promoted secret not in tree"

echo "──────────────────────────────────────"
echo "heimdall-team-default: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
