#!/usr/bin/env bash
#
# share-card.test.sh — acceptance harness for the IDENTITY-HOOK viral artifact:
# the "claim your watchman" share card (sentinels/hmd-banner.sh --share) and the
# install.sh success-card watchman moment.
#
# Proves the guarantees the share artifact lives or dies on:
#
#   1. POSTABLE NON-TTY BLOCK — `hmd-banner.sh --share </dev/null` (piped) emits a
#      clean block with ZERO ANSI escapes, exit 0, carrying the tagline + public
#      URL + handle, so it pastes into GitHub/HN as text.
#   2. DETERMINISTIC — same seed -> byte-identical card; a different seed -> a
#      different sigil (the falsifier: the art is keyed on identity, not noise).
#   3. PUBLIC-ONLY / NO SECRET — the card never carries an enroll token or any
#      cp-endpoint secret; bin/secret-scan stays clean.
#   4. TTY CARD RENDERS — on a real terminal the share card emits the colored
#      sigil (truecolor) + the URL (screen-recording / avatar form).
#   5. INSTALL SUCCESS CARD — an interactive install prints the dev's watchman
#      sigil + the `hmd invite` / share pointers; a non-interactive (curl|bash /
#      CI) install renders NONE of it — a clean no-op.
#   6. SYNTAX — both edited scripts are `bash -n` clean.
#
# Usage:  test/share-card.test.sh
# Exit 0 = every guarantee holds. Non-zero = a guarantee regressed (prints which).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REF="$(git -C "$REPO" rev-parse HEAD)"
BANNER="$REPO/sentinels/hmd-banner.sh"
INSTALL="$REPO/install.sh"
PUBLIC_URL="https://runheimdall.dev"
TAGLINE="nothing ships unproven"

# ── Hermeticity guard ────────────────────────────────────────────────────────
# This suite runs the REAL install.sh, which resolves an existing `hmd` via
# `command -v hmd`. If the dev's inherited PATH carries <repo>/bin, the installer
# would treat the repo's OWN tracked bin/hmd as a stale shadow and OVERWRITE it in
# place — mutating a tracked file (the dev-env-breaking bug). Two defenses:
#   1) run install.sh under a CONTROLLED PATH (SYS) — python3/git + system dirs
#      only, never the inherited PATH — so `command -v hmd` finds nothing to touch;
#   2) a tripwire that RESTORES + fails loudly if any tracked bin/ file changed.
SYS="$(dirname "$(command -v python3)"):$(dirname "$(command -v git)"):/usr/bin:/bin"
BIN_GUARD_BEFORE="$(git -C "$REPO" status --porcelain -- bin/ 2>/dev/null)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP_ROOT="$(mktemp -d)"
EMPTY_ID="$TMP_ROOT/empty-id"; mkdir -p "$EMPTY_ID"   # no identity.json -> HMD_HAID wins

# ── Fake `claude`: satisfy install's preflight + plugin steps with no network ──
FAKE_DIR="$(mktemp -d)"
cat > "$FAKE_DIR/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "1.5.0 (Claude Code)"; exit 0 ;;
  plugins)   exit 0 ;;
  *)         exit 0 ;;
esac
EOF
chmod +x "$FAKE_DIR/claude"
# Cleanup + tripwire: a hermetic install test must NEVER mutate a tracked file.
# If bin/ changed on ANY exit path, restore it and shout (belt to the explicit
# assertion in the body, which owns the exit code).
cleanup() {
  local after; after="$(git -C "$REPO" status --porcelain -- bin/ 2>/dev/null)"
  if [ "$after" != "$BIN_GUARD_BEFORE" ]; then
    printf '\n\033[31mFATAL\033[0m test mutated tracked bin/ — restoring:\n%s\n' "$after" >&2
    git -C "$REPO" checkout -- bin/ 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT" "$FAKE_DIR"
}
trap cleanup EXIT

# Count ESC (0x1b) bytes in a file — the ANSI detector for the paste-clean check.
esc_count() { LC_ALL=C tr -cd '\033' < "$1" | wc -c | tr -d ' '; }

echo "share-card harness  repo=$REPO  ref=${REF:0:12}"
echo "--------------------------------------------------------------------"

# A stable, obviously-fake seed so the card is reproducible and the handle known.
SEED="watchman-test-7f3a"
EXP_HANDLE="$(env HEIMDALL_IDENTITY_DIR="$EMPTY_ID" HMD_HAID="$SEED" \
  "$REPO/bin/heimdall-identity" --handle 2>/dev/null || true)"
[ -n "$EXP_HANDLE" ] || EXP_HANDLE="$SEED"

run_share() { # stdout-capturing, NON-TTY (piped) share render for $1=seed
  env HEIMDALL_IDENTITY_DIR="$EMPTY_ID" HMD_HAID="$1" \
    bash "$BANNER" --share </dev/null
}

# ── (1) POSTABLE NON-TTY BLOCK ────────────────────────────────────────────────
SHARE_OUT="$TMP_ROOT/share.out"
run_share "$SEED" > "$SHARE_OUT" 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "share --share (piped) exits 0" || bad "share --share exit $RC (want 0)"

EC="$(esc_count "$SHARE_OUT")"
[ "$EC" = "0" ] && ok "share (piped) is ANSI-free ($EC ESC bytes) — pastes as text" \
                || bad "share (piped) leaked $EC ANSI escape bytes (want 0)"

grep -qF "$TAGLINE" "$SHARE_OUT" \
  && ok "share carries the tagline ('$TAGLINE')" \
  || bad "share missing the tagline"
grep -qF "$PUBLIC_URL" "$SHARE_OUT" \
  && ok "share carries the public join URL ($PUBLIC_URL)" \
  || bad "share missing the public URL"
grep -qF "@$EXP_HANDLE" "$SHARE_OUT" \
  && ok "share carries the handle (@$EXP_HANDLE)" \
  || bad "share missing the handle @$EXP_HANDLE"
grep -qF "my Heimdall watchman — $PUBLIC_URL" "$SHARE_OUT" \
  && ok "share carries the one-line caption" \
  || bad "share missing the 'my Heimdall watchman' caption"

# ── (2) DETERMINISTIC ─────────────────────────────────────────────────────────
A="$TMP_ROOT/det-a"; B="$TMP_ROOT/det-b"
run_share "$SEED" > "$A" 2>&1
run_share "$SEED" > "$B" 2>&1
cmp -s "$A" "$B" && ok "deterministic: same seed -> byte-identical card" \
                 || bad "non-deterministic: two renders of seed differ"

# Falsifier: a different seed must yield a DIFFERENT sigil (extract the art rows
# — the block lines that are pure sigil glyphs/space, before the handle line).
sigil_of() { sed -n '/^  *[▓█ ]*$/p' "$1" | grep -v '^$'; }
C="$TMP_ROOT/det-c"
run_share "a-totally-different-seed-9q2" > "$C" 2>&1
if diff -q <(sigil_of "$A") <(sigil_of "$C") >/dev/null; then
  bad "falsifier: two different seeds produced the SAME sigil (art not identity-keyed)"
else
  ok "falsifier: different seed -> different sigil"
fi

# ── (3) PUBLIC-ONLY / NO SECRET ───────────────────────────────────────────────
# The card must never carry an enroll-token shape. Inject a fake secret into the
# environment + a cp-endpoint and prove it NEVER reaches the card output.
FAKE_TOK="ENROLLTOK-deadbeef-NEVER-ON-A-CARD-0xCAFE"
SECRET_OUT="$TMP_ROOT/secret.out"
env HEIMDALL_IDENTITY_DIR="$EMPTY_ID" HMD_HAID="$SEED" \
    HEIMDALL_ENROLL_TOKEN="$FAKE_TOK" ENROLL_TOKEN="$FAKE_TOK" \
    bash "$BANNER" --share </dev/null > "$SECRET_OUT" 2>&1
if grep -qF "$FAKE_TOK" "$SECRET_OUT"; then
  bad "SECRET LEAK: the enroll token appeared on the share card"
else
  ok "no secret leak: enroll token never reaches the card"
fi
# Static: the banner never reads any secret config file. Strip full-line comments
# first — the constraint bars actual CODE that reads a secret, not a "no secret is
# read here" note in a comment.
if grep -vE '^[[:space:]]*#' "$BANNER" | grep -qE 'cp-endpoint|enroll_token|ENROLL_TOKEN|pki/'; then
  bad "banner references a secret source (cp-endpoint/enroll_token/pki)"
else
  ok "banner reads no secret source (public material only)"
fi
# secret-scan over the whole tree stays clean (the new files included).
if bash "$REPO/bin/secret-scan" >/dev/null 2>&1; then
  ok "bin/secret-scan clean"
else
  bad "bin/secret-scan flagged the tree"
fi

# ── (6) SYNTAX ────────────────────────────────────────────────────────────────
bash -n "$BANNER"  && ok "hmd-banner.sh is bash -n clean"  || bad "hmd-banner.sh has a syntax error"
bash -n "$INSTALL" && ok "install.sh is bash -n clean"     || bad "install.sh has a syntax error"

# ── (4) TTY CARD + (5) INSTALL SUCCESS CARD need a real pty ───────────────────
# pty_run <outfile> <secs> -- cmd args…  : run cmd with stdout on a TTY (so
# `[ -t 1 ]` is true) but stdin on /dev/null (so no prompt path engages / hangs).
# Captures combined output to <outfile>; hard time cap; prints the child exit code.
pty_run() {
  local out="$1" secs="$2"; shift 2; shift   # drop the literal --
  HMD_PTY_OUT="$out" HMD_PTY_SECS="$secs" python3 - "$@" <<'PY'
import os, pty, sys, select, time, subprocess
out_path = os.environ["HMD_PTY_OUT"]
secs     = float(os.environ["HMD_PTY_SECS"])
master, slave = pty.openpty()
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL,
                     stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
buf = bytearray()
deadline = time.time() + secs
rc = None
while True:
    if time.time() > deadline:
        p.kill(); rc = 124; break
    r, _, _ = select.select([master], [], [], 0.5)
    if r:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            chunk = b""
        if chunk:
            buf += chunk
        else:
            break
    if p.poll() is not None:
        # drain any remaining buffered output
        while True:
            r, _, _ = select.select([master], [], [], 0.2)
            if not r:
                break
            try:
                chunk = os.read(master, 4096)
            except OSError:
                chunk = b""
            if not chunk:
                break
            buf += chunk
        break
if rc is None:
    rc = p.wait()
with open(out_path, "wb") as fh:
    fh.write(buf)
print(rc)
PY
}

# Shared install env: a throwaway HOME, fake claude, local repo as the clone
# source, no network. Differs only in TTY-ness / color between the two runs.
INST_HOME_I="$TMP_ROOT/home-tty";   mkdir -p "$INST_HOME_I"
INST_HOME_N="$TMP_ROOT/home-pipe";  mkdir -p "$INST_HOME_N"

# (5a) INTERACTIVE (pty stdout, color on) — the success card SHOULD show the
# watchman sigil + the invite/share pointers. pty_run prints the child rc.
# Identity MUST be pinned (same HEIMDALL_IDENTITY_DIR/HMD_HAID hermeticity as
# run_share() above) — without it, render_sigil() resolves the seed via
# heimdall-haid, which is deterministic from machine+user, NOT from $HOME. On
# a dev box whose real HAID happens to be a CUSTOM_SIGILS pin (e.g. RJ's own
# machine -> the hand-authored "batsy" hero), that hero renders with ITS OWN
# eye color instead of the generic watchman EYE — a real render, just not the
# generic one this check asserts. Pinning $SEED (already non-HAID-shaped, so
# it never collides with a CUSTOM_SIGILS/HERO_SIGILS pin) makes the assertion
# machine-independent instead of failing only on the pinned dev's own box.
ICARD="$TMP_ROOT/install-tty.out"
IRC="$(pty_run "$ICARD" 90 -- env -u NO_COLOR -u HEIMDALL_NO_COLOR \
        -u CLAUDE_CONFIG_DIR -u HEIMDALL_HOME \
        HOME="$INST_HOME_I" TERM="xterm-256color" \
        HEIMDALL_REPO="$REPO" HEIMDALL_REF="$REF" PATH="$FAKE_DIR:$SYS" \
        HEIMDALL_IDENTITY_DIR="$EMPTY_ID" HMD_HAID="$SEED" \
        bash "$INSTALL")"
IRC="$(printf '%s' "$IRC" | tail -1)"

if [ "$IRC" = "124" ]; then
  bad "interactive install hung (pty cap hit)"
else
  ok "interactive install completed (rc=$IRC)"
fi
grep -qF "Your watchman" "$ICARD" \
  && ok "interactive card shows the 'Your watchman' moment" \
  || bad "interactive card missing the watchman label"
grep -qF "invite" "$ICARD" \
  && ok "interactive card points to the team-recruit invite" \
  || bad "interactive card missing the invite pointer"
grep -qF "hmd-banner.sh --share" "$ICARD" \
  && ok "interactive card points to the share command" \
  || bad "interactive card missing the share pointer"
# The eye-glint truecolor is emitted ONLY by the sigil renderer (the install
# banner uses 16-color codes), so its presence proves the SIGIL actually rendered.
if grep -qF "38;2;240;248;255" "$ICARD"; then
  ok "interactive card rendered the watchman sigil (truecolor eye glint)"
else
  bad "interactive card did not render the sigil"
fi

# (5b) NON-INTERACTIVE (piped stdout, TERM=dumb, NO_COLOR) — a clean no-op: the
# watchman block must NOT appear (it would be ANSI garbage in a pipe/CI).
NCARD="$TMP_ROOT/install-pipe.out"
env -u CLAUDE_CONFIG_DIR -u HEIMDALL_HOME \
    HOME="$INST_HOME_N" TERM="dumb" HEIMDALL_NO_COLOR=1 \
    HEIMDALL_REPO="$REPO" HEIMDALL_REF="$REF" PATH="$FAKE_DIR:$SYS" \
    bash "$INSTALL" </dev/null > "$NCARD" 2>&1; NRC=$?
[ "$NRC" -eq 0 ] && ok "non-interactive install exits 0" \
                 || bad "non-interactive install exit $NRC (want 0)"
if grep -qF "Your watchman" "$NCARD"; then
  bad "non-interactive install printed the watchman card (should be a clean no-op)"
else
  ok "non-interactive install: watchman card is a clean no-op"
fi
NEC="$(esc_count "$NCARD")"
[ "$NEC" = "0" ] && ok "non-interactive install output is ANSI-free (clean logs)" \
                 || bad "non-interactive install leaked $NEC ANSI bytes"

# ── HERMETIC — the install runs left the repo's tracked bin/ pristine ───────────
BIN_GUARD_AFTER="$(git -C "$REPO" status --porcelain -- bin/ 2>/dev/null)"
if [ "$BIN_GUARD_AFTER" = "$BIN_GUARD_BEFORE" ]; then
  ok "hermetic: install runs never mutated the repo's tracked bin/ (no clobber)"
else
  bad "install run MUTATED tracked bin/ (non-hermetic): $BIN_GUARD_AFTER"
fi

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "--------------------------------------------------------------------"
echo "share-card: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
