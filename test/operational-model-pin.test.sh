#!/usr/bin/env bash
#
# operational-model-pin.test.sh — ZERO PINNED MODEL IDS ON AN OPERATIONAL SPAWN PATH.
#
# WHY: Opus 5 shipped and Heimdall kept spawning claude-opus-4-8, because the tier
# tables the orchestrator reads before every spawn mapped each tier to a FULL MODEL
# ID. A pinned id is correct on the day it is typed and silently last-generation on
# the day after — the failure is invisible, costs quality on every code task, and
# nothing goes red. bin/heimdall-model-resolve fixed the shell call sites; this gate
# closes the class everywhere, including the prose surfaces an agent reads as
# instructions and then obeys.
#
# THE RULE (.planning/settings.json model_routing, authoritative):
#   Operational spawns pass the BARE TIER ALIAS — opus | sonnet | haiku — so Claude
#   Code itself resolves the current generation of that tier. A full model id may be
#   pinned ONLY for bench/eval reproducibility, via HEIMDALL_MODEL_<TIER>=<full-id>.
#
# Guarantees proved:
#   1. The swept set is real (a scan that matched no files must not pass).
#   2. Every allowlist entry is backed — the path exists, a NON-COMMENT anchor proves
#      the file genuinely is the bench/doc surface the entry claims, and the entry's
#      line pattern still matches something. Checked BEFORE the allowlist excuses
#      anything, so a stale exemption cannot buy a pass.
#   3. THE LOAD-BEARING ASSERTION: zero unexcused pinned ids across bin/ hooks/
#      agents/ commands/ skills/ modules/ sentinels/ deploy/ .claude-plugin/.
#   4. PROVE-DETECTS: a planted pin is flagged. A green sweep is worth nothing if the
#      pattern stopped matching — that reads exactly like a clean tree.
#   5. PROVE-NARROW: the allowlist is LINE-scoped, never FILE-scoped. For EVERY
#      allowlisted file, a pin planted on a line the entry does not cover is still
#      flagged. This is what makes a widened allowlist impossible to read as clean.
#   6. The agent routing tables state the rule and name the resolver, and carry no
#      generation-shaped model name in any spelling ("Opus 4.8" is the same defect
#      as claude-opus-4-8, wearing a different hat).
#   7. The recommended default path still works end to end: each tier resolves to its
#      bare alias, and HEIMDALL_MODEL_<TIER> still pins for bench/eval repro.
#
# Usage:  test/operational-model-pin.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
cd "$REPO" || exit 2

RESOLVE="$REPO/bin/heimdall-model-resolve"

# The shape of a pinned id: a tier name followed by a generation. Deliberately
# version-free — it must catch the NEXT stale pin, not just today's.
PIN_RE='claude-(opus|sonnet|haiku|fable)-[0-9]'

# A model generation written in prose rather than as an id. Same rot, same class.
PROSE_RE='(Opus|Sonnet|Haiku|Fable)[ -][0-9]'

# ── The swept surface ────────────────────────────────────────────────────────
# Every directory from which hmd launches Claude Code, the Agent SDK, or reads
# spawn instructions. Named explicitly rather than swept whole-repo: test/ and
# docs/analysis/ must stay free to WRITE a pinned id in order to forbid or refute
# one, and evals/ is where pinning is the point.
SWEPT_PATHSPECS=(bin hooks agents commands skills modules sentinels deploy .claude-plugin)

# ── The allowlist ────────────────────────────────────────────────────────────
# "<relpath>|<non-comment anchor>|<probe line>|<line ERE>"
#
# Four columns because a path alone would make this a suppression list — append a
# file, silence the gate. Each column is a live obligation, re-checked every run:
#
#   ANCHOR  a literal that must appear on a NON-COMMENT line, proving the file
#           really is the surface the entry claims. A comment can outlive the code
#           it describes; that is how an exemption survives the thing it excused.
#   PROBE   a line that the ERE must NOT cover. Planted in a copy of the file, it
#           must still be flagged — that is what proves the excuse is line-scoped.
#   ERE     the exact line shape excused. Last column on purpose: an ERE may itself
#           contain '|', and `read` hands every remaining separator to the final
#           variable, so any earlier position would truncate it at its first
#           alternation bar and silently narrow the exemption.
#
# Anchors and probes must therefore contain no '|'.
#
# The entries, and why each is legitimate under the rule:
#   bin/heimdall-bench          the bench harness's own help text, showing how to
#                               PIN a model for a reproducible published table.
#                               Pinning is the documented purpose of that flag.
#   bin/heimdall-model-resolve  the resolver's header, which must be able to show
#                               what a pin looks like in order to explain the
#                               HEIMDALL_MODEL_<TIER> override. Comments only —
#                               a pin in its CODE is still caught.
#   bin/lib/tier-table.json     the no_pinned_ids note, which quotes the exact id
#                               that rotted as its cautionary example.
ALLOW_ROWS='bin/heimdall-bench|--model <id>|PIN_PROBE=claude-opus-4-8|heimdall-bench --live --model claude-
bin/heimdall-model-resolve|HEIMDALL_MODEL_OPUS|PIN_PROBE=claude-opus-4-8|^#
bin/lib/tier-table.json|no_pinned_ids|  "probe_pin": "claude-opus-4-8",|"no_pinned_ids"'

# The agent templates whose routing tables an orchestrator reads before it spawns.
ROUTING_TEMPLATES="agents/heimdall.md agents/architect.md agents/planner.md"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/op-model-pin.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "operational-model-pin harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# excused <relpath> <line text> — 0 when the allowlist entry for this exact path
# covers this exact line. File membership alone is deliberately NOT enough.
excused() {
  local rel="$1" text="$2" rrel ranchor rprobe rere
  while IFS='|' read -r rrel ranchor rprobe rere; do
    [ -n "$rrel" ] || continue
    [ "$rrel" = "$rel" ] || continue
    printf '%s\n' "$text" | grep -Eq -e "$rere" && return 0
  done <<ROWS
$ALLOW_ROWS
ROWS
  return 1
}

# scan_one <relpath> <file to read> — print "<lineno>:<text>" for every pin the
# allowlist does not cover. The relpath selects the allowlist entry; the file read
# is separate so the same logic can be pointed at a mutated copy.
scan_one() {
  local rel="$1" path="$2" hit ln text
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    ln="${hit%%:*}"; text="${hit#*:}"
    excused "$rel" "$text" && continue
    printf '%s:%s\n' "$ln" "$text"
  done <<HITS
$(grep -nE -e "$PIN_RE" "$path" 2>/dev/null || true)
HITS
}

# ── 1. THE SWEPT SET IS REAL ─────────────────────────────────────────────────
SWEPT="$(git ls-files -- "${SWEPT_PATHSPECS[@]}" 2>/dev/null || true)"
SWEPT_N="$(printf '%s\n' "$SWEPT" | grep -c . || true)"
if [ "$SWEPT_N" -eq 0 ]; then
  bad "the file scan matched NOTHING across ${SWEPT_PATHSPECS[*]} — an empty scan must not pass"
else
  ok "scanning $SWEPT_N tracked file(s) across ${SWEPT_PATHSPECS[*]} for pinned model ids"
fi

# ── 2. ALLOWLIST INTEGRITY — checked BEFORE it excuses anything ──────────────
ALLOW_OK=1
ALLOW_N=0
while IFS='|' read -r rel anchor probe ere; do
  [ -n "$rel" ] || continue
  ALLOW_N=$((ALLOW_N+1))
  if [ ! -f "$REPO/$rel" ]; then
    bad "allowlist names $rel, which does not exist — remove the entry or restore the file"
    ALLOW_OK=0; continue
  fi
  # Every pattern is passed with -e. An anchor legitimately starts with '-' (the
  # bench harness's own `--model <id>` help line), and without -e grep parses it as
  # an option and dies — which this gate then reported as a STALE exemption, a red
  # for entirely the wrong reason.
  if ! grep -v '^[[:space:]]*#' "$REPO/$rel" | grep -Fq -e "$anchor"; then
    bad "allowlist entry for $rel is STALE: no NON-COMMENT line contains '$anchor', so nothing proves this file is still the surface the exemption describes"
    ALLOW_OK=0; continue
  fi
  if ! grep -Eq -e "$ere" "$REPO/$rel"; then
    bad "allowlist entry for $rel excuses a line shape (/$ere/) that no longer appears in the file — an exemption covering nothing is dead weight that will one day cover something"
    ALLOW_OK=0; continue
  fi
  if printf '%s\n' "$probe" | grep -Eq -e "$ere"; then
    bad "allowlist entry for $rel declares a probe line its own ERE covers — the narrowness proof below would be vacuous"
    ALLOW_OK=0; continue
  fi
  if ! printf '%s\n' "$probe" | grep -Eq -e "$PIN_RE"; then
    bad "allowlist entry for $rel declares a probe line carrying no pinned id — it could never prove the scan still fires"
    ALLOW_OK=0; continue
  fi
done <<ALLOWCHECK
$ALLOW_ROWS
ALLOWCHECK
[ "$ALLOW_OK" -eq 1 ] \
  && ok "all $ALLOW_N allowlist entr(ies) are backed by a live anchor, a live line shape, and a usable narrowness probe"

# ── 3. THE LOAD-BEARING ASSERTION — zero unexcused pinned ids ────────────────
UNEXCUSED=0
for f in $SWEPT; do
  [ -f "$f" ] || continue
  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    bad "pinned model id on an operational path: $f:$finding"
    printf '       fix: pass the BARE TIER ALIAS (opus|sonnet|haiku) so Claude Code resolves the current generation — bin/heimdall-model-resolve <tier> prints it, and HEIMDALL_MODEL_<TIER> pins it for bench/eval repro\n'
    UNEXCUSED=$((UNEXCUSED+1))
  done <<FINDINGS
$(scan_one "$f" "$f")
FINDINGS
done
[ "$UNEXCUSED" -eq 0 ] \
  && ok "ZERO pinned model ids on an operational spawn path — every tier floats to its current generation"

# ── 4. PROVE-DETECTS ─────────────────────────────────────────────────────────
# The clean verdict above is only worth something if the pattern can still go red.
PROBE_FILE="$TMP/detects.probe"
printf 'spawn the coder with --model claude-opus-4-8\n' > "$PROBE_FILE"
if [ -n "$(scan_one 'no/such/allowlisted/path' "$PROBE_FILE")" ]; then
  ok "PROVE-DETECTS: the scan flags a planted pinned model id"
else
  bad "PROVE-DETECTS: the scan no longer flags a planted pinned id — the clean verdict above is vacuous"
fi

# ── 5. PROVE-NARROW — the allowlist is line-scoped, not file-scoped ──────────
# The excused DIRECTION is already proved by section 3: if an entry's ERE failed to
# cover the real line it exists for, that line would have been reported above. This
# section proves the other direction, which is the one that turns an allowlist into
# a blind spot: a pin added ELSEWHERE in an allowlisted file must still be caught.
NARROW_OK=1
NARROW_N=0
while IFS='|' read -r rel anchor probe ere; do
  [ -n "$rel" ] || continue
  [ -f "$REPO/$rel" ] || continue
  NARROW_N=$((NARROW_N+1))
  MUT="$TMP/mutant-$NARROW_N"
  cp "$REPO/$rel" "$MUT" || { bad "could not copy $rel for the narrowness probe"; NARROW_OK=0; continue; }
  printf '%s\n' "$probe" >> "$MUT"
  if [ -z "$(scan_one "$rel" "$MUT")" ]; then
    bad "PROVE-NARROW: a pin planted OUTSIDE the excused line shape in $rel was not flagged — that exemption is file-wide and hides everything else in the file"
    NARROW_OK=0
  fi
done <<NARROWCHECK
$ALLOW_ROWS
NARROWCHECK
[ "$NARROW_OK" -eq 1 ] && [ "$NARROW_N" -gt 0 ] \
  && ok "PROVE-NARROW: all $NARROW_N allowlisted file(s) still flag a pin planted off the excused line"
[ "$NARROW_N" -eq 0 ] \
  && bad "PROVE-NARROW ran over ZERO allowlisted files — the narrowness proof asserted nothing"

# ── 6. THE ROUTING TABLES TEACH THE RULE, NOT A PIN ──────────────────────────
# These templates are instructions an orchestrator obeys. A table mapping a tier to
# a full id is a spawn path written in prose, and it ages exactly like code.
for t in $ROUTING_TEMPLATES; do
  if [ ! -f "$t" ]; then
    bad "routing template $t missing — the tier table an orchestrator reads is gone"
    continue
  fi
  grep -Fq 'heimdall-model-resolve' "$t" \
    && ok "$t names bin/heimdall-model-resolve — the agent is told how to obtain the model string" \
    || bad "$t never names bin/heimdall-model-resolve — its tier table states a rule with no way to apply it"
  grep -Fq 'HEIMDALL_MODEL_' "$t" \
    && ok "$t documents the HEIMDALL_MODEL_<TIER> pin as the bench/eval-only escape hatch" \
    || bad "$t omits HEIMDALL_MODEL_<TIER> — the only legitimate way to pin is undocumented where the rule is stated"
  PROSE="$(grep -nE -e "$PROSE_RE" "$t" || true)"
  if [ -z "$PROSE" ]; then
    ok "$t names no model generation in prose either"
  else
    bad "$t names a model generation in prose — same rot as a pinned id:"
    printf '       %s\n' "$PROSE"
  fi
done

# ── 7. THE RECOMMENDED DEFAULT PATH STILL WORKS ──────────────────────────────
# The two halves of the rule, asserted here so this gate stands on its own: the
# default floats, and the documented pin still overrides it.
if [ ! -x "$RESOLVE" ]; then
  bad "bin/heimdall-model-resolve missing or not executable — nothing renders a tier into a model string"
else
  # opus/haiku resolve to the bare alias. sonnet resolves to the 1M-context
  # alias `sonnet[1m]` — still an ALIAS (Claude Code picks the current
  # generation: the shipped 2.1.227 binary labels it "Sonnet 5 with 1M context
  # window"), so the no-pinned-id rule is intact. The suffix exists because
  # sonnet is the only tier where the 1M window is opt-in; opus and fable
  # already carry 1M as their default maximum, and haiku has no 1M variant.
  for tier in opus haiku; do
    got="$(env -u HEIMDALL_MODEL_OPUS -u HEIMDALL_MODEL_SONNET -u HEIMDALL_MODEL_HAIKU \
           "$RESOLVE" "$tier" 2>/dev/null)"
    [ "$got" = "$tier" ] \
      && ok "default: tier '$tier' resolves to the bare alias '$got' (Claude Code picks the current generation)" \
      || bad "tier '$tier' resolved to '$got', expected the bare alias '$tier'"
  done

  got="$(env -u HEIMDALL_MODEL_SONNET "$RESOLVE" sonnet 2>/dev/null)"
  [ "$got" = "sonnet[1m]" ] \
    && ok "default: tier 'sonnet' resolves to '$got' — the 1M-context alias, so long sessions stop compacting" \
    || bad "tier 'sonnet' resolved to '$got', expected 'sonnet[1m]'"
  # the suffix must not smuggle in a pinned generation
  case "$got" in
    *claude-sonnet-[0-9]*) bad "sonnet resolved to '$got' — a pinned generation, which silently ages" ;;
    *) ok "sonnet's 1M form names no model generation (still floats to current-gen)" ;;
  esac
  # haiku has NO 1M variant — asserting it never grows one by accident
  got="$(env -u HEIMDALL_MODEL_HAIKU "$RESOLVE" haiku 2>/dev/null)"
  case "$got" in
    *'[1m]'*) bad "haiku resolved to '$got' — no haiku[1m] exists; this would be an invalid --model" ;;
    *) ok "haiku carries no [1m] suffix (no such variant exists; its window is 200K)" ;;
  esac
  # opus already defaults to 1M — the 4.x-era suffix must not be re-added
  got="$(env -u HEIMDALL_MODEL_OPUS "$RESOLVE" opus 2>/dev/null)"
  case "$got" in
    *'[1m]'*) bad "opus resolved to '$got' — opus already defaults to a 1M window; the suffix is the 4.x-era opt-in" ;;
    *) ok "opus carries no [1m] suffix (1M is already its default maximum)" ;;
  esac
  # escape hatch: a cost-capped or pre-1M bench run can opt out
  got="$(env -u HEIMDALL_MODEL_SONNET HEIMDALL_NO_1M=1 "$RESOLVE" sonnet 2>/dev/null)"
  [ "$got" = "sonnet" ] \
    && ok "HEIMDALL_NO_1M=1 suppresses the suffix -> '$got' (cost cap / pre-1M bench repro)" \
    || bad "HEIMDALL_NO_1M=1 gave '$got', expected the bare alias 'sonnet'"
  got="$(HEIMDALL_MODEL_OPUS=claude-opus-9-9 "$RESOLVE" opus 2>/dev/null)"
  [ "$got" = "claude-opus-9-9" ] \
    && ok "override: HEIMDALL_MODEL_OPUS still pins opus -> '$got' (bench/eval repro preserved)" \
    || bad "HEIMDALL_MODEL_OPUS override -> '$got', expected the pinned id — bench reproducibility is broken"
  got="$(HEIMDALL_MODEL_SONNET=claude-sonnet-9-9 "$RESOLVE" sonnet 2>/dev/null)"
  [ "$got" = "claude-sonnet-9-9" ] \
    && ok "override: HEIMDALL_MODEL_SONNET still pins sonnet -> '$got'" \
    || bad "HEIMDALL_MODEL_SONNET override -> '$got', expected the pinned id"
  got="$(HEIMDALL_MODEL_HAIKU=claude-haiku-9-9 "$RESOLVE" haiku 2>/dev/null)"
  [ "$got" = "claude-haiku-9-9" ] \
    && ok "override: HEIMDALL_MODEL_HAIKU still pins haiku -> '$got'" \
    || bad "HEIMDALL_MODEL_HAIKU override -> '$got', expected the pinned id"
fi

echo ""
echo "operational-model-pin.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
