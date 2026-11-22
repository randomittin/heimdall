#!/usr/bin/env bash
# Journey 11 -- start a team in a repo and bring a teammate onto it (commands/team.md "/hmd:team", bin/heimdall-team "one file, one secret", DATA.md "Does hmd commit team.json?").
#
#   Asha and Ben work on the same repo, each on a machine of their own (a HOME each). The repo has no remote, so hmd cannot prove it private and the team secret, a bearer
#   capability, has to travel out of band. No control plane answers (a dead port): nothing here may need one.
#     1. Asha runs `hmd team new` at a terminal: exit 0, the team_id is announced, the secret is stored 0600 in .heimdall/team.json, the repo's .gitignore names that file
#        and nothing is committed, and the join one-liner is printed once, carrying the secret and the control-plane URL
#     2. Asha commits the ignore rule and Ben clones the repo: the secret did not travel with the clone, and `hmd team show` says Ben is on no team
#     3. a paste cut short (under 32 characters) is refused (exit 2) and writes nothing
#     4. Ben takes the secret from Asha's join and runs `hmd team join`: exit 0, "Joined team <Asha's team_id>", stored 0600
#     5. `hmd team show` on both machines gives the same team_id, the one the server derives from the secret (the first 32 hex digits of sha256 over "heimdall-team", a NUL
#        byte and the secret), in text and in --json, and never prints the secret
#     6. the secret is in no file but the two team.json: not in either HOME or repo, not in the temp dir, in no commit; both working trees are clean
#
# `hmd team new` prints the join only to a person at a terminal (heimdall-invite refuses a pipe), so it runs under a pseudo-terminal; the harness default is no tty.
# The network is faked at curl: `new` probes the installer URL it is about to print, and the double answers 200 and records every call.
# Engines reused: test/heimdall-team.test.sh (b new, d show, f join, g no leak), test/install-team-secret.test.sh (0600, gitignore).
# Mutants (test/use-cases/mutants.list): join stores a different secret than the one pasted, team.json is made readable by everyone.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 11_start_and_join_a_team
uc_tree
uc_fakebin

# the network: the one call `hmd team new` makes (is the installer it is about to print there?) is answered 200 and logged
CURL_LOG="$UC_ROOT/curl.log"
: > "$CURL_LOG"
cat > "$UC_BIN/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$CURL_LOG"
printf 200
EOF
chmod +x "$UC_BIN/curl"

# a terminal: a command run through this has a pseudo-terminal for stdin, stdout and stderr, as for a person at a prompt (uc_run itself never has one)
PTY_PY='import os, pty, sys; st = pty.spawn(sys.argv[1:]); sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st))'
"$UC_PY" -I -c 'import pty; pty.openpty()' >/dev/null 2>&1 || uc_fatal "no pseudo-terminal can be opened here: hmd team new prints the join only to a terminal"

HMD="$UC_TREE/bin/hmd"
uc_sandbox asha; A_HOME="$UC_HOME"; A_WORK="$UC_WORK"
uc_sandbox ben;  B_HOME="$UC_HOME"; B_WORK="$UC_WORK"
A_REPO="$A_WORK/shop"; B_REPO="$B_WORK/shop"
A_TEAM="$A_REPO/.heimdall/team.json"; B_TEAM="$B_REPO/.heimdall/team.json"
asha() { uc_run "$A_HOME" "$A_REPO" -- "$@"; }
ben()  { uc_run "$B_HOME" "$B_REPO" -- "$@"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

mkdir -p "$A_REPO"
asha git init -q
asha git config user.email asha@example.com
asha git config user.name Asha
printf '# shop\n' > "$A_REPO/README.md"
asha git add README.md
asha git commit -q -m "start the shop"
uc_rc "(setup) Asha's repo has its first commit" 0
asha git remote
if [ ! -s "$UC_OUT" ]; then uc_ok "(setup) the repo has no remote: hmd cannot prove it private"; else uc_bad "(setup) the repo has a remote, so this is not the unprovable-privacy case"; fi

# 1. Asha starts a team, at a terminal
asha python3 -I -c "$PTY_PY" "$HMD" team new
uc_rc "Asha: hmd team new at a terminal" 0
SCREEN="$UC_ROOT/asha-new.screen"
LC_ALL=C tr -d '\r' < "$UC_OUT" > "$SCREEN"
uc_has "the new team's id is announced" "$SCREEN" '^Minted a new team for this repo \(team_id [0-9a-f]{32}\)\.$'
NEW_TID="$(sed -n 's/^Minted a new team for this repo (team_id \([0-9a-f]*\))\.$/\1/p' "$SCREEN" | head -1)"
if [ -f "$A_TEAM" ]; then uc_ok "the secret is stored in <repo>/.heimdall/team.json"; else uc_bad "no team file at $A_TEAM"; fi
if [ "$(mode_of "$A_TEAM")" = 600 ]; then uc_ok "…mode 0600"; else uc_bad "the team file is mode $(mode_of "$A_TEAM"), want 600"; fi
uc_jq "…holding a base64url secret of at least 32 characters, minted by new" '.source == "new" and (.team_secret | test("^[A-Za-z0-9_-]{32,}$"))' "$A_TEAM"
uc_has "the join one-liner fetches the installer over https" "$SCREEN" "curl -fsSL --proto '=https' https://raw\\.githubusercontent\\.com/[^ ]+/install\\.sh -o "
uc_has "…and runs it with the control-plane URL (the dead port) and the team secret" "$SCREEN" "HEIMDALL_CP_URL='http://127\\.0\\.0\\.1:9' HEIMDALL_TEAM_SECRET='[A-Za-z0-9_-]{32,}' bash "
uc_has "…under a warning that it contains the team secret" "$SCREEN" 'contains your team secret'
SECRET="$(sed -n "s/.*HEIMDALL_TEAM_SECRET='\([^']*\)'.*/\1/p" "$SCREEN" | head -1)"
if [ -n "$SECRET" ] && [ "$SECRET" = "$(jq -r '.team_secret' "$A_TEAM" 2>/dev/null)" ]; then uc_ok "…and the secret in the join is the one stored in team.json"; else uc_bad "the secret in the printed join is not the one in team.json"; fi
if [ "$(grep -cF -- "$SECRET" "$SCREEN")" = 1 ]; then uc_ok "…printed once"; else uc_bad "the secret appears $(grep -cF -- "$SECRET" "$SCREEN") times on the screen, want 1"; fi
uc_has "the repo's .gitignore names the team file, so it cannot be committed by accident" "$A_REPO/.gitignore" '^\.heimdall/team\.json$'
asha git rev-list --count HEAD
if [ "$(tr -d '\n' < "$UC_OUT")" = 1 ]; then uc_ok "…and nothing was committed"; else uc_bad "the repo has $(tr -d '\n' < "$UC_OUT") commits, want 1"; fi
asha git ls-files -- .heimdall
if [ ! -s "$UC_OUT" ]; then uc_ok "…and git does not track the team file"; else uc_bad "git tracks: $(head -c 200 "$UC_OUT" | LC_ALL=C tr '\n' ' ')"; fi

# 2. Asha commits the ignore rule; Ben clones the repo
asha git add .gitignore
asha git commit -q -m "ignore the team secret"
uc_rc "Asha commits the ignore rule" 0
asha git status --porcelain
if [ ! -s "$UC_OUT" ]; then uc_ok "…her working tree is clean: the team file is ignored, not left for a blanket git add"; else uc_bad "Asha's working tree is not clean: $(head -c 200 "$UC_OUT" | LC_ALL=C tr '\n' ' ')"; fi
uc_run "$B_HOME" "$B_WORK" -- git clone -q "$A_REPO" "$B_REPO"
uc_rc "Ben clones the repo" 0
if [ ! -e "$B_TEAM" ]; then uc_ok "the secret did not travel with the clone: Ben's copy has no team file"; else uc_bad "Ben's fresh clone already holds a team file"; fi
ben "$HMD" team show --json
uc_rc "Ben: hmd team show before joining" 0
uc_jq "…says Ben is on no team yet" '.configured == false and .team_id == null' "$UC_OUT"

# 3. a paste cut short is refused
SHORT="$(printf '%s' "$SECRET" | cut -c1-20)"
ben "$HMD" team join "$SHORT"
uc_rc "Ben pastes only the start of the secret: hmd team join refuses it" 2
uc_has "…as a weak secret, and says to ask for the full one" "$UC_ERR" 'refusing a weak team secret'
if [ ! -e "$B_TEAM" ]; then uc_ok "…and wrote nothing"; else uc_bad "the refused join wrote a team file"; fi

# 4. Ben joins with the secret from Asha's join
ben "$HMD" team join "$SECRET"
uc_rc "Ben: hmd team join with the secret from Asha's join" 0
cp "$UC_OUT" "$UC_ROOT/ben-join.out"
JOINED_TID="$(sed -n 's/^Joined team \([0-9a-f]*\) for this repo\.$/\1/p' "$UC_ROOT/ben-join.out" | head -1)"
if [ -n "$JOINED_TID" ] && [ "$JOINED_TID" = "$NEW_TID" ]; then uc_ok "…he is told he joined Asha's team (the team_id new announced)"; else uc_bad "join named team '$JOINED_TID', new announced '$NEW_TID'"; fi
if [ "$(mode_of "$B_TEAM")" = 600 ]; then uc_ok "…his team file is mode 0600"; else uc_bad "Ben's team file is mode $(mode_of "$B_TEAM"), want 600"; fi

# 5. show gives the same team_id on both machines, derived as the server derives it, and never the secret
WANT_TID="$(printf 'heimdall-team\0%s' "$SECRET" | shasum -a 256 | cut -c1-32)"
asha "$HMD" team show --json
uc_rc "Asha: hmd team show --json" 0
cp "$UC_OUT" "$UC_ROOT/asha-show.json"
ben "$HMD" team show --json
uc_rc "Ben: hmd team show --json" 0
cp "$UC_OUT" "$UC_ROOT/ben-show.json"
asha "$HMD" team show
uc_rc "Asha: hmd team show" 0
cp "$UC_OUT" "$UC_ROOT/asha-show.txt"
ben "$HMD" team show
uc_rc "Ben: hmd team show" 0
cp "$UC_OUT" "$UC_ROOT/ben-show.txt"
uc_jq "Asha's team is configured, not tracked by git, with a 32-digit team_id" '.configured == true and .tracked == false and (.team_id | test("^[0-9a-f]{32}$"))' "$UC_ROOT/asha-show.json"
uc_jq "Ben's team is configured, not tracked by git, with a 32-digit team_id" '.configured == true and .tracked == false and (.team_id | test("^[0-9a-f]{32}$"))' "$UC_ROOT/ben-show.json"
A_TID="$(jq -r '.team_id' "$UC_ROOT/asha-show.json" 2>/dev/null)"
B_TID="$(jq -r '.team_id' "$UC_ROOT/ben-show.json" 2>/dev/null)"
if [ -n "$A_TID" ] && [ "$A_TID" = "$B_TID" ]; then uc_ok "both machines report the same team_id"; else uc_bad "Asha's team_id is '$A_TID', Ben's is '$B_TID'"; fi
if [ "$A_TID" = "$WANT_TID" ]; then uc_ok "…the one the server derives from the secret"; else uc_bad "show says '$A_TID', the server's derivation gives '$WANT_TID'"; fi
if [ "$A_TID" = "$NEW_TID" ]; then uc_ok "…and the one new announced"; else uc_bad "show says '$A_TID', new announced '$NEW_TID'"; fi
uc_has "Asha's text show prints the team_id too" "$UC_ROOT/asha-show.txt" "^team_id: +$WANT_TID\$"
uc_has "Ben's text show prints the team_id too" "$UC_ROOT/ben-show.txt" "^team_id: +$WANT_TID\$"
LEAKED=""
for f in asha-show.json asha-show.txt ben-show.json ben-show.txt ben-join.out; do
  if grep -qF -- "$SECRET" "$UC_ROOT/$f"; then LEAKED="$LEAKED $f"; fi
done
if [ -z "$LEAKED" ]; then uc_ok "neither show (text or --json, on either machine) nor join ever prints the secret"; else uc_bad "the secret was printed in:$LEAKED"; fi

# 6. the secret is in no file but the two team files, and in no commit
HITS="$(grep -rlF -- "$SECRET" "$UC_ROOT/asha" "$UC_ROOT/ben" "$UC_TMP" 2>/dev/null | LC_ALL=C sort)"
WANT_HITS="$(printf '%s\n%s\n' "$A_TEAM" "$B_TEAM" | LC_ALL=C sort)"
if [ "$HITS" = "$WANT_HITS" ]; then uc_ok "the secret is in exactly two files, each developer's own .heimdall/team.json (both HOMEs, both repos and the temp dir searched)"; else uc_bad "the secret was found in: $(printf '%s' "$HITS" | LC_ALL=C tr '\n' ' ')"; fi
asha git log --all --name-only --format=
uc_has "(control) the history listing shows Asha's own files" "$UC_OUT" '^README\.md$'
uc_lacks "no commit of Asha's repo ever carried .heimdall/team.json" "$UC_OUT" 'team\.json'
ben git log --all --name-only --format=
uc_lacks "…nor does any commit in Ben's clone" "$UC_OUT" 'team\.json'
ben git status --porcelain
if [ ! -s "$UC_OUT" ]; then uc_ok "Ben's working tree is clean after joining: his team file is ignored too"; else uc_bad "Ben's working tree is not clean: $(head -c 200 "$UC_OUT" | LC_ALL=C tr '\n' ' ')"; fi

# the doubles: the network was asked about the installer in the join and nothing else; no model session, no keychain
JOIN_URL="$(sed -n "s/.*curl -fsSL --proto '=https' \(https:[^ ]*\) -o .*/\1/p" "$SCREEN" | head -1)"
if [ -n "$JOIN_URL" ] && grep -qF -- "$JOIN_URL" "$CURL_LOG" && ! grep -vqF -- "$JOIN_URL" "$CURL_LOG"; then uc_ok "the only network call was the check that the installer in the join exists"; else uc_bad "the network calls were not just the check of the join's installer ($JOIN_URL)" "$(head -c 300 "$CURL_LOG" | LC_ALL=C tr '\n' '|')"; fi
if [ ! -s "$UC_CLAUDE_LOG" ] && [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "no model session and no keychain access in the whole journey"; else uc_bad "the journey called claude or the keychain" "$(cat "$UC_CLAUDE_LOG" "$UC_SECURITY_LOG" | head -c 200)"; fi

uc_finish
