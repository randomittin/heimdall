#!/usr/bin/env bash
# bin/lib/lean_install_fixture.sh -- the INDEPENDENT reference for INV-L8 (lean-core plan, T1.4).
#
#   INV-L8: `install.sh` without `--reset` leaves the tree and $HEIMDALL_HOME byte-identical to the unmodified script's result on the same fixture.
#
# The fixture is an EXISTING install: the developer's machine (their own .zshrc line and ~/.claude/settings.json key) after one install.sh run, then the
# no-flag UPGRADE run (the same script again, no argument). It reuses the offline sandbox of test/use-cases/lib.sh: a private HOME under a private temp
# root, `env -i`, a fake `claude` and `security` (the keychain is never reached), HEIMDALL_REPO a local snapshot so the one network call never leaves the
# machine. Nothing here reads or writes the operator's HOME, ~/.heimdall, ~/.claude or keychain.
#
# What the run leaves behind is reduced to NORMALIZED components, never raw bytes of volatile files: timestamps, run ids, the host name, durations, the
# team secret and the sandbox path differ on every run and machine, so each file is reduced to the part the installer decides (a path list, a
# normalized line, a field set) before it is hashed. The cloned tree is compared to the source tree it was cloned from (a tree id, not a constant: the
# source moves with every commit), and the tracked files the install itself leaves modified are listed by name.
#
#   source bin/lib/lean_install_fixture.sh     then:  lean_fx_run   (builds the fixture, runs the upgrade, sets LEAN_FX_JSON)
#   bash bin/lib/lean_install_fixture.sh digest   print the components JSON for the tree under test (UC_TREE overrides the tree: a mutant is a snapshot)
#   bash bin/lib/lean_install_fixture.sh record   print the baseline document (components + provenance) -- run ONLY on an unmodified install.sh
#
# Bash 3.2 compatible.
# shellcheck disable=SC2034  # LEAN_FX_* are this library's interface
set -u
LEAN_FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEAN_FX_REPO="$(cd "$LEAN_FX_DIR/../.." && pwd -P)"
# shellcheck source=../../test/use-cases/lib.sh
. "$LEAN_FX_REPO/test/use-cases/lib.sh"

lean_fx_hash() { shasum -a 256 | cut -c1-64; }

# lean_fx_norm -- stdin to stdout with the volatile identifiers replaced by tokens: the sandbox HOME (as given and as realpath'd), the version, the commit.
lean_fx_norm() {
  local home_real
  home_real="$(cd "$UC_HOME" && pwd -P)"
  sed -e "s|$home_real|<HOME>|g" -e "s|$UC_HOME|<HOME>|g" \
      -e "s|$(printf '%s' "$UC_VERSION" | sed 's/\./\\./g')|<VERSION>|g" -e "s|$UC_SHA|<SHA>|g"
}

# lean_fx_json_lines FILE FILTER -- the normalized, filtered ndjson/json of FILE as sorted compact lines ("-" for a missing file: absence is a component).
lean_fx_json_lines() {
  if [ -f "$1" ]; then jq -c "$2" "$1" 2>/dev/null | lean_fx_norm | LC_ALL=C sort; else echo '-'; fi
}

# lean_fx_components -- JSON of the normalized components for the current UC_HOME. The installer's decisions, not its clocks.
lean_fx_components() {
  local h="$UC_HOME" inst="$UC_HOME/.heimdall" state="$UC_HOME/.heimdall/.heimdall"
  local tree_clone tree_src dirty paths d_zshrc d_settings d_links d_lock d_tel d_funnel d_receipts d_team d_cc d_doctor
  tree_clone="$(git -C "$inst" rev-parse 'HEAD^{tree}' 2>/dev/null || echo none)"
  tree_src="$(git -C "$UC_TREE" rev-parse 'HEAD^{tree}' 2>/dev/null || echo none2)"
  dirty="$(git -C "$inst" status --porcelain 2>/dev/null | LC_ALL=C sort | jq -R . | jq -sc .)"
  # everything outside the clone's own tracked files and .git: the files the installer ADDED to the machine (names normalized where the name is volatile)
  git -C "$inst" ls-files | LC_ALL=C sort | sed 's|^|./.heimdall/|' > "$UC_ROOT/fx-tracked.txt"
  paths="$(cd "$h" && find . -path ./.heimdall/.git -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort \
            | grep -vxFf "$UC_ROOT/fx-tracked.txt" \
            | sed -e 's|installs-run-[0-9a-f]*\.ndjson|installs-run-RUN.ndjson|' -e 's|haid_unknown\.[^/]*\.doctor-diagnosis|haid_unknown.HOST.doctor-diagnosis|' \
            | jq -R . | jq -sc .)"
  d_zshrc="$(lean_fx_norm < "$h/.zshrc" | lean_fx_hash)"
  d_settings="$(lean_fx_norm < "$h/.claude/settings.json" | lean_fx_hash)"
  d_links="$( { for n in hmd heimdall; do printf '%s -> %s\n' "$n" "$(readlink "$h/.local/bin/$n")"; done; } | lean_fx_norm | lean_fx_hash)"
  d_lock="$(lean_fx_json_lines "$state/skills.lock" '.entries[] | {id,kind,ref,state,version,source,pin,content_hash,consent,via:.why.via,rule:.why.rule}' | lean_fx_hash)"
  d_tel="$(lean_fx_json_lines "$state/telemetry/events.ndjson" '[.event_type,.phase,.step,.outcome]' | lean_fx_hash)"
  d_funnel="$(lean_fx_json_lines "$state/telemetry/funnel/events.ndjson" '[.schema,.event,.context,.env.os_class,.env.hmd_version]' | lean_fx_hash)"
  d_receipts="$(cat "$inst"/receipts/installs-run-*.ndjson 2>/dev/null | jq -c '{kind,name,version,source,pin,result,via}' | lean_fx_norm | LC_ALL=C sort | lean_fx_hash)"
  d_team="$(lean_fx_json_lines "$inst/team.json" '[(keys|sort), .source]' | lean_fx_hash)"
  d_cc="$(lean_fx_json_lines "$state/cc-verify.json" '[(keys|sort), .rc]' | lean_fx_hash)"
  d_doctor="$(cat "$inst"/pki/haid_unknown.*.doctor-diagnosis 2>/dev/null | jq -c '{state,reason,detail}' | lean_fx_norm | lean_fx_hash)"
  jq -n --arg tc "$tree_clone" --arg ts "$tree_src" --argjson dirty "$dirty" --argjson paths "$paths" \
        --arg zshrc "$d_zshrc" --arg settings "$d_settings" --arg links "$d_links" --arg lock "$d_lock" --arg tel "$d_tel" \
        --arg funnel "$d_funnel" --arg receipts "$d_receipts" --arg team "$d_team" --arg cc "$d_cc" --arg doctor "$d_doctor" \
        --argjson irc "$LEAN_FX_INSTALL_RC" --argjson urc "$LEAN_FX_UPGRADE_RC" '
    { install_exit: $irc, upgrade_exit: $urc,
      clone_tree_equals_source: ($tc == $ts),
      clone_tracked_modified_by_install: $dirty,
      added_files: $paths,
      digests: { zshrc: $zshrc, claude_settings: $settings, bin_links: $links, skills_lock: $lock, telemetry: $tel,
                 funnel: $funnel, install_receipts: $receipts, team: $team, cc_verify: $cc, doctor_diagnosis: $doctor } }'
}

# lean_fx_run -- build the fixture existing install, run the no-flag upgrade, set LEAN_FX_JSON (components + state_sha256). Leaves the sandbox in UC_HOME.
lean_fx_run() {
  uc_begin lean_install_fixture
  uc_need_node
  uc_need_crypto
  uc_tree
  uc_fakebin
  uc_sandbox fixture
  printf '# my zshrc\nexport EDITOR=vim\n' > "$UC_HOME/.zshrc"
  mkdir -p "$UC_HOME/.claude"
  printf '{"theme":"dark"}\n' > "$UC_HOME/.claude/settings.json"
  uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh
  LEAN_FX_INSTALL_RC=$UC_RC
  uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh      # the no-flag upgrade: the script again, no argument
  LEAN_FX_UPGRADE_RC=$UC_RC
  LEAN_FX_JSON="$(lean_fx_seal "$(lean_fx_components)")"
}

# lean_fx_seal -- state_sha256 = sha256 of the canonical digests object (one value to compare, the digests say which part moved).
lean_fx_seal() {
  local sha
  sha="$(printf '%s' "$1" | jq -cS '.' | lean_fx_hash)"
  printf '%s' "$1" | jq -S --arg s "$sha" '.state_sha256 = $s'
}

case "${1:-}" in
  digest|record)
    lean_fx_run
    doc="$LEAN_FX_JSON"
    if [ "$1" = record ]; then
      head_sha="$(git -C "$LEAN_FX_REPO" rev-parse HEAD)"
      doc="$(printf '%s' "$doc" | jq -S --arg sh "$(shasum -a 256 "$UC_TREE/install.sh" | cut -c1-64)" --arg hs "$head_sha" \
        '{schema: 1, recorded_from: {install_sh_sha256: $sh, repo_head: $hs, note: "recorded from the UNMODIFIED install.sh: a no-flag upgrade over an existing install in the offline use-case sandbox"}, components: .}')"
    fi
    printf '%s\n' "$doc"
    ;;
esac
