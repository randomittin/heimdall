#!/usr/bin/env bash
# test/install-reset-userdata.test.sh -- INV-L10 (lean-core plan, T4.4): `install.sh --reset` never touches the user's ledger, receipts, memory, team, pairing
# or data/, which live in the SAME directory as the plugin clone (~/.heimdall is both). Invariants: .planning/lean-core/INVARIANTS.md; the rest of the reset
# is test/install-reset.test.sh.
#
# The journey: a developer who has used hmd for months (a full install made by the install.sh that predates the lean profile, then their own data in the
# runtime home) runs `install.sh --reset`, and later runs the undo command it printed. Real install.sh of the tree under test, offline, in the use-case sandbox
# of test/use-cases/lib.sh (a private HOME, `env -i`, a fake `claude` and `security`, HEIMDALL_REPO a local snapshot; the operator's ~/.heimdall, ~/.claude and
# keychain are never read or written). Proof that the data is untouched is a manifest of every file under those names, path and sha256, taken before the reset,
# after it and after the undo: no file is missing or changed. The ONE thing allowed to appear is the installer's own per-run install receipt
# (receipts/installs-run-<id>.ndjson, written by every install.sh run, flag or not). The run is not vacuous: the same check shows the tree went lean and the
# undo brought the full tree back. The backup is held to the same line: it contains none of the data (no entry of its manifest names it, and a secret planted
# in the data is nowhere under backups/).
# The Headroom CLI acts on launchd and is another subsystem: the release used here carries a recording stand-in at bin/heimdall-headroom, so the real one never runs.
#
# budget: 120 -- about 70 s solo: one existing install by the pinned installer, one real install.sh --reset (a local fetch, python and git starts, the doctor,
# a sparse apply of ~2300 files, the fake claude), one `heimdall-lean off` undo. No sleep, no timing assertion.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../bin/lib/lean_install_fixture.sh
. "$HERE/../bin/lib/lean_install_fixture.sh"
BASELINE="$HERE/../evals/lean/install-baseline.json"
uc_begin install_reset_userdata
uc_need_node
uc_need_crypto
uc_tree
uc_fakebin
[ -f "$BASELINE" ] || uc_fatal "missing $BASELINE"

# ud_release NAME TAG CMD... -- a copy of the tree under test with ONE more commit (CMD runs in the copy), tagged TAG: a release the installer can be pointed at.
ud_release() {
  local name="$1" tag="$2" dir="$UC_ROOT/rel-$1"
  shift 2
  git clone -q --no-hardlinks "$UC_TREE" "$dir" || uc_fatal "cannot copy the tree under test for the $name release"
  ( cd "$dir" && "$@" ) || uc_fatal "the $name release edit failed"
  git -c core.hooksPath=/dev/null -C "$dir" add -A -f || uc_fatal "cannot stage the $name release"
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=use-case@example.invalid -c user.name=use-case \
    -C "$dir" commit -q --no-verify -m "$name release" || uc_fatal "cannot commit the $name release"
  git -c tag.gpgsign=false -C "$dir" tag "$tag" || uc_fatal "cannot tag the $name release"
  UD_REL="$dir"
}
ud_edit_double() {   # (in a tree) the Headroom CLI becomes a recording stand-in: it appends its arguments to $UD_HEADROOM_LOG and changes nothing
  cat > bin/heimdall-headroom <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${UD_HEADROOM_LOG:-/dev/null}"
echo "headroom double: $*"
EOF
  chmod +x bin/heimdall-headroom
}

UD_SECRET="userdata-secret-$$-$RANDOM-$RANDOM"
UD_PATHS="ledger receipts memory team pairing pairing.json data"   # team.json joins the list below only when the data seeded it (the installer owns one that exists)

ud_seed() {   # CLONE -- the developer's own data, beside the plugin clone
  local h="$1"
  mkdir -p "$h/ledger/2026/11" "$h/receipts" "$h/memory/projects" "$h/team" "$h/pairing/devices" "$h/data/cache"
  printf 'row one %s\nrow two\n' "$UD_SECRET" > "$h/ledger/2026/11/21.ndjson"
  printf 'a file with a space\n' > "$h/ledger/file with space.ndjson"
  printf '{"kind":"seed","secret":"%s"}\n' "$UD_SECRET" > "$h/receipts/seed-receipt.json"
  printf '# memory\nremember %s\n' "$UD_SECRET" > "$h/memory/MEMORY.md"
  printf 'project note\n' > "$h/memory/projects/note.md"
  printf '{"members":["a","b"],"secret":"%s"}\n' "$UD_SECRET" > "$h/team/roster.json"
  printf '{"paired":true}\n' > "$h/pairing/devices/phone.json"
  printf '{"code":"123456"}\n' > "$h/pairing.json"
  head -c 2048 /dev/urandom > "$h/data/cache/blob.bin"
  if [ ! -e "$h/team.json" ]; then
    printf '{"team_secret":"%s"}\n' "$UD_SECRET" > "$h/team.json"
    UD_PATHS="$UD_PATHS team.json"
  fi
}
ud_manifest() {   # CLONE -- path and sha256 of every file under the user-data names, sorted: equal before and after means not one byte moved
  ( cd "$1" && for p in $UD_PATHS; do [ -e "$p" ] && find "$p" -type f -print0; done | LC_ALL=C sort -z | xargs -0 shasum -a 256 | LC_ALL=C sort )
}
# ud_same LABEL BEFORE AFTER -- no file of BEFORE is missing or changed in AFTER; a new file may only be the installer's own per-run install receipt
ud_same() {
  local lost new
  lost="$(LC_ALL=C comm -23 "$2" "$3")"
  new="$(LC_ALL=C comm -13 "$2" "$3" | sed 's/^[0-9a-f]*  //' | grep -v '^receipts/installs-run-.*\.ndjson$' || true)"
  if [ -z "$lost" ]; then uc_ok "$1: every file of the user data is there with the same sha256"; else uc_bad "$1: user data was lost or changed" "$(printf '%s\n' "$lost" | head -3 | tr '\n' '|')"; fi
  if [ -z "$new" ]; then uc_ok "$1: nothing was added to the user data (bar the installer's own install receipt)"; else uc_bad "$1: files appeared in the user data" "$(printf '%s\n' "$new" | head -3 | tr '\n' '|')"; fi
}

# 0. the existing install and the developer's data
uc_sandbox ud
CLONE="$UC_HOME/.heimdall"
lean_fx_baseline_installer "$BASELINE" "$UC_ROOT/baseline-installer/install.sh" 2>"$UC_ROOT/baseline-installer.err" \
  || uc_fatal "the install.sh the baseline was recorded from is not available: $(head -c 400 "$UC_ROOT/baseline-installer.err" | LC_ALL=C tr '\n' ' ')"
printf '# my zshrc\nclaude() { hmd route claude "$@"; }\n' > "$UC_HOME/.zshrc"
mkdir -p "$UC_HOME/.claude"
printf '{"theme":"dark"}\n' > "$UC_HOME/.claude/settings.json"
uc_run "$UC_HOME" "$UC_WORK" HEIMDALL_REPO="$UC_TREE" HEIMDALL_REF="$UC_REF" SHELL=/bin/zsh -- bash "$UC_ROOT/baseline-installer/install.sh"
uc_rc "0. the existing install (the installer that predates the lean profile) finishes" 0
: > "$CLONE/setup-done"
uc_run "$UC_HOME" "$UC_WORK" HEIMDALL_HOME="$CLONE" -- python3 -I "$CLONE/bin/lib/skills_config.py" init --marker-present
uc_rc "...and the launcher's first run records the grandfathering" 0
ud_seed "$CLONE"
ud_manifest "$CLONE" > "$UC_ROOT/ud-before.txt"
if [ "$(wc -l < "$UC_ROOT/ud-before.txt" | tr -d ' ')" -ge 9 ]; then uc_ok "the user data is seeded ($(wc -l < "$UC_ROOT/ud-before.txt" | tr -d ' ') files under ledger, receipts, memory, team, pairing, data)"; else uc_bad "the seeding made too few files for the check to mean anything"; fi
ud_release double "v$UC_VERSION-userdata-double" ud_edit_double
UD_DOUBLE="$UD_REL"; UD_DOUBLE_TAG="v$UC_VERSION-userdata-double"
: > "$UC_ROOT/headroom.log"

# 1. the reset
uc_run "$UC_HOME" "$UC_WORK" HEIMDALL_REPO="$UD_DOUBLE" HEIMDALL_REF="$UD_DOUBLE_TAG" SHELL=/bin/zsh UD_HEADROOM_LOG="$UC_ROOT/headroom.log" HEADROOM_PORT=9 \
  -- bash "$UC_TREE/install.sh" --reset
cp "$UC_OUT" "$UC_ROOT/reset.out"
uc_rc "1. install.sh --reset finishes" 0
uc_has "the reset ran to its last step" "$UC_ROOT/reset.out" '8/8 to undo: '
if [ "$(git -C "$CLONE" config --bool --get core.sparseCheckout 2>/dev/null || true)" = true ] && [ ! -e "$CLONE/test" ] && [ ! -e "$CLONE/.planning" ]; then
  uc_ok "the tree really went lean (so the check below is not vacuous)"
else
  uc_bad "the reset did not make the tree lean"
fi
ud_manifest "$CLONE" > "$UC_ROOT/ud-after-reset.txt"
ud_same "INV-L10 after the reset" "$UC_ROOT/ud-before.txt" "$UC_ROOT/ud-after-reset.txt"
if git -C "$CLONE" rev-parse --verify -q 'HEAD^{commit}' >/dev/null && [ -d "$CLONE/.git" ]; then uc_ok "the clone is intact: nothing wiped ~/.heimdall"; else uc_bad "the clone's git directory is damaged"; fi

# 2. the backup holds none of it
BACKUP="$(sed -n 's/^   2\/8 backup: //p' "$UC_ROOT/reset.out" | head -1)"
if [ -f "$BACKUP/manifest.json" ]; then uc_ok "the reset took a backup ($BACKUP)"; else uc_bad "no backup at the printed path: $BACKUP"; fi
if [ -z "$(jq -r '.entries[].id' "$BACKUP/manifest.json" 2>/dev/null | grep -E '^(ledger|receipts|memory|team|pairing|data)' || true)" ]; then uc_ok "no entry of the backup names user data"; else uc_bad "the backup manifest names user data"; fi
if ! grep -rqF "$UD_SECRET" "$CLONE/backups" 2>/dev/null; then uc_ok "a secret planted in the data is nowhere under backups/"; else uc_bad "the backup copied user data (the planted secret is in it)"; fi

# 3. the undo, as printed
UNDO="$(sed -n 's/^   8\/8 to undo: //p' "$UC_ROOT/reset.out" | head -1)"
uc_run "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh -- bash -c "$UNDO"
uc_rc "3. the printed undo command runs" 0
if [ "$(git -C "$CLONE" config --bool --get core.sparseCheckout 2>/dev/null || true)" != true ] && [ -d "$CLONE/test" ]; then uc_ok "the undo brought the full tree back"; else uc_bad "the undo did not bring the full tree back"; fi
ud_manifest "$CLONE" > "$UC_ROOT/ud-after-undo.txt"
ud_same "INV-L10 after the undo" "$UC_ROOT/ud-before.txt" "$UC_ROOT/ud-after-undo.txt"
if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "the reset asked the keychain"; fi

uc_finish
