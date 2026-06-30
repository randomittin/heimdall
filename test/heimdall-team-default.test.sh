#!/usr/bin/env bash
# heimdall-team-default.test.sh — zero-command default team: bare `hmd team` smart dispatch
# (mint / share-if-private / show) + `hmd team auto` (SessionStart). CARDINAL: never
# create/commit team.shared.json on a PUBLIC or gh-unverifiable repo (the leak guard).
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
shared_of(){ echo "$1/.heimdall/team.shared.json"; }
secret_in_tree(){ git -C "$1" grep -lI team_secret -- "$(git -C "$1" ls-files)" 2>/dev/null | head -1; }

# 1) bare `hmd team` in a PRIVATE repo -> mint + share (team.shared.json committed)
R=$(mkrepo priv1 true); printf '{}' > "$R/.heimdall/identity.json"   # heimdall-active
run "$R" true bash "$TEAM" >/dev/null 2>&1
[ -f "$(shared_of "$R")" ] && ok "bare/private: team.shared.json created" || bad "bare/private: no shared file"
git -C "$R" log --oneline 2>/dev/null | grep -qi 'team' && ok "bare/private: committed the share" || bad "bare/private: not committed"

# 2) bare `hmd team` in a PUBLIC repo -> mint personal, NEVER share (CARDINAL)
R=$(mkrepo pub1 false)
run "$R" false bash "$TEAM" >/dev/null 2>&1
[ ! -f "$(shared_of "$R")" ] && ok "bare/PUBLIC: NO team.shared.json (leak guard)" || bad "bare/PUBLIC: LEAK — shared file created!"
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

# 5) `auto` in PUBLIC repo -> solo only, NEVER shares (CARDINAL)
R=$(mkrepo auto-pub false); printf '{}' > "$R/.heimdall/identity.json"
run "$R" false bash "$TEAM" auto >/dev/null 2>&1; sleep 0.2
[ ! -f "$(shared_of "$R")" ] && ok "auto/PUBLIC: NEVER auto-shares (leak guard)" || bad "auto/PUBLIC: LEAK"
[ -z "$(secret_in_tree "$R")" ] && ok "auto/PUBLIC: secret not in tree" || bad "auto/PUBLIC: secret committed"

# 6) `auto` in PRIVATE + heimdall-active + not-shared -> auto-commits team.shared.json (no push)
R=$(mkrepo auto-priv true); printf '{}' > "$R/.heimdall/identity.json"
run "$R" true bash "$TEAM" auto >/dev/null 2>&1; sleep 0.3
[ -f "$(shared_of "$R")" ] && ok "auto/private+active: auto-shared (committed)" || bad "auto/private: did not share"
# no remote push happened (origin has no objects pushed — bare check: no upstream)
git -C "$R" log @{u}.. >/dev/null 2>&1 && bad "auto: pushed (must not)" || ok "auto: did NOT push (commit only)"

# 7) `auto` idempotent: 2nd run with shared present -> no 2nd commit
C1=$(git -C "$R" rev-list --count HEAD 2>/dev/null || echo 0)
rm -f "$R/.heimdall/.team-auto-stamp" "$HOME/.heimdall/.team-auto-stamp" 2>/dev/null
run "$R" true bash "$TEAM" auto >/dev/null 2>&1; sleep 0.2
C2=$(git -C "$R" rev-list --count HEAD 2>/dev/null || echo 0)
[ "$C1" = "$C2" ] && ok "auto: idempotent (shared exists -> no 2nd commit)" || bad "auto: re-committed"

# 8) opt-out -> clean no-op (no solo mint, no share)
R=$(mkrepo optout true); printf '{}' > "$R/.heimdall/identity.json"
run "$R" true env HEIMDALL_NO_TEAM_AUTOSHARE=1 bash "$TEAM" auto >/dev/null 2>&1; sleep 0.2
[ ! -f "$(shared_of "$R")" ] && ok "auto/opt-out: no share" || bad "auto/opt-out: shared anyway"

# 9) non-blocking: auto returns fast
R=$(mkrepo fast true); printf '{}' > "$R/.heimdall/identity.json"
T0=$(python3 -c 'import time;print(int(time.time()*1000))'); run "$R" true bash "$TEAM" auto >/dev/null 2>&1; T1=$(python3 -c 'import time;print(int(time.time()*1000))')
[ "$((T1-T0))" -lt 3000 ] && ok "auto non-blocking ($((T1-T0))ms)" || bad "auto slow ($((T1-T0))ms)"

echo "──────────────────────────────────────"
echo "heimdall-team-default: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
