#!/usr/bin/env bash
# test/install-noflag-identical.test.sh -- INV-L8 (lean-core plan, T1.4): `install.sh` without `--reset` leaves the tree and $HEIMDALL_HOME exactly as the
# UNMODIFIED script did on the same fixture.
#
# Journey: a developer who already has hmd installed runs `install.sh` again with no flag (the upgrade). Given the fixture existing install of
# bin/lib/lean_install_fixture.sh (offline sandbox, fake claude and keychain, local snapshot as the source) made by the UNMODIFIED install.sh, when the
# tree's install.sh runs over it with no flag, then every normalized component of what it left behind equals evals/lean/install-baseline.json, which was
# recorded from the unmodified install.sh. The existing install is NOT made by the tree's own script: since T3.4 a fresh install by it is lean and records
# a profile, which is not the install INV-L8 is about. The unmodified script is the one the baseline names (commit and hash), read from git history.
# The reference is independent of the code under change: the baseline is a committed file, the script it was recorded from is pinned by that hash, the
# fixture builds its own sandbox, nothing here reads the operator's HOME, ~/.heimdall or keychain.
#
# Re-run by the W6 sweep against the final tree and by T5.2's mutant (UC_TREE = a snapshot with one install.sh line broken must go RED here: a line the
# no-flag upgrade of an existing install runs and whose effect shows in what it leaves, the existing install itself is made by the pinned script).
# To re-record (ONLY from an unmodified, committed install.sh): bash bin/lib/lean_install_fixture.sh record > evals/lean/install-baseline.json
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE="$HERE/../evals/lean/install-baseline.json"
# shellcheck source=../bin/lib/lean_install_fixture.sh
. "$HERE/../bin/lib/lean_install_fixture.sh"

[ -f "$BASELINE" ] || uc_fatal "missing $BASELINE"
lean_fx_run "$BASELINE"
got="$LEAN_FX_JSON"
want="$(jq -S .components "$BASELINE")"

# the fixture really ran: both runs finished and the keychain was never asked
if [ "$LEAN_FX_INSTALL_RC" -eq 0 ]; then uc_ok "the first install.sh run finished"; else uc_bad "the first install.sh run exited $LEAN_FX_INSTALL_RC"; fi
if [ "$LEAN_FX_UPGRADE_RC" -eq 0 ]; then uc_ok "the no-flag upgrade run finished"; else uc_bad "the no-flag upgrade run exited $LEAN_FX_UPGRADE_RC"; fi
if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "the installer asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi

# the existing install is the unmodified script's, not the tree's: INV-L8 grades what the tree's script does to an install that already exists
base_want="$(jq -r .recorded_from.install_sh_sha256 "$BASELINE")"
if [ "$LEAN_FX_BASE_INSTALL_SHA256" = "$base_want" ]; then
  uc_ok "the existing install was made by the install.sh the baseline was recorded from"
else
  uc_bad "the existing install was made by another install.sh than the baseline's" "ran $LEAN_FX_BASE_INSTALL_SHA256, the baseline says $base_want"
fi

# the whole state, then each component so a failure names the part that moved
if [ "$(printf '%s' "$got" | jq -r .state_sha256)" = "$(printf '%s' "$want" | jq -r .state_sha256)" ]; then
  uc_ok "state_sha256 equals the baseline recorded from the unmodified install.sh"
else
  uc_bad "state_sha256 differs from the baseline"
fi
for key in install_exit upgrade_exit clone_tree_equals_source clone_tracked_modified_by_install added_files; do
  if [ "$(printf '%s' "$got" | jq -c ".$key")" = "$(printf '%s' "$want" | jq -c ".$key")" ]; then
    uc_ok "$key equals the baseline"
  else
    uc_bad "$key differs from the baseline" "got $(printf '%s' "$got" | jq -c ".$key" | head -c 300) want $(printf '%s' "$want" | jq -c ".$key" | head -c 300)"
  fi
done
for key in $(printf '%s' "$want" | jq -r '.digests | keys[]'); do
  if [ "$(printf '%s' "$got" | jq -r ".digests.$key")" = "$(printf '%s' "$want" | jq -r ".digests.$key")" ]; then
    uc_ok "digest $key equals the baseline"
  else
    uc_bad "digest $key differs from the baseline"
  fi
done
if [ "$(printf '%s' "$got" | jq '.digests | keys | length')" = "$(printf '%s' "$want" | jq '.digests | keys | length')" ]; then
  uc_ok "no digest was added or dropped"
else
  uc_bad "the set of digests changed"
fi

# the reference has teeth: a change to what the installer left behind moves its digest and the state hash (no re-install needed)
printf 'export INJECTED=1\n' >> "$UC_HOME/.zshrc"
mut="$(lean_fx_seal "$(lean_fx_components)")"
if [ "$(printf '%s' "$mut" | jq -r .digests.zshrc)" != "$(printf '%s' "$want" | jq -r .digests.zshrc)" ] \
  && [ "$(printf '%s' "$mut" | jq -r .state_sha256)" != "$(printf '%s' "$want" | jq -r .state_sha256)" ]; then
  uc_ok "an extra profile line is detected (the digest and the state hash move)"
else
  uc_bad "an extra profile line went unnoticed: the digest cannot tell a changed install from an unchanged one"
fi

# the pinned input is locked, not trusted: a baseline whose hash, commit or commit field does not fit what git holds is refused with the cause named
# (lean_fx_run then stops with "cannot run this journey"), never answered by running some other install.sh
expect_refused() {   # LABEL JQ-EDIT-OF-THE-BASELINE CAUSE-TEXT
  local doc="$UC_ROOT/refused-baseline.json" out rc
  jq "$2" "$BASELINE" > "$doc"
  out="$(lean_fx_baseline_installer "$doc" "$UC_ROOT/refused-installer/install.sh" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$3"; then uc_ok "$1"; else uc_bad "$1" "exit $rc: $(printf '%s' "$out" | head -c 300)"; fi
}
expect_refused "a baseline naming another install.sh hash is refused" \
  '.recorded_from.install_sh_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "was recorded from"
expect_refused "a baseline naming a commit this repository lacks is refused" \
  '.recorded_from.repo_head = "1111111111111111111111111111111111111111"' "not in this repository"
expect_refused "a baseline whose repo_head is not a commit id is refused" \
  '.recorded_from.repo_head = "--output=elsewhere"' "names no commit"

uc_finish
