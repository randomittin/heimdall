#!/usr/bin/env bash
# test/invite-nontty-secret.test.sh — bin/heimdall-invite REFUSES to print a live
# team secret to a non-human caller by default.
#
# THE INCIDENT this guards against: an audit agent, told to verify documented
# commands work, ran `heimdall-invite`. It judged the command safe from its docs
# — reasonably. The command's ENTIRE purpose is to print a live
# HEIMDALL_TEAM_SECRET, so a real team secret was written into that agent's own
# session transcript on disk, with no confirmation and no warning. The agent
# behaved well (disclosed, never reprinted, never tried to rotate); the TOOL is
# what failed — it handed a bearer credential to a non-interactive caller. This
# suite proves the fix: stdout-is-not-a-terminal is treated as "not a human",
# and the secret is withheld unless a human deliberately opts in.
#
# Proves, against the REAL CLI with a temp $HOME + a per-repo team.json (via
# HEIMDALL_TEAM_DIR), NO real network call (same test seams as
# test/invite.test.sh: HEIMDALL_INVITE_PUBLISHED_TAGS / _BRANCHES /
# _ASSUME_HTTP), and a FAKE secret (repo carries no real credential;
# secret-scan stays clean):
#
#   (a) SYNTAX      — `bash -n` parses the script clean.
#   (b) WITHHELD    — stdout is not a TTY (command substitution) and no
#                     override: the secret literal appears in NEITHER stdout
#                     NOR stderr, stdout carries no join at all (empty), exit
#                     4, stderr explains what to do about it.
#   (c) OVERRIDE    — same non-TTY caller + --yes-print-secret: the join
#                     prints (secret included) exactly as the plain CLI would,
#                     PLUS the new one-line bearer-credential warning. Exit 0.
#   (d) NOT AMBIENT — plausible pre-existing env vars that mean roughly
#                     "assume yes" / "loud" / "non-interactive is fine"
#                     elsewhere in THIS repo (F1_ASSUME_YES, ASSUME_YES,
#                     HMD_TEAM_AUTO_LOUD — a REAL sibling override in
#                     bin/heimdall-team that forces loud-by-default behavior
#                     ON for a similar TTY-gated check — CI, YES), PLUS the
#                     literal YES_PRINT_SECRET env-var name itself (set via
#                     env, not the flag), do NOT bypass this gate — only the
#                     explicit --yes-print-secret FLAG does.
#   (e) NO-TEAM     — with no team.json at all, a non-TTY caller still gets
#       UNAFFECTED    the ordinary "run heimdall-team new" degrade message
#                     (exit 0) — there is no secret yet, so the TTY gate never
#                     fires and never shadows the pre-existing degrade UX.
#   (f) --help DOCS — `--help` documents --yes-print-secret and exit code 4
#                     (works identically regardless of TTY-ness — argv
#                     parsing exits before the gate is ever reached).
#   (g) STRUCTURAL  — the gate uses the house `[ -t 1 ]` primitive (the same
#                     one bin/heimdall-team, bin/heimdall-demo, bin/heimdall,
#                     bin/lib/select.sh all gate on), and runs BEFORE the join
#                     is ever assembled — so --qr and every downstream path
#                     are covered too.
#   (h) REAL TTY    — under an actual pty (`script -q /dev/null`, the same
#                     primitive test/launch-flow-integration.test.sh and
#                     test/dream-permission-ask.test.sh use), the CLI behaves
#                     EXACTLY like the --yes-print-secret override with NO
#                     flag at all: join prints, secret included, exit 0, the
#                     same new warning line. This is the direct proof a
#                     genuine human at a terminal sees no behavior change.
#                     SKIPs (does not fail the suite) if `script` is
#                     unavailable/unusable in this environment.
#
# A deliberately FAKE secret is used so the test output and the repo carry no
# real credential (secret-scan stays clean). Exit 0 = every assertion passed
# (a SKIP in (h) does not count against this).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-invite"

[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

FAKE_URL="https://cp.example-team.test"
FAKE_SECRET="FAKE-INVITE-NONTTY-SECRET-000000000-not-a-real-token"

# Same network-free test seams as test/invite.test.sh — a join must actually be
# CONSTRUCTIBLE (cases c/h) for "withheld vs printed" to be a meaningful proof,
# not an accident of a ref/HTTP refusal firing instead.
export HEIMDALL_INVITE_PUBLISHED_TAGS="v2.0.9 v2.0.18 v2.0.10"
export HEIMDALL_INVITE_PUBLISHED_BRANCHES="main"
export HEIMDALL_INVITE_ASSUME_HTTP="200"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
skip() { printf "  \033[33mSKIP\033[0m %s\n" "$1"; }

mk_dir()       { local xr; xr="$(printf 'X%.0s' 1 2 3 4 5 6)"; mktemp -d "${TMPDIR:-/tmp}/hmd-invite-nontty.$xr"; }
write_cp_url() { mkdir -p "$1/.heimdall"; printf '{\n  "url": "%s"\n}\n' "$2" > "$1/.heimdall/cp-endpoint.json"; }
write_team()   { mkdir -p "$1"; printf '{\n  "team_secret": "%s",\n  "created": 1719500000\n}\n' "$2" > "$1/team.json"; }

# Pre-declared (never bare-referenced before assignment) so cleanup below can't
# trip this repo's own documented `set -u` nounset trap (see
# test/tree-integrity-guard.test.sh's header) when case (h) SKIPs and its
# sandbox dirs are never created.
HG=""; TDG=""

echo "============================================================"
echo "heimdall-invite — non-TTY secret withholding (security fix)"
echo "============================================================"
echo

# ── (a) SYNTAX ───────────────────────────────────────────────────────────────
if bash -n "$CLI" 2>/dev/null; then
  ok "(a) bash -n parses heimdall-invite clean"
else
  bad "(a) bash -n found a syntax error in heimdall-invite"
fi

# ── (b) WITHHELD — non-TTY, no override ───────────────────────────────────────
HB="$(mk_dir)"; TDB="$(mk_dir)/.heimdall"
write_cp_url "$HB" "$FAKE_URL"; write_team "$TDB" "$FAKE_SECRET"
ERRB="$(mk_dir)/stderr.txt"
BODYB="$(HOME="$HB" HEIMDALL_TEAM_DIR="$TDB" "$CLI" 2>"$ERRB")"
RCB=$?
STDERRB="$(cat "$ERRB")"
if [ "$RCB" -eq 4 ]; then
  ok "(b1) non-TTY without override exits 4"
else
  bad "(b1) expected exit 4, got $RCB"
fi
if ! grep -qF "$FAKE_SECRET" <<<"$BODYB" && ! grep -qF "$FAKE_SECRET" <<<"$STDERRB"; then
  ok "(b2) the secret literal appears in NEITHER stdout NOR stderr"
else
  bad "(b2) FALSIFIER: the secret LEAKED to stdout or stderr:
STDOUT: $BODYB
STDERR: $STDERRB"
fi
if [ -z "$BODYB" ]; then
  ok "(b3) stdout is completely empty on refusal (no partial/fabricated join)"
else
  bad "(b3) stdout should be empty on refusal, got:
$BODYB"
fi
if grep -qi "heimdall-invite" <<<"$STDERRB" && grep -qF -- "--yes-print-secret" <<<"$STDERRB"; then
  ok "(b4) stderr explains what the command does and how a human/override gets it"
else
  bad "(b4) stderr guidance missing expected content:
$STDERRB"
fi

# ── (c) OVERRIDE — non-TTY + --yes-print-secret prints exactly like the plain
#     CLI would, plus the new warning line ────────────────────────────────────
HC="$(mk_dir)"; TDC="$(mk_dir)/.heimdall"
write_cp_url "$HC" "$FAKE_URL"; write_team "$TDC" "$FAKE_SECRET"
OUTC="$(HOME="$HC" HEIMDALL_TEAM_DIR="$TDC" "$CLI" --yes-print-secret; echo "RC=$?")"
RCC="${OUTC##*RC=}"; BODYC="${OUTC%RC=*}"
if [ "$RCC" -eq 0 ] \
   && grep -qF "HEIMDALL_TEAM_SECRET='$FAKE_SECRET'" <<<"$BODYC" \
   && grep -qF "curl -fsSL --proto '=https' https://raw.githubusercontent.com/" <<<"$BODYC" \
   && grep -q "contains your team secret" <<<"$BODYC" \
   && grep -qi "anyone who can read your screen or scrollback" <<<"$BODYC"; then
  ok "(c) --yes-print-secret on a non-TTY caller prints the join + BOTH caveats, exit 0"
else
  bad "(c) FALSIFIER: --yes-print-secret did not print the expected join/warning (rc=$RCC):
$BODYC"
fi

# ── (d) NOT AMBIENT — pre-existing/lookalike env vars must NOT also satisfy
#     this gate; only the explicit --yes-print-secret FLAG does ───────────────
HD="$(mk_dir)"; TDD="$(mk_dir)/.heimdall"
write_cp_url "$HD" "$FAKE_URL"; write_team "$TDD" "$FAKE_SECRET"
for VAR in F1_ASSUME_YES ASSUME_YES HMD_TEAM_AUTO_LOUD CI YES YES_PRINT_SECRET; do
  OUTD="$(env HOME="$HD" HEIMDALL_TEAM_DIR="$TDD" "$VAR=1" "$CLI" 2>/dev/null; echo "RC=$?")"
  RCD="${OUTD##*RC=}"; BODYD="${OUTD%RC=*}"
  if [ "$RCD" -eq 4 ] && ! grep -qF "$FAKE_SECRET" <<<"$BODYD"; then
    ok "(d) $VAR=1 does NOT bypass the gate (still refused, exit 4)"
  else
    bad "(d) FALSIFIER: $VAR=1 bypassed the gate (rc=$RCD):
$BODYD"
  fi
done

# ── (e) NO-TEAM UNAFFECTED — non-TTY + no team.json still gets the ordinary
#     degrade message, not the secret-withholding refusal ────────────────────
HE="$(mk_dir)"; TDE="$(mk_dir)/.heimdall"; mkdir -p "$TDE"   # TDE exists, no team.json
OUTE="$(HOME="$HE" HEIMDALL_TEAM_DIR="$TDE" "$CLI" 2>&1; echo "RC=$?")"
RCE="${OUTE##*RC=}"; BODYE="${OUTE%RC=*}"
if [ "$RCE" -eq 0 ] \
   && grep -q "no team is configured for this repo" <<<"$BODYE" \
   && ! grep -qi "REFUSING to print your live team secret" <<<"$BODYE"; then
  ok "(e) no team.json -> ordinary degrade message wins, exit 0 (gate never shadows it)"
else
  bad "(e) FALSIFIER: no-team degrade path changed behavior (rc=$RCE):
$BODYE"
fi

# ── (f) --help documents the new flag + exit code ─────────────────────────────
HELP_TXT="$("$CLI" --help)"
if grep -qF -- "--yes-print-secret" <<<"$HELP_TXT" && grep -q "4" <<<"$HELP_TXT"; then
  ok "(f) --help documents --yes-print-secret and exit code 4"
else
  bad "(f) FALSIFIER: --help does not document the new flag/exit code:
$HELP_TXT"
fi

# ── (g) STRUCTURAL — the gate uses the house [ -t 1 ] primitive and runs
#     BEFORE the join is ever assembled (so --qr etc. are covered too) ────────
GATE_LINE="$(grep -n '\[ -t 1 \].*YES_PRINT_SECRET.*refuse_nontty' "$CLI" | head -1 | cut -d: -f1)"
JOIN_LINE="$(grep -n '^JOIN_FMT=' "$CLI" | head -1 | cut -d: -f1)"
if [ -n "$GATE_LINE" ] && [ -n "$JOIN_LINE" ] && [ "$GATE_LINE" -lt "$JOIN_LINE" ]; then
  ok "(g) the [ -t 1 ] gate (line $GATE_LINE) runs before JOIN_FMT is built (line $JOIN_LINE)"
else
  bad "(g) FALSIFIER: gate missing, or does not precede JOIN construction (gate=$GATE_LINE join=$JOIN_LINE)"
fi

# ── (h) REAL TTY — a genuine pty behaves exactly like --yes-print-secret, with
#     NO flag at all (the direct proof a human at a terminal sees no change) ──
SCRIPT_BIN="$(command -v script || true)"
if [ -n "$SCRIPT_BIN" ] && "$SCRIPT_BIN" -q /dev/null true </dev/null >/dev/null 2>&1; then
  HG="$(mk_dir)"; TDG="$(mk_dir)/.heimdall"
  write_cp_url "$HG" "$FAKE_URL"; write_team "$TDG" "$FAKE_SECRET"
  PTY_CMD="HOME='$HG' HEIMDALL_TEAM_DIR='$TDG' HEIMDALL_INVITE_PUBLISHED_TAGS='v2.0.9 v2.0.18 v2.0.10' HEIMDALL_INVITE_PUBLISHED_BRANCHES='main' HEIMDALL_INVITE_ASSUME_HTTP='200' '$CLI'; echo PTYRC=\$?"
  PTY_OUT="$("$SCRIPT_BIN" -q /dev/null bash -c "$PTY_CMD" </dev/null 2>&1 | tr -d '\r')"
  PTY_RC="$(printf '%s\n' "$PTY_OUT" | grep -oE 'PTYRC=[0-9]+' | tail -1 | cut -d= -f2)"
  if [ "$PTY_RC" = "0" ] \
     && grep -qF "HEIMDALL_TEAM_SECRET='$FAKE_SECRET'" <<<"$PTY_OUT" \
     && grep -qi "anyone who can read your screen or scrollback" <<<"$PTY_OUT"; then
    ok "(h) a REAL tty prints the join (no flag needed) + the new warning line, exit 0"
  else
    bad "(h) FALSIFIER: real-tty behavior changed (rc=$PTY_RC):
$PTY_OUT"
  fi
else
  skip "(h) real-tty check ('script' unavailable/unusable in this environment)"
fi

# ── cleanup ────────────────────────────────────────────────────────────────────
rm -rf "$HB" "$HC" "$HD" "$HE" "$HG" "$TDB" "$TDC" "$TDD" "$TDE" "$TDG" \
       "$(dirname "$ERRB")" 2>/dev/null || true

echo
echo "  invite-nontty-secret tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
