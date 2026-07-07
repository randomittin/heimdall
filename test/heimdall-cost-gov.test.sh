#!/usr/bin/env bash
# heimdall-cost-gov.test.sh — THE COST-GOVERNANCE FALSIFIER SUITE (cost-governance §0–§4).
#
# WHAT THIS GATES. The $10k/mo budget buys ONLY orchestration (Firestore ops + Cloud Run
# request handling) — Heimdall NEVER pays for inference (BYO everywhere). This suite proves the
# governance that keeps that true and un-abusable, EACH section with its falsifiable opposite:
#
#   1. GET /config  — the public unsigned tuning read returns {beat_interval_s, refresh_interval_s,
#      ttl_s, tier, backoff_reason?}. (cp_config.config_route)
#   2. LADDER TRANSITIONS — synthetic spend-pace 40/60/80/95% -> 20/15, 30/30, 60/60, 120/120,
#      with an OWNER ALERT flagged only at >90%. Drive the ladder setter directly + the brake
#      chain's upward-crossing alert. FALSIFIER: a pace BELOW a tier floor does NOT enter it.
#   3. CLIENT CLAMP — /config beat=5 or 9999 -> the client clamps to [15,300]. FALSIFIER: the
#      UNCLAMPED raw value (5 / 9999) passes -> proving the clamp is load-bearing.
#   4. ANOMALY COALESCING — a >50×-median writer (over the absolute floor) is ACCEPTED but
#      COALESCED to the ladder max (not dropped), its cohort MARKED; persistently flagged 3 days
#      -> enrollment FROZEN (existing members keep working, a NET-NEW enroll is refused).
#      FALSIFIER both directions: at 10×median / under the floor it is NOT flagged, NOT coalesced.
#   5. REGISTRY HYGIENE — a 60-day-zero-beat identity is EVICTED; an active one is KEPT; an owner
#      is NEVER evicted; a no-signal legacy binding is grandfathered (kept). (cp_registry_hygiene)
#   6. FREE-TIER DISPATCH QUOTA — the per-team/day dispatch ceiling (cp_daily_budget) allows N
#      then REFUSES; a different team is independent; the UTC-day rollover resets it.
#   7. §0 / HARD CAP — the brake chain's dead-man's-brake (billing kill-switch) exists end-to-end:
#      the daily job reports kill_switch_armed at >=100% of the $10k budget and NOT below; the
#      §0 invariant holds — no cost-gov server module constructs a model-inference client.
#
# DISCIPLINE (mirrors cp-ratelimit / cp-presence): an isolated throwaway home + the LOCAL backend,
# every check deterministic with an injected `now`. ZERO real GCP / ZERO spend. Exit 0 = every
# proof (and every falsifier) holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_config cp_anomaly cp_cost_model cp_costjob cp_daily_budget cp_registry_hygiene \
         cp_auth cp_presence cp_state; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "cost-gov.XXXXXX")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

# A helper: extract a field from a JSON blob on stdin.
jget() { "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

echo "============================================================"
echo "COST GOVERNANCE — the \$10k-budget self-heal + abuse throttles (LOCAL backend)"
echo "============================================================"
echo

# ──────────────────────────────────────────────────────────────────────────────
# §1–§3 + §7: the interval ladder, the /config route, the client clamp, the brake chain.
# ──────────────────────────────────────────────────────────────────────────────
LAD_OUT="$(env HEIMDALL_STATE_BACKEND=local HEIMDALL_HOME="$HOME_T" HOME_T="$HOME_T" \
  "$PY" - <<'PYEOF' 2>"$EXT/lad.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_config as C, cp_costjob as J
home = os.environ["HOME_T"]
out = {}

# §1. GET /config returns the closed tuning body.
C.set_ladder(80, home=home)
resp = C.config_route({"query": {}}, home=home)
out["cfg_status"] = resp.status
out["cfg_keys"] = sorted(resp.body.keys())
out["cfg_cache"] = resp.headers.get("Cache-Control")
out["cfg_beat"] = resp.body.get("beat_interval_s")
out["cfg_refresh"] = resp.body.get("refresh_interval_s")

# §2. LADDER TRANSITIONS on synthetic spend-pace. 40->tier0(20/15), 60->tier1(30/30),
#     80->tier2(60/60), 95->tier3(120/120)+owner_alert.
ladder = {}
for pct in (40, 60, 80, 95):
    r = C.set_ladder(pct, home=home)
    ladder[str(pct)] = [r["beat_interval_s"], r["refresh_interval_s"],
                        bool(r["owner_alert"]), r["ttl_s"]]
out["ladder"] = ladder

# §2 FALSIFIER: a pace BELOW a floor does NOT enter the higher tier (49% stays tier0 not tier1).
out["falsi_49_below_50"] = C.set_ladder(49, home=home)["beat_interval_s"]   # expect 20 (tier0)
out["falsi_50_at_floor"] = C.set_ladder(50, home=home)["beat_interval_s"]   # expect 30 (tier1)

# §2 brake chain: an UPWARD crossing into tier3 fires the owner alert (crossed_up + alert_fired).
C.set_ladder(0, home=home)                                                   # reset to tier0
res = J.run_daily(daily_usd=1000.0, home=home, notify_owner=True)            # 1000*30+50 -> 300%
out["brake_crossed_up"] = res["crossed_up"]
out["brake_alert_fired"] = res["alert_fired"]
out["brake_new_tier"] = res["new_tier"]

# §3. CLIENT CLAMP to [15,300]. A spoofed beat 5 clamps to 15; 9999 clamps to 300; in-band 60
#     is unchanged. The FALSIFIER is the UNCLAMPED raw value (5 / 9999) — it must DIFFER from the
#     clamped result, proving the clamp is load-bearing (drop the min()/max() and 5/9999 pass).
out["clamp_5"] = C.clamp_interval(5)          # expect 15
out["clamp_9999"] = C.clamp_interval(9999)    # expect 300
out["clamp_60"] = C.clamp_interval(60)        # expect 60 (in-band, inert)
out["clamp_raw_5"] = 5                         # the unclamped value a missing clamp would pass
out["clamp_raw_9999"] = 9999

# §7. HARD CAP / dead-mans brake exists end-to-end: armed at >=100% of the $10k budget, NOT below.
out["ks_budget"] = J.kill_switch_budget_usd()
out["ks_armed_150"] = J.kill_switch_armed(150)
out["ks_armed_50"] = J.kill_switch_armed(50)
out["ks_run_armed"] = res["kill_switch_armed"]        # the 300% run above must be armed
out["ks_run_pct"] = res["spend_pace_pct"]

print(json.dumps(out))
PYEOF
)"
# The §7 hard-cap run drives a DELIBERATE 300% synthetic spend; run_daily emits ONE expected
# operational "HARD CAP REACHED" diagnostic to stderr (Cloud Run captures it — the same status is
# also in the returned dict, asserted below). Filter that one expected line; ANY OTHER stderr (a
# traceback, an import error) is still a real failure.
grep -v "HARD CAP REACHED" "$EXT/lad.err" > "$EXT/lad.err.resid" 2>/dev/null || true
[ -s "$EXT/lad.err.resid" ] && { bad "§1–3/7 raised on stderr"; sed 's/^/    /' "$EXT/lad.err.resid" >&2; }
lget() { printf '%s' "$LAD_OUT" | jget "$1"; }

echo "§1. GET /config — the public unsigned tuning read"
[ "$(lget "['cfg_status']")" = "200" ] \
  && ok "§1 /config returns 200" || bad "§1 /config status (out=$LAD_OUT)"
CK="$(lget "['cfg_keys']")"
case "$CK" in
  *"'beat_interval_s'"*|*'"beat_interval_s"'*) HAS_BEAT=1 ;; *) HAS_BEAT= ;;
esac
{ printf '%s' "$CK" | grep -q "beat_interval_s" && printf '%s' "$CK" | grep -q "refresh_interval_s"; } \
  && ok "§1 body carries {beat_interval_s, refresh_interval_s, ...} (keys=$CK)" \
  || bad "§1 body missing beat/refresh keys (keys=$CK)"
[ "$(lget "['cfg_cache']")" != "None" ] && [ -n "$(lget "['cfg_cache']")" ] \
  && ok "§1 /config carries a Cache-Control header (clients+CDN cache it)" \
  || bad "§1 /config missing Cache-Control"

echo
echo "§2. LADDER TRANSITIONS on synthetic spend-pace (+ owner alert >90%)"
[ "$(lget "['ladder']['40']")" = "[20, 15, False, 45]" ] \
  && ok "§2 40% -> 20/15 (tier0 defaults, ttl 45, no alert)" \
  || bad "§2 40% tier wrong (got $(lget "['ladder']['40']"))"
[ "$(lget "['ladder']['60']")" = "[30, 30, False, 90]" ] \
  && ok "§2 60% -> 30/30 (tier1, ttl 90 rises with the ladder)" \
  || bad "§2 60% tier wrong (got $(lget "['ladder']['60']"))"
[ "$(lget "['ladder']['80']")" = "[60, 60, False, 135]" ] \
  && ok "§2 80% -> 60/60 (tier2, ttl 135)" \
  || bad "§2 80% tier wrong (got $(lget "['ladder']['80']"))"
[ "$(lget "['ladder']['95']")" = "[120, 120, True, 270]" ] \
  && ok "§2 95% -> 120/120 (tier3, ttl 270) + OWNER ALERT flagged" \
  || bad "§2 95% tier wrong (got $(lget "['ladder']['95']"))"
[ "$(lget "['falsi_49_below_50']")" = "20" ] && [ "$(lget "['falsi_50_at_floor']")" = "30" ] \
  && ok "§2 FALSIFIER: 49% stays tier0 (20), 50% enters tier1 (30) — the floor is inclusive + load-bearing" \
  || bad "§2 FALSIFIER: the tier floor did not gate correctly (49=$(lget "['falsi_49_below_50']") 50=$(lget "['falsi_50_at_floor']"))"
{ [ "$(lget "['brake_crossed_up']")" = "True" ] && [ "$(lget "['brake_alert_fired']")" = "True" ] \
  && [ "$(lget "['brake_new_tier']")" = "3" ]; } \
  && ok "§2 the brake chain fires the OWNER ALERT on an upward crossing into tier3 (>90%)" \
  || bad "§2 the brake-chain upward-crossing alert did not fire (out=$LAD_OUT)"

echo
echo "§3. CLIENT CLAMP to [15s,300s] (a spoofed/broken /config can't DoS the client)"
[ "$(lget "['clamp_5']")" = "15" ] && [ "$(lget "['clamp_9999']")" = "300" ] \
  && ok "§3 a spoofed beat 5 clamps to 15, 9999 clamps to 300" \
  || bad "§3 clamp did not bound to [15,300] (5=$(lget "['clamp_5']") 9999=$(lget "['clamp_9999']"))"
[ "$(lget "['clamp_60']")" = "60" ] \
  && ok "§3 an in-band 60 is unchanged (the clamp is inert on honest values)" \
  || bad "§3 clamp altered an in-band value (60=$(lget "['clamp_60']"))"
{ [ "$(lget "['clamp_raw_5']")" != "$(lget "['clamp_5']")" ] \
  && [ "$(lget "['clamp_raw_9999']")" != "$(lget "['clamp_9999']")" ]; } \
  && ok "§3 FALSIFIER: the UNCLAMPED raw 5/9999 differ from the clamped 15/300 — the clamp is load-bearing (drop it and 5/9999 pass -> RED)" \
  || bad "§3 FALSIFIER: raw == clamped, the clamp is a no-op (out=$LAD_OUT)"

echo
echo "§7. §0 HARD CAP — the dead-man's-brake (billing kill-switch) exists end-to-end"
[ "$(lget "['ks_budget']")" = "10000.0" ] \
  && ok "§7 the software brake budget aligns to the \$10k cap (kill_switch_budget_usd == 10000)" \
  || bad "§7 kill-switch budget != 10000 (got $(lget "['ks_budget']"))"
[ "$(lget "['ks_armed_150']")" = "True" ] && [ "$(lget "['ks_armed_50']")" = "False" ] \
  && ok "§7 the kill-switch is ARMED at >=100% of budget and NOT below (150->armed, 50->not)" \
  || bad "§7 kill-switch arming threshold wrong (150=$(lget "['ks_armed_150']") 50=$(lget "['ks_armed_50']"))"
[ "$(lget "['ks_run_armed']")" = "True" ] \
  && ok "§7 a daily run projecting $(lget "['ks_run_pct']")% of budget reports the dead-man's brake ARMED (chain: measure->ladder->alert->kill-switch)" \
  || bad "§7 the daily run at >100% did not report the kill-switch armed (out=$LAD_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# §4. ANOMALY COALESCING — >50×-median writer accepted+coalesced+marked; 3 days -> enroll frozen.
#     FALSIFIER both directions: at 10×median / under the floor -> NOT flagged, NOT coalesced.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "§4. ANOMALY COALESCING + 3-day enrollment FREEZE (write-flood throttle)"
ANO_OUT="$(env HEIMDALL_STATE_BACKEND=local HEIMDALL_HOME="$EXT/anom" \
  "$PY" - <<'PYEOF' 2>"$EXT/anom.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_anomaly as A, cp_config as C
home = os.environ["HEIMDALL_HOME"]
DAY = 86400
now = 1_000_000_000.0
out = {}

# Seed a peer baseline: 5 cohorts @100 writes/day -> median 100, so the 50× threshold is 5000
# (which also clears the absolute 5000 floor). A flooder at 6000 is over BOTH bars.
for i in range(5):
    A.record_write(A.KIND_TEAM, "peer%d" % i, amount=100, now=now, home=home)
A.record_write(A.KIND_TEAM, "flood", amount=6000, now=now, home=home)
out["median"] = A.median_daily_writes(A.KIND_TEAM, now=now, home=home)
anomalous, count, median, threshold = A.is_anomalous(A.KIND_TEAM, "flood", now=now, home=home)
out["flood_anomalous"] = anomalous
d = A.evaluate(A.KIND_TEAM, "flood", now=now, home=home, notify=False)
out["flood_coalesced"] = d["coalesced"]
out["flood_marked"] = d["marked"]
# The flooder is ACCEPTED but COALESCED to the ladder MAX — its /config now serves 120/120.
eff = C.effective_config("flood", home=home)
out["flood_eff_beat"] = eff["beat_interval_s"]
out["flood_eff_reason"] = eff.get("backoff_reason")
out["coalesce_tier_beat"] = C.tier_by_index(C.COALESCE_TIER)["beat_interval_s"]

# FALSIFIER a) UNDER the floor: 10×median (1000) is < the 5000 absolute floor -> NOT anomalous.
A.record_write(A.KIND_TEAM, "small", amount=1000, now=now, home=home)
sa = A.is_anomalous(A.KIND_TEAM, "small", now=now, home=home)[0]
sd = A.evaluate(A.KIND_TEAM, "small", now=now, home=home, notify=False)
out["small_anomalous"] = sa
out["small_coalesced"] = sd["coalesced"]
out["small_marked"] = sd["marked"]
out["small_eff_beat"] = C.effective_config("small", home=home)["beat_interval_s"]  # global tier0 = 20

# FALSIFIER b) OVER the floor but only 10×median (not >50×): seed a fresh day where the median is
# high enough that a 6000 writer is <=50×. peers @200 -> median 200, 50×=10000; a 6000 writer is
# over the 5000 floor yet UNDER the 10000 threshold -> NOT anomalous (the multiple gate, not just
# the floor).
day2 = now + DAY
for i in range(5):
    A.record_write(A.KIND_TEAM, "hp%d" % i, amount=200, now=day2, home=home)
A.record_write(A.KIND_TEAM, "midflood", amount=6000, now=day2, home=home)
mf = A.is_anomalous(A.KIND_TEAM, "midflood", now=day2, home=home)
out["mid_median"] = mf[2]
out["mid_threshold"] = mf[3]
out["mid_anomalous"] = mf[0]

# 3-DAY FREEZE: a cohort flagged 3 CONSECUTIVE days has its enrollment frozen. Seed peers each day
# so the median stays low and the flooder stays anomalous; evaluate once per day.
fh = os.path.join(home, "..", "freeze")
for dd in range(3):
    n = now + dd * DAY
    for i in range(5):
        A.record_write(A.KIND_TEAM, "fp%d" % i, amount=100, now=n, home=fh)
    A.record_write(A.KIND_TEAM, "persist", amount=6000, now=n, home=fh)
    r = A.evaluate(A.KIND_TEAM, "persist", now=n, home=fh, notify=False)
    out["freeze_day%d_consec" % dd] = r["consecutive_days"]
    out["freeze_day%d_frozen" % dd] = r["frozen"]
out["is_frozen"] = A.is_frozen("persist", home=fh)
# Reversibility: clear_mark releases the freeze AND the coalesce override.
out["cleared"] = A.clear_mark(A.KIND_TEAM, "persist", home=fh)
out["is_frozen_after_clear"] = A.is_frozen("persist", home=fh)

print(json.dumps(out))
PYEOF
)"
[ -s "$EXT/anom.err" ] && { bad "§4 raised on stderr"; sed 's/^/    /' "$EXT/anom.err" >&2; }
aget() { printf '%s' "$ANO_OUT" | jget "$1"; }

[ "$(aget "['flood_anomalous']")" = "True" ] \
  && ok "§4 a >50×-median writer over the absolute floor IS flagged anomalous" \
  || bad "§4 the flooder was not flagged (out=$ANO_OUT)"
{ [ "$(aget "['flood_coalesced']")" = "True" ] && [ "$(aget "['flood_marked']")" = "True" ]; } \
  && ok "§4 the flooder is ACCEPTED but COALESCED (cohort pinned to ladder max) + MARKED — not dropped" \
  || bad "§4 the flooder was not coalesced+marked (out=$ANO_OUT)"
{ [ "$(aget "['flood_eff_beat']")" = "$(aget "['coalesce_tier_beat']")" ] \
  && [ "$(aget "['flood_eff_reason']")" = "coalesced" ]; } \
  && ok "§4 the coalesced cohort's /config now serves the ladder-max beat ($(aget "['flood_eff_beat']")s, reason=coalesced)" \
  || bad "§4 the cohort override did not pin the ladder max (out=$ANO_OUT)"
{ [ "$(aget "['small_anomalous']")" = "False" ] && [ "$(aget "['small_coalesced']")" = "False" ] \
  && [ "$(aget "['small_marked']")" = "False" ] && [ "$(aget "['small_eff_beat']")" = "20" ]; } \
  && ok "§4 FALSIFIER (under the floor): a 10×-median/under-floor cohort is NOT flagged, NOT coalesced, stays on the global tier0 (20s)" \
  || bad "§4 FALSIFIER: an under-floor cohort was wrongly throttled (out=$ANO_OUT)"
[ "$(aget "['mid_anomalous']")" = "False" ] \
  && ok "§4 FALSIFIER (over floor, under 50×): a 6000 writer at median $(aget "['mid_median']") (threshold $(aget "['mid_threshold']")) is NOT flagged — the multiple gate, not just the floor" \
  || bad "§4 FALSIFIER: a sub-50× writer over the floor was wrongly flagged (out=$ANO_OUT)"
{ [ "$(aget "['freeze_day0_frozen']")" = "False" ] && [ "$(aget "['freeze_day1_frozen']")" = "False" ] \
  && [ "$(aget "['freeze_day2_frozen']")" = "True" ] && [ "$(aget "['freeze_day2_consec']")" = "3" ]; } \
  && ok "§4 3 CONSECUTIVE flagged days -> enrollment FROZEN (day0/1 not frozen, day2 frozen at consec=3)" \
  || bad "§4 the 3-day freeze did not trip correctly (out=$ANO_OUT)"
[ "$(aget "['is_frozen']")" = "True" ] \
  && ok "§4 is_frozen(team) True after the 3-day run (cp_enroll refuses a NET-NEW member)" \
  || bad "§4 is_frozen did not report frozen (out=$ANO_OUT)"
{ [ "$(aget "['cleared']")" = "True" ] && [ "$(aget "['is_frozen_after_clear']")" = "False" ]; } \
  && ok "§4 REVERSIBLE: clear_mark releases the freeze + the coalesce override (all throttles reversible)" \
  || bad "§4 the throttle was not reversible (out=$ANO_OUT)"

# The FREEZE-GATE on real enrollment: a frozen team refuses a NET-NEW enroll while an EXISTING
# member (same-key idempotent re-enroll) still works — the "existing members keep working" invariant.
echo
echo "§4b. enrollment FREEZE gate — net-new refused, existing member kept"
ENR_OUT="$(env HEIMDALL_STATE_BACKEND=local HEIMDALL_HOME="$EXT/enr" HEIMDALL_ENROLL_TOKEN="tok-costgov" \
  "$PY" - <<'PYEOF' 2>"$EXT/enr.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_enroll, cp_anomaly as A
home = os.environ["HEIMDALL_HOME"]
out = {}
# A real team_secret is a high-entropy bearer capability >= TEAM_SECRET_MIN_LEN (32 chars); a
# shorter one is refused team_secret_weak (422). Use a 32+ char secret so the enroll gate is the
# FREEZE under test here, not the secret-strength gate.
secret = "team-secret-costgov-abuse-proofing-01"
team_id = cp_auth.derive_team_id(secret)

# An EXISTING member enrolls BEFORE the freeze.
seed, pub = cp_auth.generate_keypair()
haid_existing = "haid:existing-member"
r0 = cp_enroll.enroll(haid_existing, pub, provided_token="tok-costgov",
                      team_secret=secret, home=home)
out["existing_enrolled"] = r0.get("ok")

# Freeze the team (write the frozen mark directly — the state the 3-day run produces).
A._backend(home).put_record(
    A._mark_rel(A.KIND_TEAM, team_id),
    {"kind": "team", "marked": True, "frozen": True, "consecutive_flag_days": 3,
     "reason": "write_flood", "last_flag_day": 0, "first_flag_day": 0})
out["is_frozen"] = A.is_frozen(team_id, home=home)

# A NET-NEW member is REFUSED (team_frozen); the EXISTING members idempotent re-enroll still works.
seed2, pub2 = cp_auth.generate_keypair()
r_new = cp_enroll.enroll("haid:new-member", pub2, provided_token="tok-costgov",
                         team_secret=secret, home=home)
out["new_ok"] = r_new.get("ok")
out["new_reason"] = r_new.get("reason")
r_existing = cp_enroll.enroll(haid_existing, pub, provided_token="tok-costgov",
                             team_secret=secret, home=home)
out["existing_still_ok"] = r_existing.get("ok")
print(json.dumps(out))
PYEOF
)"
[ -s "$EXT/enr.err" ] && { bad "§4b raised on stderr"; sed 's/^/    /' "$EXT/enr.err" >&2; }
eget() { printf '%s' "$ENR_OUT" | jget "$1"; }
{ [ "$(eget "['existing_enrolled']")" = "True" ] && [ "$(eget "['is_frozen']")" = "True" ]; } \
  && ok "§4b setup: an existing member enrolled, then the team was frozen" \
  || bad "§4b setup failed (out=$ENR_OUT)"
{ [ "$(eget "['new_ok']")" = "False" ] && [ "$(eget "['new_reason']")" = "team_frozen" ]; } \
  && ok "§4b a NET-NEW enroll into a frozen team is REFUSED (reason team_frozen)" \
  || bad "§4b a net-new enroll into a frozen team was not refused (out=$ENR_OUT)"
[ "$(eget "['existing_still_ok']")" = "True" ] \
  && ok "§4b an EXISTING member (idempotent re-enroll) STILL WORKS — the freeze bounds only net-new growth" \
  || bad "§4b an existing member was wrongly blocked by the freeze (out=$ENR_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# §5. REGISTRY HYGIENE — 60-day-zero-beat evicted; active kept; owner kept; no-signal grandfathered.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "§5. REGISTRY HYGIENE — TTL-eviction of zero-beat identities (bounded growth forever)"
HYG_OUT="$(env HEIMDALL_STATE_BACKEND=local HEIMDALL_HOME="$EXT/hyg" \
  "$PY" - <<'PYEOF' 2>"$EXT/hyg.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth, cp_presence, cp_registry_hygiene as H
home = os.environ["HEIMDALL_HOME"]
DAY = 86400
now = 1_000_000_000.0
out = {}

# Five bindings: an owner, an active beater, a stale beater (61d old beat), a never-beat old
# enroll (61d), a never-beat recent enroll (5d), and a legacy no-signal binding.
cp_auth.register_key("haid:owner", "pk-owner", owner=True, home=home)
for h in ("haid:active", "haid:stale", "haid:nb_old", "haid:nb_new", "haid:legacy"):
    cp_auth.register_key(h, "pk-%s" % h, owner=False, home=home)
reg = cp_auth._load_keys(home)
reg["keys"]["haid:nb_old"]["enrolled_at"] = int(now - 61 * DAY)
reg["keys"]["haid:nb_new"]["enrolled_at"] = int(now - 5 * DAY)
# haid:legacy has NO enrolled_at and NO presence -> a grandfathered no-signal binding.
cp_auth._store_keys(reg, home)
# Presence beats: active now, stale 61 days ago.
cp_presence.record_presence("haid:active", project="p", team_id="t1", ts=now, home=home)
cp_presence.record_presence("haid:stale", project="p", team_id="t1", ts=now - 61 * DAY, home=home)

plan = H.plan_eviction(now=now, home=home)
out["plan_evict"] = plan["evict"]
out["plan_keep_active"] = plan["keep_active"]
out["plan_keep_owner"] = plan["keep_owner"]
out["plan_grandfathered"] = plan["keep_grandfathered"]

# Apply it; the stale + never-beat-old are removed, everything else survives.
res = H.evict_stale(now=now, home=home, apply=True)
out["evicted"] = res["evicted"]
out["registry_after"] = sorted(cp_auth._load_keys(home)["keys"].keys())

# FALSIFIER: a DRY RUN removes NOTHING (apply=False), even with a stale binding present.
reg2 = cp_auth._load_keys(home)
reg2["keys"]["haid:stale2"] = {"pubkey": "pk", "owner": False, "enrolled_at": int(now - 90 * DAY)}
cp_auth._store_keys(reg2, home)
dry = H.evict_stale(now=now, home=home, apply=False)
out["dry_evict_planned"] = dry["evict"]
out["dry_evicted"] = dry["evicted"]
out["dry_still_present"] = "haid:stale2" in cp_auth._load_keys(home)["keys"]

print(json.dumps(out))
PYEOF
)"
[ -s "$EXT/hyg.err" ] && { bad "§5 raised on stderr"; sed 's/^/    /' "$EXT/hyg.err" >&2; }
hget() { printf '%s' "$HYG_OUT" | jget "$1"; }
[ "$(hget "['evicted']")" = "['haid:nb_old', 'haid:stale']" ] \
  && ok "§5 a 60-day-zero-beat identity (stale beat + never-beat-old enroll) is EVICTED" \
  || bad "§5 the wrong set was evicted (got $(hget "['evicted']"))"
{ printf '%s' "$HYG_OUT" | jget "['registry_after']" | grep -q "haid:active" \
  && printf '%s' "$HYG_OUT" | jget "['registry_after']" | grep -q "haid:owner" \
  && printf '%s' "$HYG_OUT" | jget "['registry_after']" | grep -q "haid:nb_new" \
  && printf '%s' "$HYG_OUT" | jget "['registry_after']" | grep -q "haid:legacy"; } \
  && ok "§5 the ACTIVE beater, the OWNER, the recent enroll, and the no-signal LEGACY binding are all KEPT" \
  || bad "§5 an identity that should survive was evicted (after=$(hget "['registry_after']"))"
{ printf '%s' "$HYG_OUT" | jget "['registry_after']" | grep -qv "haid:stale'" ; } \
  && [ "$(hget "['plan_keep_owner']")" = "['haid:owner']" ] \
  && ok "§5 the owner is classified keep_owner (an owner is NEVER evicted, even if idle)" \
  || bad "§5 owner classification wrong (out=$HYG_OUT)"
[ "$(hget "['plan_grandfathered']")" = "['haid:legacy']" ] \
  && ok "§5 a binding with NO activity signal is GRANDFATHERED (never evicted on the absence of evidence)" \
  || bad "§5 the no-signal binding was not grandfathered (out=$HYG_OUT)"
{ [ "$(hget "['dry_evicted']")" = "[]" ] && [ "$(hget "['dry_still_present']")" = "True" ] \
  && printf '%s' "$HYG_OUT" | jget "['dry_evict_planned']" | grep -q "haid:stale2"; } \
  && ok "§5 FALSIFIER: a DRY RUN (apply=False) PLANS the eviction but removes NOTHING — the stale binding survives" \
  || bad "§5 FALSIFIER: the dry run mutated the registry (out=$HYG_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# §6. FREE-TIER DISPATCH QUOTA — per-team/day dispatch ceiling (cp_daily_budget).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "§6. FREE-TIER DISPATCH QUOTA — the per-team/day ceiling (generous, bounded)"
BUD_OUT="$(env HEIMDALL_STATE_BACKEND=local HEIMDALL_HOME="$EXT/bud" \
  "$PY" - <<'PYEOF' 2>"$EXT/bud.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_daily_budget as B
home = os.environ["HEIMDALL_HOME"]
now = 1_000_000_000.0
bud = B.DailyTeamBudget(home=home)
out = {}

# The generous free-tier ceiling: 50 remote-job dispatches/team/day (spec §3). token_budget is
# effectively unbounded here so the DISPATCH count is the ceiling under test.
DMAX, TBUD = 50, 10 ** 9
firstN = [bud.check_and_consume("teamA", tokens=0, dispatch_max=DMAX, token_budget=TBUD, now=now).ok
          for _ in range(DMAX)]
over = bud.check_and_consume("teamA", tokens=0, dispatch_max=DMAX, token_budget=TBUD, now=now)
out["first50_all_ok"] = all(firstN)
out["n_ok"] = sum(1 for x in firstN if x)
out["over_ok"] = over.ok
out["over_dim"] = over.limit_dim
out["over_retry_after"] = over.retry_after

# A DIFFERENT team is independent (one teams exhaustion never starves another).
out["teamB_ok"] = bud.check_and_consume("teamB", tokens=0, dispatch_max=DMAX,
                                        token_budget=TBUD, now=now).ok

# The UTC-day rollover resets teamAs ceiling (a fresh day is a fresh quota).
out["teamA_next_day_ok"] = bud.check_and_consume(
    "teamA", tokens=0, dispatch_max=DMAX, token_budget=TBUD, now=now + 86400).ok

# FALSIFIER: an explicit zero cap is a hard-closed kill switch — it refuses the FIRST dispatch.
out["zero_cap_first_ok"] = bud.check_and_consume(
    "teamZ", tokens=0, dispatch_max=0, token_budget=TBUD, now=now).ok
print(json.dumps(out))
PYEOF
)"
[ -s "$EXT/bud.err" ] && { bad "§6 raised on stderr"; sed 's/^/    /' "$EXT/bud.err" >&2; }
bget() { printf '%s' "$BUD_OUT" | jget "$1"; }
{ [ "$(bget "['first50_all_ok']")" = "True" ] && [ "$(bget "['n_ok']")" = "50" ]; } \
  && ok "§6 the first 50 dispatches/team/day are ALLOWED (generous free-tier quota)" \
  || bad "§6 the first 50 dispatches did not all pass (out=$BUD_OUT)"
{ [ "$(bget "['over_ok']")" = "False" ] && [ "$(bget "['over_dim']")" = "dispatch" ] \
  && [ "$(bget "['over_retry_after']")" -ge 1 ] 2>/dev/null; } \
  && ok "§6 the 51st is REFUSED (limit_dim=dispatch, retry_after to UTC rollover) — the daily ceiling holds" \
  || bad "§6 the 51st dispatch was not refused correctly (out=$BUD_OUT)"
[ "$(bget "['teamB_ok']")" = "True" ] \
  && ok "§6 a DIFFERENT team is independent (an exhausted team never starves another)" \
  || bad "§6 team independence broke (out=$BUD_OUT)"
[ "$(bget "['teamA_next_day_ok']")" = "True" ] \
  && ok "§6 the UTC-day rollover RESETS the ceiling (a fresh day is a fresh quota)" \
  || bad "§6 the daily rollover did not reset the quota (out=$BUD_OUT)"
[ "$(bget "['zero_cap_first_ok']")" = "False" ] \
  && ok "§6 FALSIFIER: a zero cap is a hard-closed kill switch — it refuses the FIRST dispatch (not fail-open)" \
  || bad "§6 FALSIFIER: a zero cap failed open (out=$BUD_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# §0 INVARIANT — no cost-gov server module constructs a model-inference client (BYO holds).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "§0. INVARIANT — no cost-gov module touches a paid-inference path (BYO everywhere)"
INV="$(REPO="$REPO" "$PY" - <<'PYEOF' 2>/dev/null
import os, re
lib = os.path.join(os.environ["REPO"], "bin", "lib")
mods = ["cp_config.py", "cp_anomaly.py", "cp_cost_model.py", "cp_costjob.py",
        "cp_daily_budget.py", "cp_registry_hygiene.py"]
# A paid-inference client would be an import/construction of a model SDK. NONE may appear.
pat = re.compile(r"\b(import\s+anthropic|from\s+anthropic|import\s+openai|from\s+openai|"
                 r"Anthropic\(|OpenAI\(|genai\.|google\.generativeai)\b")
hits = []
for m in mods:
    p = os.path.join(lib, m)
    if not os.path.isfile(p):
        continue
    for i, line in enumerate(open(p, encoding="utf-8"), 1):
        # Ignore comments/docstrings mentioning inference in prose (only real code constructs).
        code = line.split("#", 1)[0]
        if pat.search(code):
            hits.append("%s:%d" % (m, i))
print(len(hits), ";".join(hits))
PYEOF
)"
INV_N="${INV%% *}"
[ "${INV_N:-1}" = "0" ] \
  && ok "§0 the cost-gov modules construct NO model-inference client — Heimdall never pays for inference (BYO)" \
  || bad "§0 a cost-gov module references a paid-inference client: ${INV#* }"

echo
echo "============================================================"
printf "cost-gov: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
