#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2015,SC2016,SC2030,SC2031,SC2059  # the readers are sourced by a computed path; ok never fails, so `check && ok || bad` is if-then-else; single quotes hold the literal $ of jq programs and mutation texts; the reader helpers run in a subshell on purpose; printf formats are this test's own literals
#
# heimdall-guardrails-cli.test.sh -- bin/heimdall-guardrails, the write side of the guardrail tiers: `hmd guardrails list [--json] | why ID | off ID | on ID`
# (3.x M1, task T3.6 of docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md).
#
# guardrails.manifest.json puts every guardrail in a tier. `off` of a CORE id exits 2 and writes nothing (INV-G1); a RECOMMENDED hook row is switched by
# `heimdall-hooks disable` (hooks-disabled), a RECOMMENDED guard living inside a hook by a line of $HEIMDALL_HOME/guardrails-off, the file bin/lib/hmd_guardrail_enabled.sh reads.
#
#   A. the real manifest, found through the tool's own location (no seam): list, list --json, why, usage, and that the read-only commands create nothing
#   B. INV-G1 over EVERY core id of the manifest: `off` exits 2 and nothing is written (no file, no directory); `on` of a core id is a no-op; a core id typed into either
#      switch file stays "always on"; and the READERS agree (INV-G3): switching every recommended guard off flips exactly those, never a core one
#   C. guard rows -> guardrails-off: the `off` / `on` round trip, idempotence (a second call writes nothing), every other line kept byte for byte, the reader's whole-line rule,
#      HEIMDALL_HOME empty -> HOME, a relative HEIMDALL_HOME refused (the reader would never read it), a file that cannot be read is not overwritten; and what the security review of
#      T3.6 asked for: a guardrails-off that is a link is refused (the file it points at is not written), HEIMDALL_HOME must be a real directory of ours that others cannot write to
#      (a link, a group- or world-writable directory, another account's directory: exit 1, nothing written), and with neither HEIMDALL_HOME nor HOME there is no /tmp fallback
#   D. hook rows -> heimdall-hooks: `off stop-lint` lands in hooks-disabled, never in guardrails-off, and hmd_hook_enabled agrees
#   E. refusals: an unknown id; a manifest or hooks metadata that is missing, relative, not JSON, repeats a key or an id, or has a tier it does not know; a recommended hook row whose
#      hook the metadata locks or does not list is core; where the manifest comes from (override > CLAUDE_PLUGIN_ROOT > the tool's own checkout)
#   F. falsifiability: each defect (twenty-two, injected ALONE into a copy of the tool or of its link-safe helper) turns the check that owns it red; an unmodified copy passes
#
# Hermetic: a throwaway HEIMDALL_HOME and HOME per check; the operator's real ~/.heimdall is never read or written. The tool runs under the resolved interpreter, not the
# `python3` of PATH (a version-manager shim costs ~0.4 s a call and this suite starts the tool ~150 times); one call goes through the shebang to prove it works.
# Runs in about 7 s solo.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO/bin/heimdall-guardrails"
MANIFEST="$REPO/guardrails.manifest.json"
HOOKS_META="$REPO/hooks/hooks.metadata.json"
READER_G="$REPO/bin/lib/hmd_guardrail_enabled.sh"
READER_H="$REPO/bin/lib/hook-enabled.sh"
PASS=0
FAIL=0
ok()      { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()     { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
section() { printf '\n%s\n' "$1"; }
finish()  { printf '\n  guardrails-cli: %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 2; }
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
PY="$("$PY" -c 'import sys; print(sys.executable)')" && [ -n "$PY" ] || { echo "FATAL: cannot resolve python3"; exit 2; }
[ -f "$CLI" ] || { bad "bin/heimdall-guardrails does not exist"; finish; exit 1; }

WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK"' EXIT

# ---- fixtures ---------------------------------------------------------------------------------------------------------------------------------------------------
# a small VALID manifest and hooks metadata: a recommended hook (opt-hook), a hook the metadata locks although the manifest says recommended (drift-hook), one it does not list
# (ghost-hook), a core hook, and a recommended and a core guard inside the core hook
FIX_M="$WORK/fix-manifest.json"
FIX_H="$WORK/fix-hooks.json"
cat > "$FIX_M" <<'EOF'
{"schema": 1, "guardrails": [
  {"id": "opt-hook", "kind": "guard", "tier": "recommended", "layer": "hook", "hook": "opt-hook", "fails": "open", "proof": "test/x.test.sh", "why": "an advisory hook"},
  {"id": "drift-hook", "kind": "guard", "tier": "recommended", "layer": "hook", "hook": "drift-hook", "fails": "open", "proof": "test/x.test.sh", "why": "recommended here, locked in the metadata"},
  {"id": "ghost-hook", "kind": "guard", "tier": "recommended", "layer": "hook", "hook": "ghost-hook", "fails": "open", "proof": "test/x.test.sh", "why": "recommended here, absent from the metadata"},
  {"id": "core-hook", "kind": "guard", "tier": "core", "layer": "hook", "hook": "core-hook", "fails": "closed", "proof": "test/x.test.sh", "why": "a locked hook"},
  {"id": "opt-guard", "kind": "guard", "tier": "recommended", "layer": "precheck-bash", "hook": "core-hook", "fails": "open", "proof": "test/x.test.sh", "why": "a guard inside a locked hook"},
  {"id": "core-guard", "kind": "guard", "tier": "core", "layer": "precheck-bash", "hook": "core-hook", "fails": "closed", "proof": "test/x.test.sh", "why": "a core guard inside a locked hook"}
]}
EOF
printf '%s\n' '{"hooks": [{"id": "opt-hook", "locked": false}, {"id": "drift-hook", "locked": true}, {"id": "core-hook", "locked": true}]}' > "$FIX_H"
# manifests and metadata the tool must refuse to trust
BAD_TIER="$WORK/bad-tier.json"; jq '.guardrails += [{"id": "odd-tier", "kind": "guard", "tier": "optional", "layer": "x", "proof": "p", "why": "w"}]' "$FIX_M" > "$BAD_TIER"
BAD_DUP="$WORK/bad-dup.json";   jq '.guardrails += [.guardrails[4]]' "$FIX_M" > "$BAD_DUP"
BAD_KEY="$WORK/bad-key.json";   printf '%s' '{"schema": 1, "schema": 1, "guardrails": [{"id": "opt-guard", "kind": "guard", "tier": "recommended", "layer": "x", "proof": "p", "why": "w"}]}' > "$BAD_KEY"
BAD_JSON="$WORK/bad-json.json"; printf '%s' 'garbage{' > "$BAD_JSON"
BAD_HOOKS="$WORK/bad-hooks.json"; printf '%s' '{"hooks": []}' > "$BAD_HOOKS"
PLUG="$WORK/plug"; mkdir -p "$PLUG/hooks"; cp "$FIX_M" "$PLUG/guardrails.manifest.json"; cp "$FIX_H" "$PLUG/hooks/hooks.metadata.json"   # a plugin root

# ---- harness ----------------------------------------------------------------------------------------------------------------------------------------------------
CLI_UNDER_TEST="$CLI"
CLI_ENV=()
USERHOME="$WORK/userhome"   # the HOME the tool runs with (a directory that does not exist); unset it to run the tool with no HOME at all
H=""
N=0
RC=0
OUT=""
ERR=""
REASON=""
fresh()       { N=$((N + 1)); H="$WORK/home$N"; }   # a HEIMDALL_HOME that does not exist yet: "nothing written" is then "it still does not exist"
mkhome()      { mkdir -p "$1" && chmod 700 "$1"; }   # a HEIMDALL_HOME a check makes itself: private whatever the umask (the tool refuses one others can write to)
use_real()    { CLI_ENV=(HMD_GUARDRAILS_MANIFEST="$MANIFEST" HMD_HOOKS_METADATA="$HOOKS_META"); }
use_fixture() { CLI_ENV=(HMD_GUARDRAILS_MANIFEST="$FIX_M" HMD_HOOKS_METADATA="$FIX_H"); }

# cli ARGS... -- run the tool in a clean environment (HEIMDALL_HOME=$H and HOME=$USERHOME while those are set, none of the plugin-root or seam variables except those of $CLI_ENV);
# leaves RC, OUT and ERR
cli() {
  local envv=()
  if [ "${USERHOME+set}" = set ]; then envv+=(HOME="$USERHOME"); fi
  if [ "${H+set}" = set ]; then envv+=(HEIMDALL_HOME="$H"); fi
  env -u CLAUDE_PLUGIN_ROOT -u HMD_GUARDRAILS_MANIFEST -u HMD_HOOKS_METADATA -u HEIMDALL_HOME -u HOME \
    ${envv[@]+"${envv[@]}"} ${CLI_ENV[@]+"${CLI_ENV[@]}"} \
    "$PY" "$CLI_UNDER_TEST" "$@" < /dev/null > "$WORK/out" 2> "$WORK/err"
  RC=$?
  OUT="$(cat "$WORK/out")"
  ERR="$(cat "$WORK/err")"
}
# same FILE FORMAT -- FILE holds exactly the bytes printf FORMAT writes
same() { printf "$2" | cmp -s - "$1"; }
# sig DIR -- a fingerprint of everything under DIR (names, links, checksums), or "absent"
sig() {
  if [ ! -e "$1" ]; then echo absent; return 0; fi
  ( cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
      if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"
      elif [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum 2>/dev/null < "$f")"
      else printf '%s\n' "$f"; fi
    done )
}
# files DIR -- how many entries DIR holds (a temp file left behind counts)
files() { find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }
# mf ID FIELD -- a field of the real manifest's row
mf() { jq -r --arg id "$1" --arg f "$2" '.guardrails[] | select(.id == $id) | .[$f] // empty' "$MANIFEST"; }
# reader_g ID / reader_h ID -- what the guard's reader (hmd_guardrail_enabled) and the hook's reader (hmd_hook_enabled) answer for ID with HEIMDALL_HOME=$H: 0 enabled, 1 switched off
reader_g() { ( unset CLAUDE_PLUGIN_ROOT HMD_GUARDRAILS_MANIFEST; export HEIMDALL_HOME="$H" HOME="$WORK/userhome"; . "$READER_G" 2>/dev/null; hmd_guardrail_enabled "$1"; printf '%s' "$?" ); }
reader_h() { ( unset CLAUDE_PLUGIN_ROOT HMD_HOOKS_METADATA; export HEIMDALL_HOME="$H" HOME="$WORK/userhome"; . "$READER_H" 2>/dev/null; hmd_hook_enabled "$1"; printf '%s' "$?" ); }
core_ids()        { jq -r '.guardrails[] | select(.tier == "core") | .id' "$MANIFEST"; }
rec_guard_ids()   { jq -r '.guardrails[] | select(.tier == "recommended" and .layer != "hook") | .id' "$MANIFEST"; }
core_guard_ids()  { jq -r '.guardrails[] | select(.tier == "core" and .layer != "hook") | .id' "$MANIFEST"; }

# ---- the checks: each returns 0 when the behaviour holds, else 1 with REASON saying what was seen (B-E run them on the tool; F runs the owner of each defect on a damaged copy) -
chk_core_refused() {   # $1 = a core id: `off` exits 2, says REFUSED, and writes nothing -- not even the directory
  use_real; fresh
  cli off "$1"
  [ "$RC" = 2 ] || { REASON="off $1 exited $RC, want 2 (stderr: $ERR)"; return 1; }
  case "$ERR" in *REFUSED*) ;; *) REASON="off $1 did not say REFUSED: $ERR"; return 1 ;; esac
  [ ! -e "$H" ] || { REASON="off $1 left $(sig "$H")"; return 1; }
  return 0
}
chk_core_files_unchanged() {   # $1 = a core id, with both switch files already there
  use_real; fresh; mkhome "$H"
  printf 'ci-waste-guard\n' > "$H/guardrails-off"; printf 'ctx-meter-notice\n' > "$H/hooks-disabled"
  local before; before="$(sig "$H")"
  cli off "$1"
  [ "$RC" = 2 ] || { REASON="off $1 exited $RC, want 2 (stderr: $ERR)"; return 1; }
  [ "$(sig "$H")" = "$before" ] || { REASON="off $1 changed the switch files: $(sig "$H")"; return 1; }
  return 0
}
chk_on_core_noop() {   # `on` of a core id: always on, exit 0, nothing written
  use_real; fresh
  local id
  for id in stub-gate push-secret-scan agent-concurrency-cap; do
    cli on "$id"
    [ "$RC" = 0 ] || { REASON="on $id exited $RC, want 0 (stderr: $ERR)"; return 1; }
    [ ! -e "$H" ] || { REASON="on $id left $(sig "$H")"; return 1; }
  done
  return 0
}
chk_core_listed_stays_on() {   # core ids typed into either file by hand stay "always on" in the list, and the list says the lines switch nothing
  use_real; fresh; mkhome "$H"
  printf 'push-secret-scan\nstub-gate\nghost-id\n' > "$H/guardrails-off"
  printf 'stub-gate\nsecret-read-guard\n' > "$H/hooks-disabled"
  cli list --json
  [ "$RC" = 0 ] || { REASON="list exited $RC: $ERR"; return 1; }
  local off; off="$(printf '%s' "$OUT" | jq -r '[.[] | select(.state == "off") | .id] | join(" ")')"
  [ -z "$off" ] || { REASON="list shows [$off] off though they are core"; return 1; }
  case "$ERR" in *"switch nothing"*) ;; *) REASON="list did not say which lines switch nothing: [$ERR]"; return 1 ;; esac
  return 0
}
chk_off_sub() {   # a guard inside a hook: one line in guardrails-off, hooks-disabled untouched, no temp file left behind
  use_real; fresh
  cli off ci-waste-guard
  [ "$RC" = 0 ] || { REASON="off ci-waste-guard exited $RC: $ERR"; return 1; }
  same "$H/guardrails-off" 'ci-waste-guard\n' || { REASON="guardrails-off holds [$(cat "$H/guardrails-off" 2>&1)]"; return 1; }
  [ ! -e "$H/hooks-disabled" ] || { REASON="off wrote hooks-disabled"; return 1; }
  [ "$(files "$H")" = 1 ] || { REASON="entries left in $H: $(find "$H" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"; return 1; }
  return 0
}
chk_on_sub() {   # `on` removes every exact line of the id and keeps the rest byte for byte; a second `on` writes nothing
  use_real; fresh; mkhome "$H"
  printf '# note\nghost-id\n\nci-waste-guard\nci-waste-guard\ndisk-floor' > "$H/guardrails-off"
  cli on ci-waste-guard
  [ "$RC" = 0 ] || { REASON="on ci-waste-guard exited $RC: $ERR"; return 1; }
  same "$H/guardrails-off" '# note\nghost-id\n\ndisk-floor' || { REASON="guardrails-off holds [$(cat "$H/guardrails-off" 2>&1)]"; return 1; }
  [ "$(files "$H")" = 1 ] || { REASON="entries left in $H: $(find "$H" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"; return 1; }
  local before; before="$(sig "$H")"
  cli on ci-waste-guard
  [ "$RC" = 0 ] && [ "$(sig "$H")" = "$before" ] || { REASON="a second on exited $RC or rewrote the file"; return 1; }
  return 0
}
chk_off_appends() {   # `off` appends on its own line even after a last line without a newline; a second `off` writes nothing
  use_real; fresh; mkhome "$H"
  printf 'disk-floor' > "$H/guardrails-off"
  cli off wait-guard
  [ "$RC" = 0 ] || { REASON="off wait-guard exited $RC: $ERR"; return 1; }
  same "$H/guardrails-off" 'disk-floor\nwait-guard\n' || { REASON="guardrails-off holds [$(cat "$H/guardrails-off" 2>&1)]"; return 1; }
  local before; before="$(sig "$H")"
  cli off wait-guard
  [ "$RC" = 0 ] && [ "$(sig "$H")" = "$before" ] || { REASON="a second off exited $RC or rewrote the file"; return 1; }
  return 0
}
chk_near_misses() {   # the reader's rule is a WHOLE line: padding, case and a trailing CR do not match, so `off` still adds the id and `on` removes only the exact line
  use_real; fresh; mkhome "$H"
  printf 'ci-waste-guard \n ci-waste-guard\nCI-WASTE-GUARD\nci-waste-guard\r\n' > "$H/guardrails-off"
  cp "$H/guardrails-off" "$WORK/near$N"
  cli off ci-waste-guard
  [ "$RC" = 0 ] || { REASON="off exited $RC: $ERR"; return 1; }
  { cat "$WORK/near$N"; printf 'ci-waste-guard\n'; } | cmp -s - "$H/guardrails-off" || { REASON="off beside near misses: [$(cat "$H/guardrails-off")]"; return 1; }
  cli on ci-waste-guard
  cmp -s "$WORK/near$N" "$H/guardrails-off" || { REASON="on beside near misses: [$(cat "$H/guardrails-off")]"; return 1; }
  return 0
}
chk_unknown() {   # an id the manifest does not have: exit 1 for every verb, nothing written
  use_real; fresh
  local verb
  for verb in off on why; do
    cli "$verb" no-such-guard
    [ "$RC" = 1 ] || { REASON="$verb no-such-guard exited $RC, want 1 (stderr: $ERR)"; return 1; }
  done
  cli off 'ci-waste-guard
x'
  [ "$RC" = 1 ] || { REASON="off with a newline in the id exited $RC, want 1"; return 1; }
  cli off ''
  [ "$RC" = 1 ] || { REASON="off with an empty id exited $RC, want 1"; return 1; }
  [ ! -e "$H" ] || { REASON="an unknown id left $(sig "$H")"; return 1; }
  return 0
}
chk_off_hook() {   # a hook row goes through heimdall-hooks: hooks-disabled, never guardrails-off
  use_real; fresh
  cli off stop-lint
  [ "$RC" = 0 ] || { REASON="off stop-lint exited $RC: $ERR"; return 1; }
  same "$H/hooks-disabled" 'stop-lint\n' || { REASON="hooks-disabled holds [$(cat "$H/hooks-disabled" 2>&1)]"; return 1; }
  [ ! -e "$H/guardrails-off" ] || { REASON="off stop-lint wrote guardrails-off"; return 1; }
  cli on stop-lint
  [ "$RC" = 0 ] && [ ! -s "$H/hooks-disabled" ] || { REASON="on stop-lint exited $RC, hooks-disabled holds [$(cat "$H/hooks-disabled" 2>&1)]"; return 1; }
  return 0
}
chk_list_states() {   # the list shows what each switch file says, in the table and in the JSON; core rows never leave "always on"
  use_real; fresh
  cli off ci-waste-guard; [ "$RC" = 0 ] || { REASON="off ci-waste-guard exited $RC"; return 1; }
  cli off stop-lint;      [ "$RC" = 0 ] || { REASON="off stop-lint exited $RC"; return 1; }
  cli list --json
  [ "$RC" = 0 ] || { REASON="list --json exited $RC: $ERR"; return 1; }
  local off; off="$(printf '%s' "$OUT" | jq -r '[.[] | select(.state == "off") | .id] | sort | join(" ")')"
  [ "$off" = "ci-waste-guard stop-lint" ] || { REASON="rows off in the JSON: [$off]"; return 1; }
  local wrong; wrong="$(printf '%s' "$OUT" | jq -r '[.[] | select((.tier == "core") != (.state == "always on")) | .id] | join(" ")')"
  [ -z "$wrong" ] || { REASON="core and always-on disagree for: $wrong"; return 1; }
  cli list
  printf '%s\n' "$OUT" | grep -Eq '^ci-waste-guard +recommended +guard +off +precheck-bash$' || { REASON="table row of ci-waste-guard: $(printf '%s\n' "$OUT" | grep '^ci-waste-guard ')"; return 1; }
  printf '%s\n' "$OUT" | grep -Eq '^stop-lint +recommended +guard +off +hook$' || { REASON="table row of stop-lint: $(printf '%s\n' "$OUT" | grep '^stop-lint ')"; return 1; }
  return 0
}
chk_why() {   # tier, rationale, fail mode, operator override and proof suite, as the manifest says them
  use_real; fresh
  local id label value tier
  for id in ci-waste-guard push-secret-scan ctx-meter-notice agent-concurrency-cap; do
    cli why "$id"
    [ "$RC" = 0 ] || { REASON="why $id exited $RC: $ERR"; return 1; }
    printf '%s\n' "$OUT" | grep -Fxq -- "$id" || { REASON="why $id does not start with the id: $OUT"; return 1; }
    tier="$(mf "$id" tier)"
    printf '%s\n' "$OUT" | grep -Eq -- "^  tier +$tier" || { REASON="why $id has no tier $tier: $OUT"; return 1; }
    for label in why fails operator_env proof; do
      value="$(mf "$id" "$label")"
      if [ -z "$value" ]; then
        case "$label" in fails) value='n/a' ;; *) value='none' ;; esac
      fi
      printf '%s\n' "$OUT" | grep -Fxq -- "$(printf '  %-13s %s' "$(printf '%s' "$label" | tr _ ' ')" "$value")" || { REASON="why $id has no line '$label  $value': $OUT"; return 1; }
    done
  done
  cli why agent-concurrency-cap
  printf '%s\n' "$OUT" | grep -Eq '^  provisional ' || { REASON="why agent-concurrency-cap (provisional in the manifest) does not say so: $OUT"; return 1; }
  return 0
}
chk_relative_home() {   # a relative HEIMDALL_HOME is the cwd, which the reader never reads: `off` and `on` refuse it, write nothing, and `list` says so
  use_real; fresh
  local here="$PWD" rc_off rc_on rc_list err_list left
  mkdir -p "$WORK/rel$N"; cd "$WORK/rel$N" || return 1
  H="rel/home"
  cli off ci-waste-guard; rc_off=$RC
  cli on ci-waste-guard;  rc_on=$RC
  cli list;               rc_list=$RC; err_list="$ERR"
  left="$(find . | LC_ALL=C sort | tr '\n' ' ')"
  cd "$here" || return 1
  [ "$rc_off" = 1 ] || { REASON="off with a relative HEIMDALL_HOME exited $rc_off, want 1"; return 1; }
  [ "$rc_on" = 1 ] || { REASON="on with a relative HEIMDALL_HOME exited $rc_on, want 1"; return 1; }
  [ "$left" = ". " ] || { REASON="a relative HEIMDALL_HOME left [$left] in the cwd"; return 1; }
  [ "$rc_list" = 0 ] || { REASON="list with a relative HEIMDALL_HOME exited $rc_list"; return 1; }
  case "$err_list" in *"not absolute"*) ;; *) REASON="list did not say the home is not absolute: [$err_list]"; return 1 ;; esac
  return 0
}
chk_symlink() {   # a guardrails-off that is a link is refused by off and on (also a dangling one): the file it points at is not written, the link is not replaced
  use_real; fresh; mkhome "$H"; mkdir -p "$WORK/dot$N"
  printf 'disk-floor\n' > "$WORK/dot$N/target"
  ln -s "$WORK/dot$N/target" "$H/guardrails-off"
  local before verb; before="$(sig "$WORK/dot$N")|$(sig "$H")"
  for verb in off on; do
    cli "$verb" ci-waste-guard
    [ "$RC" = 1 ] || { REASON="$verb through a link exited $RC, want 1 (stderr: $ERR)"; return 1; }
  done
  [ "$(sig "$WORK/dot$N")|$(sig "$H")" = "$before" ] || { REASON="a link was followed or replaced: $(sig "$WORK/dot$N") | $(sig "$H")"; return 1; }
  rm -f "$WORK/dot$N/target"
  cli off ci-waste-guard
  [ "$RC" = 1 ] && [ ! -e "$WORK/dot$N/target" ] || { REASON="off through a dangling link exited $RC, or created the file it points at"; return 1; }
  return 0
}
chk_home_vet() {   # HEIMDALL_HOME must be a real directory of ours that others cannot write to: a link (also a dangling one), a group- or world-writable directory, another account's: exit 1, nothing written
  use_real; fresh
  local mode verb
  mkhome "$WORK/real$N"; ln -s "$WORK/real$N" "$H"
  cli off ci-waste-guard
  [ "$RC" = 1 ] || { REASON="off with HEIMDALL_HOME a link exited $RC, want 1 (stderr: $ERR)"; return 1; }
  [ "$(files "$WORK/real$N")" = 0 ] || { REASON="a switch was written through the HEIMDALL_HOME link: $(sig "$WORK/real$N")"; return 1; }
  fresh; ln -s "$WORK/nowhere$N" "$H"
  cli off ci-waste-guard
  [ "$RC" = 1 ] && [ ! -e "$WORK/nowhere$N" ] || { REASON="off with HEIMDALL_HOME a dangling link exited $RC, or created the directory it points at"; return 1; }
  for mode in 775 757; do
    fresh; mkdir -p "$H"; chmod "$mode" "$H"
    for verb in off on; do
      cli "$verb" ci-waste-guard
      [ "$RC" = 1 ] || { REASON="$verb with HEIMDALL_HOME of mode $mode exited $RC, want 1 (stderr: $ERR)"; return 1; }
      case "$ERR" in *"written by its group or by others"*) ;; *) REASON="$verb with HEIMDALL_HOME of mode $mode: no word on who can write there: [$ERR]"; return 1 ;; esac
    done
    [ ! -e "$H/guardrails-off" ] || { REASON="a switch was written into a directory of mode $mode"; return 1; }
  done
  if [ "$(id -u)" != 0 ] && [ -n "$(find /usr -maxdepth 0 -not -user "$(id -un)")" ]; then
    H=/usr
    cli off ci-waste-guard
    [ "$RC" = 1 ] || { REASON="off with HEIMDALL_HOME=/usr (another account's) exited $RC, want 1"; return 1; }
    case "$ERR" in *"not to you"*) ;; *) REASON="off with HEIMDALL_HOME=/usr: no word on whose it is: [$ERR]"; return 1 ;; esac
  fi
  fresh; mkhome "$H"
  cli off ci-waste-guard
  [ "$RC" = 0 ] || { REASON="off into a private directory of ours exited $RC: $ERR"; return 1; }
  chmod 755 "$H"
  cli off wait-guard
  [ "$RC" = 0 ] || { REASON="off into a directory of ours of mode 755 exited $RC: $ERR"; return 1; }
  return 0
}
chk_no_home() {   # neither HEIMDALL_HOME nor HOME: no /tmp fallback for a write (a guard row, a hook row whose delegate would fall back itself, on); list says so
  use_real; CLI_ENV+=(MUT_FALLBACK="$WORK/fallback"); fresh
  local tmp_g=no tmp_h=no rc_guard rc_hook rc_on rc_list err_guard err_list
  if [ -e /tmp/.heimdall/guardrails-off ]; then tmp_g=yes; fi
  if [ -e /tmp/.heimdall/hooks-disabled ]; then tmp_h=yes; fi
  unset H USERHOME
  cli off ci-waste-guard; rc_guard=$RC; err_guard="$ERR"
  cli off stop-lint;      rc_hook=$RC
  cli on ci-waste-guard;  rc_on=$RC
  cli list;               rc_list=$RC; err_list="$ERR"
  USERHOME="$WORK/userhome"; fresh
  if [ "$tmp_g" = no ] && [ -e /tmp/.heimdall/guardrails-off ]; then rm -f /tmp/.heimdall/guardrails-off; REASON="off with no home wrote /tmp/.heimdall/guardrails-off"; return 1; fi
  if [ "$tmp_h" = no ] && [ -e /tmp/.heimdall/hooks-disabled ]; then rm -f /tmp/.heimdall/hooks-disabled; REASON="off of a hook row with no home wrote /tmp/.heimdall/hooks-disabled"; return 1; fi
  [ "$rc_guard" = 1 ] || { REASON="off with no home exited $rc_guard, want 1"; return 1; }
  case "$err_guard" in *"neither HEIMDALL_HOME nor HOME"*) ;; *) REASON="off with no home did not say so: [$err_guard]"; return 1 ;; esac
  [ "$rc_hook" = 1 ] || { REASON="off of a hook row with no home exited $rc_hook, want 1"; return 1; }
  [ "$rc_on" = 1 ] || { REASON="on with no home exited $rc_on, want 1"; return 1; }
  [ ! -e "$WORK/fallback" ] || { REASON="a switch was written under a fallback home"; return 1; }
  [ "$rc_list" = 0 ] || { REASON="list with no home exited $rc_list"; return 1; }
  case "$err_list" in *"neither HEIMDALL_HOME nor HOME"*) ;; *) REASON="list with no home did not say so: [$err_list]"; return 1 ;; esac
  return 0
}
chk_fixture_delegation() {   # a hook row is switched against the metadata it was classified with, and a guard row beside it still goes to guardrails-off
  use_fixture; fresh
  cli off opt-hook
  [ "$RC" = 0 ] || { REASON="off opt-hook exited $RC: $ERR"; return 1; }
  same "$H/hooks-disabled" 'opt-hook\n' || { REASON="hooks-disabled holds [$(cat "$H/hooks-disabled" 2>&1)]"; return 1; }
  cli on opt-hook
  [ "$RC" = 0 ] && [ ! -s "$H/hooks-disabled" ] || { REASON="on opt-hook exited $RC, hooks-disabled holds [$(cat "$H/hooks-disabled" 2>&1)]"; return 1; }
  cli off opt-guard
  [ "$RC" = 0 ] && same "$H/guardrails-off" 'opt-guard\n' || { REASON="off opt-guard exited $RC, guardrails-off holds [$(cat "$H/guardrails-off" 2>&1)]"; return 1; }
  return 0
}
chk_hook_drift() {   # a recommended hook row whose hook the metadata locks, or does not list, is core: refused, and "always on" in the list
  use_fixture; fresh
  local id
  for id in drift-hook ghost-hook core-hook core-guard; do
    cli off "$id"
    [ "$RC" = 2 ] || { REASON="off $id exited $RC, want 2 (stderr: $ERR)"; return 1; }
  done
  [ ! -e "$H" ] || { REASON="a refused off left $(sig "$H")"; return 1; }
  cli list --json
  local got; got="$(printf '%s' "$OUT" | jq -r '[.[] | "\(.id)=\(.state)"] | join(" ")')"
  [ "$got" = 'opt-hook=on drift-hook=always on ghost-hook=always on core-hook=always on opt-guard=on core-guard=always on' ] || { REASON="list says [$got]"; return 1; }
  return 0
}
chk_bad_inputs() {   # a manifest or metadata that cannot be trusted stops every command with exit 1, before anything is written
  fresh
  local spec
  for spec in "m:$BAD_TIER" "m:$BAD_DUP" "m:$BAD_KEY" "m:$BAD_JSON" "m:$WORK/none.json" "m:relative.json" "h:$BAD_HOOKS" "h:$WORK/none-hooks.json"; do
    case "${spec%%:*}" in
      m) CLI_ENV=(HMD_GUARDRAILS_MANIFEST="${spec#*:}" HMD_HOOKS_METADATA="$FIX_H") ;;
      *) CLI_ENV=(HMD_GUARDRAILS_MANIFEST="$FIX_M" HMD_HOOKS_METADATA="${spec#*:}") ;;
    esac
    fresh
    cli off opt-guard
    [ "$RC" = 1 ] || { REASON="off with ${spec#*:} exited $RC, want 1 (stderr: $ERR)"; return 1; }
    [ ! -e "$H" ] || { REASON="off with ${spec#*:} left $(sig "$H")"; return 1; }
  done
  CLI_ENV=(HMD_GUARDRAILS_MANIFEST="$BAD_TIER" HMD_HOOKS_METADATA="$FIX_H")
  cli list
  [ "$RC" = 1 ] || { REASON="list with a manifest of an unknown tier exited $RC, want 1"; return 1; }
  return 0
}

# ---- A. the real manifest, through the tool's own location ---------------------------------------------------------------------------------------------------------
section "A. the real manifest (no seam: the manifest and hooks metadata beside the tool)"
CLI_ENV=(); fresh
TOTAL="$(jq '.guardrails | length' "$MANIFEST")"
NCORE="$(jq '[.guardrails[] | select(.tier == "core")] | length' "$MANIFEST")"
cli list
if [ "$RC" = 0 ] && [ -z "$ERR" ] && [ "$(printf '%s\n' "$OUT" | sed -n 1p | tr -s ' ')" = 'ID TIER KIND STATE LAYER' ]; then ok "list: exit 0, nothing on stderr, a header row"; else bad "list: exit $RC" "stderr [$ERR], first line [$(printf '%s\n' "$OUT" | sed -n 1p)]"; fi
jq -r '.guardrails[].id' "$MANIFEST" > "$WORK/ids.txt"
SHOWN="$(printf '%s\n' "$OUT" | awk 'NR == FNR { ids[$1]; next } ($1 in ids) { n++ } END { print n + 0 }' "$WORK/ids.txt" -)"
if [ "$SHOWN" = "$TOTAL" ] && printf '%s\n' "$OUT" | grep -Fxq "$TOTAL guardrails: $NCORE core (always on), $((TOTAL - NCORE)) recommended (0 off)"; then ok "list: one row per manifest row ($TOTAL), $NCORE of them core, the summary line says so"; else bad "list: $SHOWN of $TOTAL rows shown" "$(printf '%s\n' "$OUT" | tail -2)"; fi
if printf '%s\n' "$OUT" | grep -Eq '^ci-waste-guard +recommended +guard +on +precheck-bash$' && printf '%s\n' "$OUT" | grep -Eq '^push-secret-scan +core +guard +always on +precheck-bash$'; then ok "list: a recommended guard is on, a core one is always on"; else bad "list: rows of ci-waste-guard and push-secret-scan" "$(printf '%s\n' "$OUT" | grep -E '^(ci-waste-guard|push-secret-scan) ')"; fi
cli list --json
JSON_OK="$(printf '%s' "$OUT" | jq --argjson total "$TOTAL" --argjson ncore "$NCORE" --slurpfile m "$MANIFEST" '
  (length == $total)
  and ([.[].id] == [$m[0].guardrails[].id])
  and ([.[] | select(.tier == "core")] | length == $ncore)
  and (all(.[]; (.tier == "core") == (.state == "always on") and (.switchable == (.tier == "recommended")) and (.enabled == (.state != "off"))))
  and (all(.[] | select(.tier == "recommended"); .state == "on"))' 2>&1)"
if [ "$RC" = 0 ] && [ "$JSON_OK" = true ]; then ok "list --json: valid JSON, the manifest's rows in its order, core always on and not switchable, recommended on"; else bad "list --json" "rc $RC: [$JSON_OK]"; fi
fresh
cli list; cli why ci-waste-guard; cli why stub-gate; cli list --json
if [ ! -e "$H" ]; then ok "the read-only commands create nothing (not even HEIMDALL_HOME)"; else bad "list/why created $H" "$(sig "$H")"; fi
use_real; chk_why && ok "why: tier, rationale, fail mode, operator override and proof suite are the manifest's (recommended guard, core guard, a feature row without them, a provisional row)" || bad "why" "$REASON"
chk_list_states && ok "list: the states follow guardrails-off and hooks-disabled, in the table and in the JSON" || bad "list states" "$REASON"
CLI_ENV=(); fresh; cli; RC_NONE=$RC; OUT_NONE="$OUT"
cli frobnicate; RC_BAD=$RC
if [ "$RC_NONE" = 0 ] && printf '%s\n' "$OUT_NONE" | grep -q 'usage: heimdall-guardrails' && [ "$RC_BAD" = 2 ]; then ok "usage: no command prints help (exit 0), an unknown command is a usage error (exit 2)"; else bad "usage" "no command: $RC_NONE, unknown command: $RC_BAD"; fi
SHEBANG_OUT="$(env -u CLAUDE_PLUGIN_ROOT -u HMD_GUARDRAILS_MANIFEST -u HMD_HOOKS_METADATA HEIMDALL_HOME="$WORK/shebang-home" "$CLI" list 2>&1)"; SHEBANG_RC=$?
if [ "$SHEBANG_RC" = 0 ] && [ -x "$CLI" ] && printf '%s\n' "$SHEBANG_OUT" | grep -q "^$TOTAL guardrails:"; then ok "the file is executable and runs through its own shebang"; else bad "run through the shebang" "rc $SHEBANG_RC: $(printf '%s\n' "$SHEBANG_OUT" | head -3)"; fi

# ---- B. INV-G1 over every core id; the readers agree ----------------------------------------------------------------------------------------------------------------
section "B. core guardrails are never switchable (INV-G1)"
FAILED=""; COUNT=0
while IFS= read -r id; do
  COUNT=$((COUNT + 1))
  chk_core_refused "$id" || FAILED="$FAILED [$id: $REASON]"
done < <(core_ids)
if [ -z "$FAILED" ] && [ "$COUNT" = "$NCORE" ] && [ "$COUNT" -ge 8 ]; then ok "off of EVERY one of the $COUNT core ids exits 2 with REFUSED, and nothing is written (HEIMDALL_HOME is not even created)"; else bad "off of a core id ($COUNT of $NCORE tried)" "$FAILED"; fi
FAILED=""
for id in stub-gate push-secret-scan agent-concurrency-cap; do chk_core_files_unchanged "$id" || FAILED="$FAILED [$id: $REASON]"; done
if [ -z "$FAILED" ]; then ok "beside existing guardrails-off and hooks-disabled, a refused off leaves both exactly as they were (a hook row, a guard row, a provisional row)"; else bad "refused off beside existing files" "$FAILED"; fi
chk_on_core_noop && ok "on of a core id: exit 0, always on, nothing written" || bad "on of a core id" "$REASON"
chk_core_listed_stays_on && ok "core ids typed into guardrails-off and hooks-disabled by hand stay always on in the list, which says those lines switch nothing" || bad "a core id typed into a switch file" "$REASON"
# the readers: the same files, read the way a guard and a hook read them
fresh; use_real
mkhome "$H"; printf 'push-secret-scan\nstub-gate\n' > "$H/guardrails-off"; printf 'stub-gate\nsecret-read-guard\n' > "$H/hooks-disabled"
if [ "$(reader_g push-secret-scan)" = 0 ] && [ "$(reader_h stub-gate)" = 0 ] && [ "$(reader_h secret-read-guard)" = 0 ]; then ok "the readers agree: a core id listed in either file is still enabled"; else bad "readers and a core id listed by hand" "guard reader: $(reader_g push-secret-scan), hook readers: $(reader_h stub-gate) $(reader_h secret-read-guard)"; fi
fresh; use_real
FAILED=""
while IFS= read -r id; do
  cli off "$id"; [ "$RC" = 0 ] || FAILED="$FAILED [off $id exited $RC]"
done < <(rec_guard_ids)
while IFS= read -r id; do [ "$(reader_g "$id")" = 1 ] || FAILED="$FAILED [reader still enables $id]"; done < <(rec_guard_ids)
while IFS= read -r id; do [ "$(reader_g "$id")" = 0 ] || FAILED="$FAILED [reader disabled core $id]"; done < <(core_guard_ids)
if [ -z "$FAILED" ] && [ "$(jq -Rn '[inputs] | length' "$H/guardrails-off")" = "$(rec_guard_ids | wc -l | tr -d ' ')" ]; then ok "every recommended guard switched off is read as off by hmd_guardrail_enabled, no core guard is (INV-G3), one line each"; else bad "writer and reader agree on the recommended guards" "$FAILED"; fi
FAILED=""
while IFS= read -r id; do cli on "$id"; [ "$RC" = 0 ] || FAILED="$FAILED [on $id exited $RC]"; done < <(rec_guard_ids)
while IFS= read -r id; do [ "$(reader_g "$id")" = 0 ] || FAILED="$FAILED [reader still disables $id]"; done < <(rec_guard_ids)
if [ -z "$FAILED" ] && [ ! -s "$H/guardrails-off" ]; then ok "and switching them all back on empties guardrails-off and the reader enables them again"; else bad "switching every recommended guard back on" "$FAILED"; fi

# ---- C. guard rows -> guardrails-off --------------------------------------------------------------------------------------------------------------------------------
section "C. a guard inside a hook is switched through \$HEIMDALL_HOME/guardrails-off"
chk_off_sub && ok "off ci-waste-guard: exactly one line in guardrails-off, hooks-disabled not touched, no temp file left behind" || bad "off ci-waste-guard" "$REASON"
fresh; use_real; cli off ci-waste-guard
if [ "$(reader_g ci-waste-guard)" = 1 ] && [ "$(reader_g disk-floor)" = 0 ] && [ "$(reader_g push-secret-scan)" = 0 ]; then ok "hmd_guardrail_enabled reads it: ci-waste-guard is off, its recommended neighbour and a core guard are not (INV-G3)"; else bad "the reader after off ci-waste-guard" "ci-waste-guard $(reader_g ci-waste-guard), disk-floor $(reader_g disk-floor), push-secret-scan $(reader_g push-secret-scan)"; fi
cli on ci-waste-guard
if [ "$RC" = 0 ] && [ "$(reader_g ci-waste-guard)" = 0 ] && [ ! -s "$H/guardrails-off" ]; then ok "on ci-waste-guard: the line is gone, the reader enables the guard again (the round trip)"; else bad "on ci-waste-guard" "rc $RC, reader $(reader_g ci-waste-guard)"; fi
chk_on_sub && ok "on removes every exact line of the id and keeps everything else byte for byte (comments, other ids, blank lines, a missing last newline); a second on writes nothing" || bad "on keeps the rest" "$REASON"
chk_off_appends && ok "off appends on its own line after a last line without a newline; a second off writes nothing" || bad "off appends" "$REASON"
chk_near_misses && ok "the reader's whole-line rule: padded, upper-case and CR-terminated lines are not the id, so off still adds it and on removes only the exact line" || bad "near misses" "$REASON"
rm -rf "$WORK/userhome"; mkdir -p "$WORK/userhome"; use_real; H=""   # an empty HEIMDALL_HOME is an unset one: HOME/.heimdall, like the readers
cli off ci-waste-guard
if [ "$RC" = 0 ] && same "$WORK/userhome/.heimdall/guardrails-off" 'ci-waste-guard\n'; then ok "HEIMDALL_HOME empty: the file is \$HOME/.heimdall/guardrails-off (the readers' fallback)"; else bad "the HOME fallback" "rc $RC, tree: $(sig "$WORK/userhome")"; fi
rm -rf "$WORK/userhome"
chk_relative_home && ok "a relative HEIMDALL_HOME: off and on exit 1 and write nothing (the reader would never read it), list says the home is not absolute" || bad "a relative HEIMDALL_HOME" "$REASON"
chk_symlink && ok "a guardrails-off that is a link (also a dangling one) is refused by off and on: the file it points at is not written, the link is not replaced" || bad "a guardrails-off that is a link" "$REASON"
chk_home_vet && ok "HEIMDALL_HOME must be a real directory of ours that others cannot write to (a link, also a dangling one; a group- or world-writable directory; another account's): exit 1, nothing written; 700 and 755 are fine" || bad "vetting HEIMDALL_HOME" "$REASON"
chk_no_home && ok "neither HEIMDALL_HOME nor HOME: no /tmp fallback for a guard row, a hook row or on; list says so" || bad "no HEIMDALL_HOME and no HOME" "$REASON"
if [ "$(id -u)" != 0 ]; then
  fresh; use_real; mkhome "$H"; printf 'disk-floor\n' > "$H/guardrails-off"; chmod 000 "$H/guardrails-off"
  BEFORE_UNREAD="$(sig "$H")"
  cli off ci-waste-guard; RC_OFF=$RC
  cli list; RC_LIST=$RC; ERR_LIST="$ERR"
  AFTER_UNREAD="$(sig "$H")"
  chmod 600 "$H/guardrails-off"
  case "$ERR_LIST" in *"cannot read"*) SAID=1 ;; *) SAID=0 ;; esac
  if [ "$RC_OFF" = 1 ] && [ "$BEFORE_UNREAD" = "$AFTER_UNREAD" ] && [ "$RC_LIST" = 0 ] && [ "$SAID" = 1 ]; then ok "a guardrails-off that cannot be read is not overwritten (off exits 1); list says so and reads it as empty"; else bad "an unreadable guardrails-off" "off rc $RC_OFF, list rc $RC_LIST, said=$SAID, changed=$([ "$BEFORE_UNREAD" = "$AFTER_UNREAD" ] && echo no || echo yes)"; fi
else
  printf '  skip an unreadable guardrails-off (root reads everything)\n'
fi
fresh; use_real; mkhome "$H"; mkdir "$H/guardrails-off"
cli off ci-waste-guard
if [ "$RC" = 1 ] && [ -d "$H/guardrails-off" ] && [ "$(files "$H")" = 1 ]; then ok "a guardrails-off that is a directory: off exits 1, nothing changes"; else bad "a guardrails-off that is a directory" "rc $RC: $ERR"; fi

# ---- D. hook rows -> heimdall-hooks ---------------------------------------------------------------------------------------------------------------------------------
section "D. a hook row is switched through bin/heimdall-hooks (hooks-disabled)"
chk_off_hook && ok "off stop-lint lands in hooks-disabled and never in guardrails-off; on removes it" || bad "off stop-lint" "$REASON"
fresh; use_real; cli off stop-lint; cli off ctx-meter-notice
if [ "$(reader_h stop-lint)" = 1 ] && [ "$(reader_h ctx-meter-notice)" = 1 ] && [ "$(reader_h caveman-rules)" = 0 ] && [ "$(reader_g stop-lint)" = 0 ]; then ok "hmd_hook_enabled reads it (a guard row and a feature row), the neighbours stay enabled"; else bad "the hook reader after off" "stop-lint $(reader_h stop-lint), ctx-meter-notice $(reader_h ctx-meter-notice), caveman-rules $(reader_h caveman-rules)"; fi
cli on stop-lint; cli on ctx-meter-notice
if [ "$(reader_h stop-lint)" = 0 ] && [ "$(reader_h ctx-meter-notice)" = 0 ]; then ok "on enables them again"; else bad "on of hook rows" "stop-lint $(reader_h stop-lint), ctx-meter-notice $(reader_h ctx-meter-notice)"; fi
chk_fixture_delegation && ok "the hook row is switched against the metadata it was classified with (a fixture hook the real metadata has never heard of)" || bad "delegation against the same metadata" "$REASON"

# ---- E. refusals and sources ----------------------------------------------------------------------------------------------------------------------------------------
section "E. unknown ids, untrustworthy files, drift, and where the manifest comes from"
chk_unknown && ok "an unknown id (also one with a newline, and an empty one): exit 1 for off, on and why, nothing written" || bad "an unknown id" "$REASON"
chk_bad_inputs && ok "a manifest or metadata that is missing, relative, not JSON, repeats a key or an id, has an unknown tier, or lists no hooks: exit 1, nothing written" || bad "untrustworthy input" "$REASON"
chk_hook_drift && ok "a recommended hook row whose hook the metadata locks or does not list is core: off exits 2, nothing written, always on in the list" || bad "hook rows the metadata does not unlock" "$REASON"
CLI_ENV=(CLAUDE_PLUGIN_ROOT="$PLUG"); fresh; cli list --json
IDS_PLUG="$(printf '%s' "$OUT" | jq -r '[.[].id] | join(" ")')"
CLI_ENV=(CLAUDE_PLUGIN_ROOT="$PLUG" HMD_GUARDRAILS_MANIFEST="$MANIFEST" HMD_HOOKS_METADATA="$HOOKS_META"); cli list --json
N_OVERRIDE="$(printf '%s' "$OUT" | jq 'length')"
if [ "$IDS_PLUG" = 'opt-hook drift-hook ghost-hook core-hook opt-guard core-guard' ] && [ "$N_OVERRIDE" = "$TOTAL" ]; then ok "the manifest comes from CLAUDE_PLUGIN_ROOT, and HMD_GUARDRAILS_MANIFEST / HMD_HOOKS_METADATA win over it"; else bad "where the manifest comes from" "plugin root: [$IDS_PLUG], override: $N_OVERRIDE rows"; fi

# ---- F. falsifiability ----------------------------------------------------------------------------------------------------------------------------------------------
section "F. defects, each injected alone into a copy of the tool (or of its link-safe helper), turn the check that owns it red"
MUT="$WORK/mut"
MN=0
MUTERR=""
MUTATOR='
import ast, sys
src, dst = sys.argv[1], sys.argv[2]
old, new = sys.stdin.read().rstrip("\n").split("\n=====>\n")
text = open(src, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("the text to replace occurs %d times: %r" % (text.count(old), old[:70]))
mutated = text.replace(old, new)
ast.parse(mutated)
open(dst, "w", encoding="utf-8").write(mutated)
'
# mkcopy NAME -- an unmodified copy of the tool with the validator, the link-safe helper and heimdall-hooks it finds beside itself
mkcopy() {
  mkdir -p "$MUT/$1/bin/lib"
  cp "$CLI" "$MUT/$1/bin/heimdall-guardrails"
  cp "$REPO/bin/heimdall-hooks" "$MUT/$1/bin/heimdall-hooks"
  cp "$REPO/bin/lib/guardrails_manifest.py" "$MUT/$1/bin/lib/guardrails_manifest.py"
  cp "$REPO/bin/lib/hmd_nofollow_write.py" "$MUT/$1/bin/lib/hmd_nofollow_write.py"
}
# run_mutant LABEL NAME CHECK [ARGS...] -- CHECK must go red on the damaged copy NAME
run_mutant() {
  local label="$1" name="$2"; shift 2
  CLI_UNDER_TEST="$MUT/$name/bin/heimdall-guardrails"
  REASON=""
  if "$@" >/dev/null 2>&1; then bad "mutant '$label' survived: $1 is still green"; else ok "mutant '$label' is caught by $1: $(printf '%s' "$REASON" | tr '\n' ' ' | cut -c1-110)"; fi
  CLI_UNDER_TEST="$CLI"
}
# mut_case LABEL CHECK [ARGS...] < SPEC -- SPEC is the text to replace, a line `=====>`, the text to put there (the text must occur exactly once in the tool, and the result must
# still parse); the check must then go red on the damaged copy
mut_case() {
  local label="$1" name; shift
  MN=$((MN + 1)); name="m$MN"
  mkcopy "$name"
  if ! MUTERR="$("$PY" -c "$MUTATOR" "$CLI" "$MUT/$name/bin/heimdall-guardrails" 2>&1)"; then bad "mutant '$label' cannot be injected" "$MUTERR"; return 0; fi
  run_mutant "$label" "$name" "$@"
}
# mut_naive_helper LABEL CHECK [ARGS...] -- a copy whose link-safe helper (bin/lib/hmd_nofollow_write.py) is replaced by one that follows every link; the check must then go red
mut_naive_helper() {
  local label="$1" name; shift
  MN=$((MN + 1)); name="m$MN"
  mkcopy "$name"
  cat > "$MUT/$name/bin/lib/hmd_nofollow_write.py" <<'PYEOF'
import os


class Refused(OSError):
    """never raised: this helper follows every link"""


def open_dir(root, rel, make=False):
    return os.open(os.path.join(os.path.realpath(root), rel), os.O_RDONLY | os.O_DIRECTORY)


def read(root, rel, name, out):
    with open(os.path.join(os.path.realpath(root), rel, name), "rb") as handle:
        out.write(handle.read())


def write(root, rel, name, data, mode=0o600):
    with open(os.path.join(os.path.realpath(root), rel, name), "wb") as handle:
        handle.write(data)
PYEOF
  run_mutant "$label" "$name" "$@"
}
mkcopy control
CLI_UNDER_TEST="$MUT/control/bin/heimdall-guardrails"
if chk_off_sub && chk_off_hook && chk_fixture_delegation; then ok "control: an unmodified copy (the tool, the validator and heimdall-hooks beside it) passes the checks"; else bad "control: an unmodified copy fails" "$REASON"; fi
CLI_UNDER_TEST="$CLI"

mut_case 'a core guard is switchable' chk_core_refused push-secret-scan <<'SPEC'
if row["tier"] != "recommended":
=====>
if row["tier"] == "never":
SPEC
mut_case 'REFUSED exits 1, not 2' chk_core_refused push-secret-scan <<'SPEC'
reason, row["id"]))
        return 2
=====>
reason, row["id"]))
        return 1
SPEC
mut_case 'on of a core id is refused' chk_on_core_noop <<'SPEC'
        if turn_on:
            print("heimdall-guardrails: %s is always on
=====>
        if False:
            print("heimdall-guardrails: %s is always on
SPEC
mut_case 'hook rows are not delegated' chk_off_hook <<'SPEC'
    if row["layer"] == HOOK_LAYER:
        return delegate("enable" if turn_on else "disable", row["id"], registry.metadata_path)
=====>
    if False:
        return delegate("enable" if turn_on else "disable", row["id"], registry.metadata_path)
SPEC
mut_case 'guard rows are delegated to heimdall-hooks' chk_off_sub <<'SPEC'
    return edit_guard_file(row["id"], turn_on, home, place)
=====>
    return delegate("enable" if turn_on else "disable", row["id"], registry.metadata_path)
SPEC
mut_case 'the delegate reads other metadata' chk_fixture_delegation <<'SPEC'
[sys.executable, HOOKS_TOOL, verb, "--metadata", metadata_path, row_id]
=====>
[sys.executable, HOOKS_TOOL, verb, row_id]
SPEC
mut_case 'on keeps the line' chk_on_sub <<'SPEC'
nf.write(parent, name, GUARDRAILS_OFF, b"\n".join(line for line in lines if line != wanted))
=====>
nf.write(parent, name, GUARDRAILS_OFF, data)
SPEC
mut_case 'off glues the id to the last line' chk_off_appends <<'SPEC'
separator = b"" if not data or data.endswith(b"\n") else b"\n"
=====>
separator = b""
SPEC
mut_case 'lines are matched by whitespace, not whole' chk_near_misses <<'SPEC'
lines = data.split(b"\n")
=====>
lines = data.split()
SPEC
mut_case 'a relative HEIMDALL_HOME is written to' chk_relative_home <<'SPEC'
    if not os.path.isabs(home):
        raise CliError("HEIMDALL_HOME %s is not an absolute path: hmd_guardrail_enabled
=====>
    if False:
        raise CliError("HEIMDALL_HOME %s is not an absolute path: hmd_guardrail_enabled
SPEC
mut_case 'an unknown id is accepted' chk_unknown <<'SPEC'
raise CliError("unknown guardrail id %s (see: hmd guardrails list)" % shown(row_id))
=====>
return {"id": row_id, "tier": "recommended", "kind": "guard", "layer": "precheck-bash", "why": "w"}
SPEC
mut_case 'a core id typed into a file shows off' chk_core_listed_stays_on <<'SPEC'
    if registry.refusal(row) is not None:
        return ALWAYS_ON
=====>
    if False:
        return ALWAYS_ON
SPEC
mut_case 'hook rows read the wrong switch file' chk_list_states <<'SPEC'
listed = hook_lines if row["layer"] == HOOK_LAYER else guard_lines
=====>
listed = guard_lines
SPEC
mut_case 'why drops the proof' chk_why <<'SPEC'
("proof", row.get("proof") or "none"),
=====>
("proof", "none"),
SPEC
mut_case 'the manifest is not validated' chk_bad_inputs <<'SPEC'
        if errors:
=====>
        if False:
SPEC
mut_case 'the metadata lock is ignored' chk_hook_drift <<'SPEC'
if row["layer"] == HOOK_LAYER and self.locked.get(row["id"], True):
=====>
if False:
SPEC
mut_case 'a hook the metadata does not list is unlocked' chk_hook_drift <<'SPEC'
self.locked.get(row["id"], True)
=====>
self.locked.get(row["id"], False)
SPEC
mut_case 'a hook the metadata locks is switchable' chk_hook_drift <<'SPEC'
self.locked.get(row["id"], True)
=====>
row["id"] not in self.locked
SPEC
mut_case 'a /tmp fallback is restored' chk_no_home <<'SPEC'
return os.path.join(user_home, ".heimdall") if user_home else None
=====>
return os.path.join(user_home or os.environ.get("MUT_FALLBACK", "/nonexistent-fallback"), ".heimdall")
SPEC
mut_case 'the home mode is not checked' chk_home_vet <<'SPEC'
if info.st_mode & 0o022:
=====>
if False:
SPEC
if [ "$(id -u)" != 0 ] && [ -n "$(find /usr -maxdepth 0 -not -user "$(id -un)")" ]; then
mut_case 'the home owner is not checked' chk_home_vet <<'SPEC'
if info.st_uid != os.geteuid():
=====>
if False:
SPEC
else
  printf '  skip the defect "the home owner is not checked" (no directory of another account to aim at)\n'
fi
mut_naive_helper 'the helper follows links (a guardrails-off link)' chk_symlink
mut_naive_helper 'the helper follows links (a HEIMDALL_HOME link)' chk_home_vet

finish
