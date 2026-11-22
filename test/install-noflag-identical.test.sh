#!/usr/bin/env bash
# test/install-noflag-identical.test.sh -- INV-L8 (lean-core plan, T1.4): `install.sh` without `--reset` leaves the tree and $HEIMDALL_HOME exactly as the
# UNMODIFIED script did on the same fixture.
#
# Journey: a developer who already has hmd installed runs `install.sh` again with no flag (the upgrade). Given the fixture existing install of
# bin/lib/lean_install_fixture.sh (offline sandbox, fake claude and keychain, local snapshot as the source), when the no-flag upgrade has run, then
# every normalized component of what it left behind equals evals/lean/install-baseline.json, which was recorded from the unmodified install.sh.
# The reference is independent of the code under change: the baseline is a committed file, the fixture builds its own sandbox, nothing here reads the
# operator's HOME, ~/.heimdall or keychain.
#
# Re-run by the W6 sweep against the final tree and by T5.2's mutant (UC_TREE = a snapshot with one install.sh line broken must go RED here).
# To re-record (ONLY from an unmodified install.sh): bash bin/lib/lean_install_fixture.sh record > evals/lean/install-baseline.json
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE="$HERE/../evals/lean/install-baseline.json"
# shellcheck source=../bin/lib/lean_install_fixture.sh
. "$HERE/../bin/lib/lean_install_fixture.sh"

[ -f "$BASELINE" ] || uc_fatal "missing $BASELINE"
lean_fx_run
got="$LEAN_FX_JSON"
want="$(jq -S .components "$BASELINE")"

# the fixture really ran: both runs finished and the keychain was never asked
if [ "$LEAN_FX_INSTALL_RC" -eq 0 ]; then uc_ok "the first install.sh run finished"; else uc_bad "the first install.sh run exited $LEAN_FX_INSTALL_RC"; fi
if [ "$LEAN_FX_UPGRADE_RC" -eq 0 ]; then uc_ok "the no-flag upgrade run finished"; else uc_bad "the no-flag upgrade run exited $LEAN_FX_UPGRADE_RC"; fi
if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "the installer asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi

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

uc_finish
