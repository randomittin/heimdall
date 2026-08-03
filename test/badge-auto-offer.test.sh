#!/usr/bin/env bash
#
# badge-auto-offer.test.sh — the badge OFFER must fire itself, exactly once, on the
# 10th PROVEN merge.
#
# WHY. `hmd badge` mints the viral README badge, but a dev only runs it if they
# already know it exists. The offer therefore has to come to them: one ambient line
# on the statusline at the moment the number is worth showing off. Two failure modes
# bracket the design, and this gate holds both walls up:
#
#   UNDER-FIRING — the offer never appears, so the growth loop never starts.
#   OVER-FIRING  — the offer reappears every session. A nudge that repeats gets
#                  muted, and a muted channel mutes the nudge that MATTERS. This is
#                  the expensive failure, so "once" is enforced by a persisted stamp
#                  and proven by the repeat-render cases below.
#
# THE NUMBER IS REAL, NOT INVENTED. The trigger reads the same store the badge
# itself counts: <repo>/.heimdall/receipts/beats.log, one `<iso-ts>\t<verdict>\t<file>`
# line per gated commit, a proven merge being a `pass` (bin/heimdall-badge:59-63,
# bin/heimdall-clip:61-65 read it identically). The seeds below deliberately mix
# `deny` lines in, so a naive `wc -l` implementation counts wrong and goes RED.
#
# THRESHOLD IS THE 10th EXACTLY. 9 -> silent, 10 -> fires, 11 -> silent. The 11 case
# is asserted BOTH with and without the stamp, so the gate holds whether you read
# "not at the 11th" as "the threshold is exact" or as "the once-guard suppressed it".
#
# FAIL-CLOSED ON PERSISTENCE. If the stamp cannot be written, the notice is NOT
# shown. Showing an offer we cannot record is precisely how a once-only nudge decays
# into an every-session nudge.
#
# LATENCY. The statusline is on the interactive render path, so the trigger must be
# a pure local read — no subprocess, no network. Case 10 removes subprocess from
# reach and asserts the notice still renders; case 11 measures and bounds the cost.
#
# Usage:  bash test/badge-auto-offer.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"
BADGE="$ROOT/bin/heimdall-badge"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ]  || { echo "FATAL: statusline missing at $SL"; exit 2; }
[ -x "$BADGE" ] || { echo "FATAL: heimdall-badge missing at $BADGE"; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

echo "badge-auto-offer harness  repo=$ROOT"
echo "--------------------------------------------------------------------"

# Seed a workspace whose beats.log holds exactly $2 `pass` lines PLUS 2 `deny` lines.
# The denies are load-bearing: they make a line-count implementation disagree with a
# pass-count implementation, so the threshold cases cannot pass by accident.
# $1 = workspace dir, $2 = proven-merge count
seed_ws() {
  local ws="$1" n="$2" i=0
  mkdir -p "$ws/.heimdall/receipts"
  : > "$ws/.heimdall/receipts/beats.log"
  while [ "$i" -lt "$n" ]; do
    printf '2026-07-%02dT09:14:22Z\tpass\tbin/heimdall-badge\n' "$(( (i % 28) + 1 ))" \
      >> "$ws/.heimdall/receipts/beats.log"
    i=$(( i + 1 ))
  done
  printf '2026-07-29T09:14:22Z\tdeny\tbin/heimdall-clip\n'  >> "$ws/.heimdall/receipts/beats.log"
  printf '2026-07-30T09:14:22Z\tdeny\tbin/heimdall-badge\n' >> "$ws/.heimdall/receipts/beats.log"
}

# Render the HUD hermetically against workspace $1. env -i + a throwaway HOME keeps
# the render off this machine's real ~/.heimdall; presence-off keeps it fork-free.
render() {
  local ws="$1"
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.heimdall"; : > "$home/.heimdall/presence-off"
  printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":21}}' "$ws" \
    | env -i PATH="/usr/bin:/bin:/usr/local/bin" HOME="$home" HEIMDALL_HOME="$home/.heimdall" \
        HMD_NOW=7 HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS=120 \
        TERM=xterm python3 "$SL" --no-color 2>/dev/null
  local rc=$?
  rm -rf "$home"
  return $rc
}

# The offer is present iff BOTH its headline and its call-to-action render. Asserting
# the pair stops a bare "badge" elsewhere in the HUD from faking a pass.
has_offer() {
  case "$1" in *"proven merges"*) : ;; *) return 1 ;; esac
  case "$1" in *"hmd badge"*)     return 0 ;; *) return 1 ;; esac
}

STAMP_REL=".heimdall/.badge-offer"

# ── 1) NINE proven merges -> SILENT (the offer must not pre-fire) ─────────────
WS="$(mktemp -d)/repo"; seed_ws "$WS" 9
OUT="$(render "$WS")"; RC=$?
[ "$RC" = 0 ] && ok "9 merges: render exits 0" || bad "9 merges: render exited $RC"
if has_offer "$OUT"; then bad "9 merges: the offer fired EARLY (at the 9th)"
else ok "9 merges: silent — the offer did not pre-fire"; fi
[ -f "$WS/$STAMP_REL" ] && bad "9 merges: a stamp was written without an offer" \
                        || ok "9 merges: no stamp written"
rm -rf "$(dirname "$WS")"

# ── 2) TEN proven merges -> THE OFFER FIRES ──────────────────────────────────
WS="$(mktemp -d)/repo"; seed_ws "$WS" 10
OUT="$(render "$WS")"; RC=$?
[ "$RC" = 0 ] && ok "10 merges: render exits 0" || bad "10 merges: render exited $RC"
if has_offer "$OUT"; then ok "10 merges: THE OFFER FIRED"
else bad "10 merges: the offer did NOT fire at the 10th proven merge"; fi
case "$OUT" in *"10 proven merges"*) ok "10 merges: the offer names the real count (10)" ;;
  *) bad "10 merges: the offer does not name the count 10" ;; esac
case "$OUT" in *"hmd badge"*) ok "10 merges: the offer names the command (hmd badge)" ;;
  *) bad "10 merges: the offer does not name 'hmd badge'" ;; esac
[ -f "$WS/$STAMP_REL" ] && ok "10 merges: firing persisted a stamp ($STAMP_REL)" \
                        || bad "10 merges: the offer fired but persisted NOTHING — it will repeat"

# ── 3) ONCE MEANS ONCE — re-render the SAME workspace, offer must be gone ─────
OUT2="$(render "$WS")"; RC=$?
[ "$RC" = 0 ] && ok "repeat: render exits 0" || bad "repeat: render exited $RC"
if has_offer "$OUT2"; then bad "repeat: THE OFFER FIRED TWICE — a repeating nudge gets muted"
else ok "repeat: silent on the second render (once means once)"; fi
OUT3="$(render "$WS")"
if has_offer "$OUT3"; then bad "repeat: the offer returned on a third render"
else ok "repeat: still silent on a third render"; fi
# The stamp must record WHAT fired, not merely that something did.
case "$(cat "$WS/$STAMP_REL" 2>/dev/null)" in
  *'"count"'*10*) ok "repeat: the stamp records the count that triggered it" ;;
  *) bad "repeat: the stamp does not record the triggering count" ;;
esac
rm -rf "$(dirname "$WS")"

# ── 4) ELEVEN, no stamp -> SILENT (the threshold is the 10th, exactly) ────────
WS="$(mktemp -d)/repo"; seed_ws "$WS" 11
OUT="$(render "$WS")"; RC=$?
[ "$RC" = 0 ] && ok "11 merges: render exits 0" || bad "11 merges: render exited $RC"
if has_offer "$OUT"; then bad "11 merges: the offer fired LATE (at the 11th, unstamped)"
else ok "11 merges (unstamped): silent — the threshold is exact"; fi
rm -rf "$(dirname "$WS")"

# ── 5) ELEVEN, already stamped -> SILENT (the once-guard also holds) ─────────
WS="$(mktemp -d)/repo"; seed_ws "$WS" 11
printf '{"count":10,"epoch":1000}\n' > "$WS/$STAMP_REL"
OUT="$(render "$WS")"
if has_offer "$OUT"; then bad "11 merges (stamped): the offer fired despite an existing stamp"
else ok "11 merges (stamped): silent — the once-guard holds"; fi
rm -rf "$(dirname "$WS")"

# ── 6) NO beats.log at all -> SILENT, render still healthy ───────────────────
WS="$(mktemp -d)/repo"; mkdir -p "$WS/.heimdall"
OUT="$(render "$WS")"; RC=$?
[ "$RC" = 0 ] && ok "no beats: render exits 0" || bad "no beats: render exited $RC"
if has_offer "$OUT"; then bad "no beats: an offer fired with no gate history at all"
else ok "no beats: silent (nothing proven, nothing to offer)"; fi
[ -n "$OUT" ] && ok "no beats: the HUD still renders a line" || bad "no beats: the HUD rendered BLANK"
rm -rf "$(dirname "$WS")"

# ── 7) CORRUPT beats.log -> SILENT, never breaks the bar ─────────────────────
WS="$(mktemp -d)/repo"; mkdir -p "$WS/.heimdall/receipts"
printf 'not a beats line at all <<<\x00\xff\n\n\n' > "$WS/.heimdall/receipts/beats.log"
OUT="$(render "$WS")"; RC=$?
[ "$RC" = 0 ] && ok "corrupt beats: render exits 0 (fail-safe)" || bad "corrupt beats: render exited $RC"
if has_offer "$OUT"; then bad "corrupt beats: an offer fired off unparseable history"
else ok "corrupt beats: silent off unparseable history"; fi
[ -n "$OUT" ] && ok "corrupt beats: the HUD still renders a line" || bad "corrupt beats: the HUD rendered BLANK"
rm -rf "$(dirname "$WS")"

# ── 8) FAIL-CLOSED: cannot persist the stamp -> do NOT show the offer ────────
# An offer we cannot record is an offer that repeats forever. Read-only .heimdall.
WS="$(mktemp -d)/repo"; seed_ws "$WS" 10
chmod a-w "$WS/.heimdall"
OUT="$(render "$WS")"; RC=$?
chmod u+w "$WS/.heimdall"
[ "$RC" = 0 ] && ok "unwritable: render exits 0" || bad "unwritable: render exited $RC"
if has_offer "$OUT"; then bad "unwritable: the offer showed but could not be recorded — it WILL repeat"
else ok "unwritable: silent when the stamp cannot be persisted (fail-closed)"; fi
rm -rf "$(dirname "$WS")"

# ── 9) The trigger agrees with `hmd badge --count` — one source of truth ─────
# If the HUD's number and the badge's number could drift, the offer would advertise
# a figure the badge then contradicts.
WS="$(mktemp -d)/repo"; seed_ws "$WS" 10
BC="$(cd "$WS" && "$BADGE" --count 2>/dev/null)"
[ "$BC" = "10" ] && ok "source of truth: hmd badge --count reads 10 from the same beats.log" \
                 || bad "source of truth: hmd badge --count read '$BC', expected 10"
rm -rf "$(dirname "$WS")"

# ── 10) ZERO-SUBPROCESS: the trigger is a pure local read ────────────────────
# Same falsifier shape as heimdall-statusline-update-notice.test.sh case 6: remove
# every process-spawning primitive from reach, then call the notice. A shell-out
# would raise, be swallowed by the fail-safe, and return '' -> RED.
WS="$(mktemp -d)/repo"; seed_ws "$WS" 10
NOTE="$(python3 - "$SL" "$WS" <<'PY' 2>/dev/null
import importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("sl", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def _boom(*a, **k): raise AssertionError("subprocess on the render path")
subprocess.Popen = _boom; subprocess.run = _boom; subprocess.check_output = _boom
os.system = _boom; os.popen = _boom; os.fork = _boom
if hasattr(os, "posix_spawn"): os.posix_spawn = _boom
print(m.badge_offer_notice(sys.argv[2]))
PY
)"
case "$NOTE" in *"hmd badge"*) ok "zero-subprocess: badge_offer_notice() is a pure local read" ;;
  *) bad "zero-subprocess: the trigger shelled out or read nothing (got: '$NOTE')" ;; esac
rm -rf "$(dirname "$WS")"

# ── 11) LATENCY BUDGET: the trigger must be cheap enough to run inline ───────
# Measured as wall-clock for 200 calls in the pre-threshold state (the state EVERY
# render of a normal repo is in: stamp absent, beats present, count != 10 — the path
# that actually reads the file). Ceiling 200ms/200 calls = 1ms per render.
WS="$(mktemp -d)/repo"; seed_ws "$WS" 250
MS="$(python3 - "$SL" "$WS" <<'PY' 2>/dev/null
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("sl", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t0 = time.time()
for _ in range(200):
    m.badge_offer_notice(sys.argv[2])
print(int((time.time() - t0) * 1000))
PY
)"
case "$MS" in ''|*[!0-9]*) bad "latency: could not measure (got '$MS')" ;;
  *) if [ "$MS" -le 200 ]; then
       ok "latency: 200 calls in ${MS}ms (<=200ms budget, $(( MS * 1000 / 200 ))us per render)"
     else
       bad "latency: 200 calls took ${MS}ms — too slow for the inline render path"
     fi ;;
esac
rm -rf "$(dirname "$WS")"

# ── 12) THE BADGE ITSELF RENDERS — markdown + offline SVG fallback ───────────
# The offer is worthless if what it points at does not produce a pasteable badge.
WS="$(mktemp -d)/repo"; seed_ws "$WS" 10
MD="$(cd "$WS" && "$BADGE" --markdown 2>/dev/null)"
case "$MD" in '[!['*'](http'*')](http'*')') ok "badge: --markdown emits a linked-image snippet" ;;
  *) bad "badge: --markdown is not a linked image snippet (got: $MD)" ;; esac
case "$MD" in *"10 proven merges"*) ok "badge: the markdown carries the real count" ;;
  *) bad "badge: the markdown does not carry the count" ;; esac
case "$MD" in *"runheimdall.dev"*) ok "badge: the markdown carries the backlink" ;;
  *) bad "badge: the markdown carries no backlink" ;; esac

SVG="$(cd "$WS" && "$BADGE" --svg 2>/dev/null)"
case "$SVG" in '<svg '*'</svg>') ok "badge: --svg static fallback is a well-formed SVG element" ;;
  *) bad "badge: --svg is not a well-formed SVG" ;; esac
case "$SVG" in *"10 proven merges"*) ok "badge: the offline SVG renders the real count" ;;
  *) bad "badge: the offline SVG does not render the count" ;; esac
# The offline fallback must be exactly that: no network reference anywhere in it.
case "$SVG" in *"shields.io"*) bad "badge: the 'offline-safe' SVG references shields.io" ;;
  *) ok "badge: the offline SVG makes no shields.io round-trip" ;; esac
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$SVG" | python3 -c 'import sys,xml.dom.minidom as d; d.parseString(sys.stdin.read())' 2>/dev/null; then
    ok "badge: the offline SVG parses as XML"
  else
    bad "badge: the offline SVG does NOT parse as XML"
  fi
fi
rm -rf "$(dirname "$WS")"

# ── 13) ATTRIBUTION: the badge URLs carry the ref param ─────────────────────
# The ref rides the BADGE only. test/clip-share-artifact.test.sh holds the other
# wall: heimdall-clip must NOT gain one, because launch-docs/assets/wall.svg is a
# byte-for-byte receipt of clip's output and any injected param breaks it.
WS="$(mktemp -d)/repo"; seed_ws "$WS" 10
JSON="$(cd "$WS" && "$BADGE" --json 2>/dev/null)"
case "$JSON" in *'"endpoint":"https://runheimdall.dev/badge/'*'?ref=badge"'*)
    ok "attribution: the badge endpoint carries ?ref=badge" ;;
  *) bad "attribution: the badge endpoint carries no ref param" ;; esac
case "$JSON" in *'"backlink":"https://runheimdall.dev?ref=badge"'*)
    ok "attribution: the badge backlink carries ?ref=badge" ;;
  *) bad "attribution: the badge backlink carries no ref param" ;; esac
MD="$(cd "$WS" && "$BADGE" --markdown 2>/dev/null)"
case "$MD" in *"?ref=badge"*) ok "attribution: the pasted markdown carries the ref" ;;
  *) bad "attribution: the pasted markdown drops the ref" ;; esac
if printf '%s' "$JSON" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ok "badge: --json is valid JSON"
else
  bad "badge: --json is NOT valid JSON"
fi
rm -rf "$(dirname "$WS")"

echo "--------------------------------------------------------------------"
printf 'badge-auto-offer: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
