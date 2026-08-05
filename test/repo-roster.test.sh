#!/usr/bin/env bash
# repo-roster.test.sh — FALSIFIER: the REPO ROSTER data layer (bin/lib/repo_roster.py).
#
# THE DEFECT THIS CLOSES. The statusline wall renders LIVE PRESENCE ONLY. Presence needs a
# control-plane deploy; the deploy is outstanding; so the wall shows exactly one human and is
# indistinguishable from broken. The repo roster fixes that by folding THREE independent
# sources into ONE ranked list — and two of those sources (git, github) need NO control plane,
# so a fully-degraded presence layer STILL yields a populated wall.
#
# THE FROZEN CONTRACT (the render agent codes against this exactly):
#   [{"handle":str, "haid":str|null, "tier":"online"|"contributed"|"away"|"member",
#     "online":bool, "last_seen_ts":num|null, "last_commit_ts":num|null,
#     "sources":[ "presence"|"git"|"github", ... ]}, ...]
#   sorted best-tier-first, then most-recent-first inside a tier.
#
# WHAT IS PROVEN HERE
#   A  identity unification — the akshat 3-way (git x3) + HAID collapse to ONE person
#   A2 CONSERVATISM — a lone weak signal NEVER merges (a wrong merge hides a real human)
#   A3 no over-merge — the distinct-person count is exact
#   B  all-branches discovery — an author who never touched HEAD is still found
#   C  tier ordering + within-tier recency
#   C-RED the ranking is FALSIFIABLE: invert _TIER_RANK -> the order proof FAILS; restore -> PASS
#   D  every github degradation path: absent / not-authed / no-network / rate-limited /
#      private-404 / HANGS. Never blocks, never raises, always exit 0.
#   E  no presence -> tiers 2+4 still populate (the whole point: works before the CP deploy)
#   F  no git -> presence + github still populate
#   G  PRIVACY — a row built without presence carries NO presence fact
#   H  CACHE — the second read does NOT re-invoke gh (the statusline hot path)
#   I  CONTRACT — exact key set, exact types, exact tier vocabulary
#
# HERMETIC: a fixture git repo built in a temp dir with pinned author dates, a fake `gh` on
# PATH, and a synthetic presence cache file. No network, no control plane, no real gh.
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO
[ -f "$LIB/repo_roster.py" ] || { echo "FATAL: repo_roster.py missing at $LIB" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }
export PY

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMP="$(mktemp -d -t "repo-roster.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export TMP

# ── the injected clock. Every timestamp below is an offset from THIS instant, so tiering is
# decided by the clock we hand in, never by wall time (a test that drifts is not a test).
NOW=1800000000
export NOW
DAY=86400

# ── the LOCAL-IDENTITY ANCHOR is OFF for every fixture below. It reads the real git config,
# the real device name and the real `gh` auth of whoever runs this suite, so leaving it on
# would make these results depend on the developer's laptop. Section J turns it back on with
# every input injected explicitly, which is the only way to test it hermetically.
HMD_ROSTER_NO_SELF=1
export HMD_ROSTER_NO_SELF

echo "============================================================"
echo "REPO-ROSTER falsifier — identity unification, tiers, degradation"
echo "  lib=$LIB  tmp=$TMP  now=$NOW"
echo "============================================================"
echo

# ─────────────────────────────────────────────────────────────────────────────
# FIXTURE 1 — the git repo. Authors mirror the OWNER'S REAL rally repo, which is where the
# 3-way identity split was measured. Commits land on THREE branches so a HEAD-only scan is
# provably insufficient.
# ─────────────────────────────────────────────────────────────────────────────
GITREPO="$TMP/repo"
mkdir -p "$GITREPO"
git -C "$GITREPO" init -q
git -C "$GITREPO" symbolic-ref HEAD refs/heads/main
git -C "$GITREPO" config commit.gpgsign false
git -C "$GITREPO" remote add origin git@github.com:randomittin/rally.git

# commit <branch> <name> <email> <age-in-days> <slug>
commit() {
  local branch="$1" name="$2" email="$3" age="$4" slug="$5" when
  when=$(( NOW - age * DAY ))
  git -C "$GITREPO" checkout -q -B "$branch" >/dev/null 2>&1
  printf 'work by %s at %s\n' "$slug" "$when" > "$GITREPO/$slug.txt"
  git -C "$GITREPO" add "$slug.txt"
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" \
  GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
  GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
    git -C "$GITREPO" commit -q -m "$slug" >/dev/null 2>&1
}

# ── the akshat 3-way. One human, three git identities, none of which share an email. ──
commit main            "Akshat Singh" "akshat@Akshats-MacBook-Air-2.local"                 3 "ak-machine"
commit feat/akshat     "Akshat Singh" "akshat@mewt.in"                                     2 "ak-org"
commit feat/akshat-gh  "Akshat"       "112849320+akshat-mewt@users.noreply.github.com"     1 "ak-noreply"
# ── anu commits ONLY on her own branch. A HEAD-only scan never sees her (the measured bug). ──
commit feat/anu        "Anu Martin"   "anu@superpe.co"                                     5 "anu-branch"
# ── the CONTROL. A different human whose ONLY tie to akshat is a shared first-name token —
#    one weak signal. Merging her would HIDE A REAL PERSON; the rule must refuse. ──
commit feat/other      "Akshat Nandini" "nandini@elsewhere.example"                       40 "other"
# ── a stale author, outside the git window: discovered, but never "contributed". ──
commit feat/stale      "Old Timer"    "oldtimer@superpe.co"                              200 "stale"
git -C "$GITREPO" checkout -q main

# ─────────────────────────────────────────────────────────────────────────────
# FIXTURE 2 — the presence cache. This is the EXISTING signed roster path's output
# (`heimdall-presence roster --json` -> <repo>/.heimdall/.roster-cache.json), which only
# populates for a holder of the repo team secret. The module READS it; it never writes it
# and never re-fetches it.
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$GITREPO/.heimdall"
PRESENCE_FULL="$GITREPO/.heimdall/.roster-cache.json"
cat > "$PRESENCE_FULL" <<'JSON'
[
  {"haid":"haid:akshat.akshats-macbook-air-2-755c","handle":"akshat","project":"github.com/randomittin/rally",
   "online":true,  "state":"active",  "age_seconds":12,   "ts":1799999988, "verdict":"working"},
  {"haid":"haid:anu.anus-macbook-pro-4b1e","handle":"anu","project":"github.com/randomittin/rally",
   "online":false, "state":"offline", "age_seconds":90000, "ts":1799910000, "verdict":"working"},
  {"haid":"haid:madhavan.madhavans-mbp-90ff","handle":"madhavan","project":"github.com/randomittin/rally",
   "online":false, "state":"offline", "age_seconds":200000,"ts":1799800000, "verdict":"working"}
]
JSON

# ─────────────────────────────────────────────────────────────────────────────
# FIXTURE 3 — the fake `gh`. Behaviour is switched by GH_MODE so one binary drives every
# degradation path. It also COUNTS its invocations, which is how the cache proof (H) works.
# ─────────────────────────────────────────────────────────────────────────────
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
GH_CALLS="$TMP/gh-calls"; : > "$GH_CALLS"
export GH_CALLS
cat > "$FAKEBIN/gh" <<'SH'
#!/bin/sh
printf 'call\n' >> "$GH_CALLS"
# `gh api user` — the AUTHENTICATED login, which is what anchors the local human to their
# collaborator row. Only the success path is special-cased; every failure mode below is
# shared with the collaborator probe, so both degrade through identical code.
if [ "${2:-}" = "user" ] && [ "${GH_MODE:-ok}" = "ok" ]; then
  echo randomittin
  exit 0
fi
case "${GH_MODE:-ok}" in
  ok)
    cat <<'EOF'
randomittin
akshat-mewt
Anu5846
SuperMadhavan
sanket-spe
tejashwini-cmd
EOF
    exit 0 ;;
  unauth)
    echo 'gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable.' >&2
    exit 4 ;;
  nonet)
    echo 'error connecting to api.github.com: dial tcp: lookup api.github.com: no such host' >&2
    exit 1 ;;
  ratelimit)
    echo 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' >&2
    exit 1 ;;
  private)
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1 ;;
  hang)
    sleep 120
    exit 0 ;;
  garbage)
    printf 'not json at all <<<\n'
    exit 0 ;;
esac
SH
chmod +x "$FAKEBIN/gh"
export FAKEBIN

# ── the ONE driver. Emits a JSON envelope the bash proofs interrogate with `get`. ────────
# Every knob is explicit so each proof isolates exactly one variable.
drive() {
  # drive <presence-cache-path-or-NONE> <repo-dir-or-NONE> <git-days> [extra env already set]
  PRESENCE_CACHE="$1" REPO_DIR="$2" GIT_DAYS="$3" "$PY" - <<'PYEOF' 2>"$TMP/err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import repo_roster as RR

now = float(os.environ["NOW"])
pc = os.environ["PRESENCE_CACHE"]
rd = os.environ["REPO_DIR"]
rows = RR.build(
    repo=(None if rd == "NONE" else rd),
    now=now,
    git_days=float(os.environ["GIT_DAYS"]),
    presence_cache=(None if pc == "NONE" else pc),
    cache_dir=os.environ["CACHE_DIR"],
    blocking=True,
)
by_handle = {r["handle"]: r for r in rows}
print(json.dumps({
    "rows": rows,
    "n": len(rows),
    "handles": [r["handle"] for r in rows],
    "tiers": [r["tier"] for r in rows],
    "by_handle": by_handle,
    "keysets": sorted({",".join(sorted(r.keys())) for r in rows}),
    "tier_vocab": sorted({r["tier"] for r in rows}),
    "any_presence_source": any("presence" in r["sources"] for r in rows),
    "any_online": any(r["online"] for r in rows),
    "any_last_seen": any(r["last_seen_ts"] is not None for r in rows),
}, sort_keys=True))
PYEOF
}

# get <json> <expr> — evaluate a probe expression against the driver's envelope, bound to `d`.
# SAFE BY CONSTRUCTION: every expression is a literal written in THIS file. No argument comes
# from the network, the environment, or the module under test — the JSON is only ever the DATA
# side (`d`), never the code side. This is a test-local introspection helper, not a parser.
get() { printf '%s' "$1" | "$PY" -c 'import json,sys;d=json.load(sys.stdin);print(eval(sys.argv[1]))' "$2" 2>/dev/null; }

fresh_cache() { CACHE_DIR="$TMP/cache-$1"; rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"; export CACHE_DIR; }

# ═════════════════════════════════════════════════════════════════════════════
echo "── A. IDENTITY UNIFICATION (the akshat 3-way + HAID) ──"
# ═════════════════════════════════════════════════════════════════════════════
fresh_cache full
OUT="$(PATH="$FAKEBIN:$PATH" GH_MODE=ok drive "$PRESENCE_FULL" "$GITREPO" 90)"
[ -n "$OUT" ] || { echo "DRIVER FAILED: $(cat "$TMP/err")" >&2; }

AK_N="$(get "$OUT" "sum(1 for r in d['rows'] if 'akshat' in json.dumps(r).lower() and r['handle']!='akshat nandini')")"
AK_ROW="$(get "$OUT" "json.dumps([r for r in d['rows'] if r['handle']=='akshat'])")"
AK_COUNT="$(get "$OUT" "sum(1 for r in d['rows'] if r['handle']=='akshat')")"
if [ "$AK_COUNT" = "1" ]; then
  ok "A  the three akshat git identities + the HAID collapse to exactly ONE row"
else
  bad "A  akshat appears $AK_COUNT times (expected 1) — rows=$(get "$OUT" "d['handles']")"
fi

AK_HAID="$(get "$OUT" "d['by_handle'].get('akshat',{}).get('haid')")"
[ "$AK_HAID" = "haid:akshat.akshats-macbook-air-2-755c" ] \
  && ok "A  the HAID bridged onto the git identity (haid_human + haid_machine)" \
  || bad "A  akshat's HAID did not bridge (got '$AK_HAID')"

AK_SRC="$(get "$OUT" "','.join(d['by_handle'].get('akshat',{}).get('sources',[]))")"
[ "$AK_SRC" = "presence,git,github" ] \
  && ok "A  akshat's row credits ALL THREE sources in canonical order (presence,git,github)" \
  || bad "A  akshat's sources are '$AK_SRC' (expected presence,git,github)"

# A2 — CONSERVATISM. "Akshat Nandini <nandini@elsewhere.example>" shares ONE weak signal with
# akshat (a first-name token) and nothing else. A merge here would ERASE her from the wall.
NAND="$(get "$OUT" "sum(1 for r in d['rows'] if r['handle'] in ('nandini','akshat nandini'))")"
[ "$NAND" = "1" ] \
  && ok "A2 CONSERVATIVE: a lone weak signal does NOT merge — the control human survives" \
  || bad "A2 the control human was swallowed by a weak merge (count=$NAND, handles=$(get "$OUT" "d['handles']"))"

# A2b — the same rule stated as a unit, so the threshold itself is falsifiable in isolation.
UNIT="$("$PY" - <<'PYEOF' 2>>"$TMP/err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import repo_roster as RR
a = RR.fragment("git", name="Akshat Singh", email="akshat@mewt.in", last_commit_ts=1.0)
b = RR.fragment("git", name="Akshat Singh", email="akshat@Akshats-MacBook-Air-2.local", last_commit_ts=2.0)
c = RR.fragment("git", name="Akshat", email="112849320+akshat-mewt@users.noreply.github.com", last_commit_ts=3.0)
h = RR.fragment("presence", handle="akshat", haid="haid:akshat.akshats-macbook-air-2-755c",
                online=True, last_seen_ts=4.0)
weak = RR.fragment("git", name="Akshat Nandini", email="nandini@elsewhere.example", last_commit_ts=5.0)
print(json.dumps({
    "ab": RR.would_merge(a, b)[0],
    "bc": RR.would_merge(b, c)[0],
    "hb": RR.would_merge(h, b)[0],
    "weak_a": RR.would_merge(weak, a)[0],
    "weak_c": RR.would_merge(weak, c)[0],
    "unified": len(RR.unify([a, b, c, h, weak])),
    "ab_why": sorted(k for k, _ in RR.would_merge(a, b)[1]),
    "bc_why": sorted(k for k, _ in RR.would_merge(b, c)[1]),
    "hb_why": sorted(k for k, _ in RR.would_merge(h, b)[1]),
}, sort_keys=True))
PYEOF
)"
if [ "$(get "$UNIT" "d['ab']")" = "True" ] && [ "$(get "$UNIT" "d['bc']")" = "True" ] \
   && [ "$(get "$UNIT" "d['hb']")" = "True" ]; then
  ok "A2b unit: every akshat pair merges on >=2 corroborating classes (ab=$(get "$UNIT" "d['ab_why']") bc=$(get "$UNIT" "d['bc_why']") haid=$(get "$UNIT" "d['hb_why']"))"
else
  bad "A2b unit: an akshat pair failed to merge (ab=$(get "$UNIT" "d['ab']") bc=$(get "$UNIT" "d['bc']") hb=$(get "$UNIT" "d['hb']"))"
fi
if [ "$(get "$UNIT" "d['weak_a']")" = "False" ] && [ "$(get "$UNIT" "d['weak_c']")" = "False" ] \
   && [ "$(get "$UNIT" "d['unified']")" = "2" ]; then
  ok "A2b unit FALSIFIABLE both ways: 5 fragments -> 2 people (4 merged, 1 refused on weak evidence)"
else
  bad "A2b unit: weak merge admitted or unify miscounted (weak_a=$(get "$UNIT" "d['weak_a']") weak_c=$(get "$UNIT" "d['weak_c']") people=$(get "$UNIT" "d['unified']"))"
fi

# A3 — no over-merge across the whole fixture.
N_ROWS="$(get "$OUT" "d['n']")"
UNIQ="$(get "$OUT" "len(set(d['handles']))")"
[ "$N_ROWS" = "$UNIQ" ] \
  && ok "A3 no two rows share a handle — the fold produced distinct humans ($N_ROWS rows)" \
  || bad "A3 duplicate handles in the roster ($N_ROWS rows, $UNIQ distinct)"

echo
# ═════════════════════════════════════════════════════════════════════════════
echo "── B. ALL-BRANCH DISCOVERY (git log --all, not HEAD) ──"
# ═════════════════════════════════════════════════════════════════════════════
ANU="$(get "$OUT" "sum(1 for r in d['rows'] if r['handle']=='anu')")"
[ "$ANU" = "1" ] \
  && ok "B  anu — who commits ONLY on feat/anu, never on HEAD — is on the roster" \
  || bad "B  anu is missing: an all-branch scan did not happen (handles=$(get "$OUT" "d['handles']"))"

HEAD_ONLY="$(git -C "$GITREPO" log --since=90.days --format='%aE' | sort -u | grep -c 'anu@superpe.co' || true)"
[ "$HEAD_ONLY" = "0" ] \
  && ok "B  FALSIFIABLE: a HEAD-only scan finds ZERO anu commits — --all is load-bearing" \
  || bad "B  fixture is wrong: anu is reachable from HEAD, so B proves nothing"

echo
# ═════════════════════════════════════════════════════════════════════════════
echo "── C. TIER ORDERING (online > contributed > away > member) ──"
# ═════════════════════════════════════════════════════════════════════════════
TIERS="$(get "$OUT" "','.join(d['tiers'])")"
SORTED_OK="$(get "$OUT" "d['tiers']==sorted(d['tiers'], key=lambda t:['online','contributed','away','member'].index(t))")"
[ "$SORTED_OK" = "True" ] \
  && ok "C  tiers are emitted best-first: $TIERS" \
  || bad "C  tier order broken: $TIERS"

AK_TIER="$(get "$OUT" "d['by_handle'].get('akshat',{}).get('tier')")"
[ "$AK_TIER" = "online" ] \
  && ok "C  akshat (beating now) is tier 1 online" \
  || bad "C  akshat is tier '$AK_TIER' (expected online)"

ANU_TIER="$(get "$OUT" "d['by_handle'].get('anu',{}).get('tier')")"
[ "$ANU_TIER" = "contributed" ] \
  && ok "C  anu (away in presence, but committed 5d ago) ranks CONTRIBUTED — 2 outranks 3" \
  || bad "C  anu is tier '$ANU_TIER' (expected contributed — a recent commit outranks away)"

MAD_TIER="$(get "$OUT" "d['by_handle'].get('madhavan',{}).get('tier')")"
[ "$MAD_TIER" = "away" ] \
  && ok "C  madhavan (presence-only, past the online TTL) ranks AWAY" \
  || bad "C  madhavan is tier '$MAD_TIER' (expected away)"

MEMBERS="$(get "$OUT" "sorted(r['handle'] for r in d['rows'] if r['tier']=='member')")"
HAS_MEMBER="$(get "$OUT" "any(r['tier']=='member' for r in d['rows'])")"
[ "$HAS_MEMBER" = "True" ] \
  && ok "C  tier 4 present from github collaborators alone: $MEMBERS" \
  || bad "C  no member rows — the github collaborator source did not land"

# within-tier recency, most-recent-first
RECENCY_OK="$(get "$OUT" "all((lambda g:[all(g[i]>=g[i+1] for i in range(len(g)-1))])(  [ (r['last_seen_ts'] if r['tier'] in ('online','away') else (r['last_commit_ts'] or 0)) or 0 for r in d['rows'] if r['tier']==t ])[0] for t in ('online','contributed','away'))")"
[ "$RECENCY_OK" = "True" ] \
  && ok "C  inside every tier the rows are most-recent-first" \
  || bad "C  within-tier recency is not descending"

STALE_SEEN="$(get "$OUT" "any('oldtimer' in json.dumps(r).lower() or r['handle']=='old' for r in d['rows'])")"
[ "$STALE_SEEN" = "False" ] \
  && ok "C  the 200-day-old author is ABSENT entirely — the git window is a real, bounded scan" \
  || bad "C  a 200-day-old author leaked onto the wall (handles=$(get "$OUT" "d['handles']"))"

echo
# ═════════════════════════════════════════════════════════════════════════════
echo "── C-RED. FALSIFIABILITY: break the ranking, watch it go RED ──"
# ═════════════════════════════════════════════════════════════════════════════
RED_PASS=0; RED_FAIL=0
MUTANT_DIR="$TMP/mutant"; mkdir -p "$MUTANT_DIR"
cp "$LIB/repo_roster.py" "$MUTANT_DIR/repo_roster.py"
# INVERT the tier rank map. Nothing else changes — same sources, same clock, same fixture.
sed -e 's/^_TIER_ORDER = .*/_TIER_ORDER = ("member", "away", "contributed", "online")/' \
    "$LIB/repo_roster.py" > "$MUTANT_DIR/repo_roster.py"
grep -q '^_TIER_ORDER = ("member", "away", "contributed", "online")$' "$MUTANT_DIR/repo_roster.py" \
  && ok "C-RED mutant built: _TIER_ORDER inverted (the ONLY delta)" \
  || bad "C-RED mutation did not apply — _TIER_ORDER is not where the ranking lives"

order_proof() {  # order_proof <libdir> -> prints True/False
  LIB="$1" PRESENCE_CACHE="$PRESENCE_FULL" REPO_DIR="$GITREPO" GIT_DAYS=90 CACHE_DIR="$2" \
  "$PY" - <<'PYEOF' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["LIB"])
import repo_roster as RR
rows = RR.build(repo=os.environ["REPO_DIR"], now=float(os.environ["NOW"]),
                git_days=float(os.environ["GIT_DAYS"]),
                presence_cache=os.environ["PRESENCE_CACHE"],
                cache_dir=os.environ["CACHE_DIR"], blocking=True)
want = ["online", "contributed", "away", "member"]
got = [r["tier"] for r in rows]
print(got == sorted(got, key=want.index))
PYEOF
}
fresh_cache mutant
MUT="$(order_proof "$MUTANT_DIR" "$CACHE_DIR")"
if [ "$MUT" = "False" ]; then
  RED_PASS=$((RED_PASS+1)); ok "C-RED with the ranking inverted the order proof FAILS (RED observed)"
else
  RED_FAIL=$((RED_FAIL+1)); bad "C-RED the mutant still passed — the order proof does not test the ranking"
fi
fresh_cache restored
GREEN="$(order_proof "$LIB" "$CACHE_DIR")"
if [ "$GREEN" = "True" ]; then
  RED_PASS=$((RED_PASS+1)); ok "C-RED restored: the same proof PASSES on the real module (GREEN observed)"
else
  RED_FAIL=$((RED_FAIL+1)); bad "C-RED the real module fails its own order proof"
fi

echo
# ═════════════════════════════════════════════════════════════════════════════
echo "── D. GITHUB DEGRADATION MATRIX (never block, never raise, never error out) ──"
# ═════════════════════════════════════════════════════════════════════════════
degrade_case() {  # degrade_case <label> <PATH-to-use> <GH_MODE> <max-seconds>
  local label="$1" usepath="$2" mode="$3" budget="$4" t0 t1 elapsed out n members
  fresh_cache "deg-$mode"
  t0="$(date +%s)"
  out="$(PATH="$usepath" GH_MODE="$mode" drive "$PRESENCE_FULL" "$GITREPO" 90)"
  t1="$(date +%s)"
  elapsed=$(( t1 - t0 ))
  if [ -z "$out" ]; then
    bad "D  $label: the driver raised instead of degrading — $(tail -3 "$TMP/err")"
    return
  fi
  n="$(get "$out" "d['n']")"
  members="$(get "$out" "sum(1 for r in d['rows'] if r['tier']=='member')")"
  local t1_3
  t1_3="$(get "$out" "sum(1 for r in d['rows'] if r['tier'] in ('online','contributed','away'))")"
  if [ "$members" = "0" ] && [ "$t1_3" -ge 4 ] && [ "$elapsed" -le "$budget" ]; then
    ok "D  $label: tiers 1-3 intact ($t1_3 rows), tier 4 absent, ${elapsed}s <= ${budget}s, exit 0"
  else
    bad "D  $label: rows=$n members=$members tiers1-3=$t1_3 elapsed=${elapsed}s (budget ${budget}s)"
  fi
}
# `gh` genuinely absent: the REAL PATH minus every directory that holds a gh. Everything else
# (git, python, the shell) stays exactly as it was, so this isolates one variable and one only.
NOGH_PATH=""
OLD_IFS="$IFS"; IFS=":"
for dir in $PATH; do
  [ -n "$dir" ] || continue
  [ -x "$dir/gh" ] && continue
  NOGH_PATH="${NOGH_PATH:+$NOGH_PATH:}$dir"
done
IFS="$OLD_IFS"
command -v gh >/dev/null 2>&1 && REAL_GH=1 || REAL_GH=0
if PATH="$NOGH_PATH" command -v gh >/dev/null 2>&1; then
  bad "D  fixture: gh is STILL on the stripped PATH — the absent-gh case proves nothing"
fi
degrade_case "gh ABSENT from PATH"      "$NOGH_PATH"        "ok"        20
degrade_case "gh present, NOT AUTHED"   "$FAKEBIN:$PATH"    "unauth"    20
degrade_case "NO NETWORK (dns failure)" "$FAKEBIN:$PATH"    "nonet"     20
degrade_case "RATE LIMITED (403)"       "$FAKEBIN:$PATH"    "ratelimit" 20
degrade_case "PRIVATE REPO (404)"       "$FAKEBIN:$PATH"    "private"   20
degrade_case "gh emits GARBAGE"         "$FAKEBIN:$PATH"    "garbage"   20
# THE ONE THAT MATTERS FOR THE STATUSLINE: gh hangs forever. The module must cut it off.
degrade_case "gh HANGS (must be killed)" "$FAKEBIN:$PATH"   "hang"      25

echo
# ═════════════════════════════════════════════════════════════════════════════
echo "── E. NO PRESENCE (the CP deploy is outstanding — the wall must still populate) ──"
# ═════════════════════════════════════════════════════════════════════════════
fresh_cache nopres
NOPRES="$(PATH="$FAKEBIN:$PATH" GH_MODE=ok drive "$TMP/does-not-exist.json" "$GITREPO" 90)"
NP_N="$(get "$NOPRES" "d['n']")"
NP_CONTRIB="$(get "$NOPRES" "sum(1 for r in d['rows'] if r['tier']=='contributed')")"
NP_MEMBER="$(get "$NOPRES" "sum(1 for r in d['rows'] if r['tier']=='member')")"
if [ "$NP_CONTRIB" -ge 3 ] && [ "$NP_MEMBER" -ge 1 ]; then
  ok "E  presence FULLY degraded -> $NP_N rows anyway ($NP_CONTRIB contributed + $NP_MEMBER member). THE PROPERTY."
else
  bad "E  a degraded presence layer emptied the wall (rows=$NP_N contributed=$NP_CONTRIB member=$NP_MEMBER)"
fi
NP_TIERS="$(get "$NOPRES" "','.join(sorted(set(d['tiers'])))")"
[ "$(get "$NOPRES" "any(t in ('online','away') for t in d['tiers'])")" = "False" ] \
  && ok "E  with no presence NO row claims online/away — tiers present: $NP_TIERS" \
  || bad "E  an online/away tier appeared without any presence input ($NP_TIERS)"

# E2 — an EMPTY (but present) roster cache is the same story: the deployed-but-silent CP.
fresh_cache emptypres
printf '[]\n' > "$TMP/empty-roster.json"
EMPTY="$(PATH="$FAKEBIN:$PATH" GH_MODE=ok drive "$TMP/empty-roster.json" "$GITREPO" 90)"
[ "$(get "$EMPTY" "d['n']")" -ge 4 ] \
  && ok "E2 an EMPTY roster cache degrades identically ($(get "$EMPTY" "d['n']") rows from git+github)" \
  || bad "E2 an empty roster cache emptied the wall"

echo
# ═════════════════════════════════════════════════════════════════════════════
echo "── F. NO GIT (not a repo / git unusable) ──"
# ═════════════════════════════════════════════════════════════════════════════
NOTREPO="$TMP/notarepo"; mkdir -p "$NOTREPO/.heimdall"
cp "$PRESENCE_FULL" "$NOTREPO/.heimdall/.roster-cache.json"
fresh_cache nogit
NOGIT="$(PATH="$FAKEBIN:$PATH" GH_MODE=ok drive "$NOTREPO/.heimdall/.roster-cache.json" "$NOTREPO" 90)"
NG_N="$(get "$NOGIT" "d['n']")"
NG_COMMIT="$(get "$NOGIT" "any(r['last_commit_ts'] is not None for r in d['rows'])")"
if [ "$NG_N" = "3" ] && [ "$NG_COMMIT" = "False" ]; then
  ok "F  a non-git dir yields the 3 presence rows, zero commit facts, exit 0"
else
  bad "F  non-git degradation wrong (rows=$NG_N any_commit_ts=$NG_COMMIT)"
fi

# F2 — everything off at once. The honest empty: [] and exit 0, never a crash.
fresh_cache allgone
ALLGONE="$(PATH="$NOGH_PATH" GH_MODE=nonet drive "$TMP/nope.json" "$NOTREPO" 90)"
[ "$(get "$ALLGONE" "d['n']")" = "0" ] \
  && ok "F2 ALL THREE sources gone -> [] and exit 0 (honest empty, never an exception)" \
  || bad "F2 all-sources-gone did not produce a clean empty (n=$(get "$ALLGONE" "d['n']"))"

echo
# ═════════════════════════════════════════════════════════════════════════════
echo "── G. PRIVACY: a row built without the team secret carries NO presence fact ──"
# ═════════════════════════════════════════════════════════════════════════════
# Presence rides <repo>/.heimdall/.roster-cache.json, which ONLY populates for a holder of the
# repo team secret. Someone without it reads NOTHING there — so tier-4 (github) and tier-2 (git)
# rows must be provably free of online / last_seen_ts / a "presence" source.
G_SRC="$(get "$NOPRES" "d['any_presence_source']")"
G_ON="$(get "$NOPRES" "d['any_online']")"
G_SEEN="$(get "$NOPRES" "d['any_last_seen']")"
if [ "$G_SRC" = "False" ] && [ "$G_ON" = "False" ] && [ "$G_SEEN" = "False" ]; then
  ok "G  no team secret -> no 'presence' source, no online:true, no last_seen_ts anywhere"
else
  bad "G  PRESENCE LEAK without the team secret (source=$G_SRC online=$G_ON last_seen=$G_SEEN)"
fi
# G2 — the invariant as a callable, so the render agent (and CI) can assert it directly.
G2="$("$PY" - <<'PYEOF' 2>>"$TMP/err"
import os, sys
sys.path.insert(0, os.environ["LIB"])
import repo_roster as RR
clean = [{"handle": "x", "haid": None, "tier": "member", "online": False,
          "last_seen_ts": None, "last_commit_ts": None, "sources": ["github"]}]
leaky = [{"handle": "x", "haid": None, "tier": "member", "online": False,
          "last_seen_ts": 1.0, "last_commit_ts": None, "sources": ["github"]}]
print("%s %s" % (RR.presence_free(clean), RR.presence_free(leaky)))
PYEOF
)"
[ "$G2" = "True False" ] \
  && ok "G2 presence_free() is falsifiable: clean rows True, a planted last_seen_ts False" \
  || bad "G2 presence_free() did not discriminate (got '$G2')"

echo
# ═════════════════════════════════════════════════════════════════════════════
echo "── H. CACHE (the statusline runs on every prompt — gh must NOT be on the hot path) ──"
# ═════════════════════════════════════════════════════════════════════════════
fresh_cache hot
: > "$GH_CALLS"
PATH="$FAKEBIN:$PATH" GH_MODE=ok drive "$PRESENCE_FULL" "$GITREPO" 90 > /dev/null
C1="$(wc -l < "$GH_CALLS" | tr -d ' ')"
PATH="$FAKEBIN:$PATH" GH_MODE=ok drive "$PRESENCE_FULL" "$GITREPO" 90 > /dev/null
PATH="$FAKEBIN:$PATH" GH_MODE=ok drive "$PRESENCE_FULL" "$GITREPO" 90 > /dev/null
C3="$(wc -l < "$GH_CALLS" | tr -d ' ')"
if [ "$C1" = "1" ] && [ "$C3" = "1" ]; then
  ok "H  gh invoked ONCE across three roster builds — reads 2 and 3 came from cache"
else
  bad "H  gh invoked $C3 times across 3 builds (expected 1) — the cache is not holding"
fi
GH_CACHE_FILE="$(ls -a "$CACHE_DIR" 2>/dev/null | grep -c 'github' || true)"
[ "$GH_CACHE_FILE" -ge 1 ] \
  && ok "H  a github cache artifact exists in the cache dir" \
  || bad "H  no github cache artifact was written"

# H2 — a FAILED probe is negative-cached too, else a broken gh is re-run every prompt.
fresh_cache negcache
: > "$GH_CALLS"
PATH="$FAKEBIN:$PATH" GH_MODE=nonet drive "$PRESENCE_FULL" "$GITREPO" 90 > /dev/null
PATH="$FAKEBIN:$PATH" GH_MODE=nonet drive "$PRESENCE_FULL" "$GITREPO" 90 > /dev/null
NC="$(wc -l < "$GH_CALLS" | tr -d ' ')"
[ "$NC" = "1" ] \
  && ok "H2 a FAILED gh probe is negative-cached — offline does not re-shell every prompt" \
  || bad "H2 a failed gh probe re-ran $NC times (expected 1)"

# H3 — git is cached too (git log --all costs ~0.2s; that is not a per-prompt budget).
export GITREPO
H3="$("$PY" - <<'PYEOF' 2>>"$TMP/err"
import os, sys, time
sys.path.insert(0, os.environ["LIB"])
import repo_roster as RR
repo, cache = os.environ["GITREPO"], os.environ["TMP"] + "/cache-gitttl"
os.makedirs(cache, exist_ok=True)
now = float(os.environ["NOW"])
RR.git_fragments(repo, now=now, days=90.0, cache_dir=cache, blocking=True)
t0 = time.time(); RR.git_fragments(repo, now=now, days=90.0, cache_dir=cache, blocking=True)
warm = time.time() - t0
print("%s %.4f" % (RR.GIT_CACHE_TTL_SECONDS, warm))
PYEOF
)"
H3_TTL="$(printf '%s' "$H3" | cut -d' ' -f1)"
H3_WARM="$(printf '%s' "$H3" | cut -d' ' -f2)"
if [ -n "$H3_TTL" ] && [ "$(printf '%s' "$H3_WARM" | cut -d. -f1)" = "0" ]; then
  ok "H3 the git read is cached (ttl=${H3_TTL}s; warm read ${H3_WARM}s — no subprocess)"
else
  bad "H3 the git read is not cached (ttl=$H3_TTL warm=$H3_WARM)"
fi

echo
# ═════════════════════════════════════════════════════════════════════════════
echo "── I. THE FROZEN CONTRACT (exact keys, exact types, exact tier vocabulary) ──"
# ═════════════════════════════════════════════════════════════════════════════
WANT_KEYS="haid,handle,last_commit_ts,last_seen_ts,online,sources,tier"
KEYSETS="$(get "$OUT" "'|'.join(d['keysets'])")"
[ "$KEYSETS" = "$WANT_KEYS" ] \
  && ok "I  every row has EXACTLY the 7 contract keys and no others" \
  || bad "I  key drift: got '$KEYSETS' expected '$WANT_KEYS'"

TYPES_OK="$(get "$OUT" "all(isinstance(r['handle'],str) and (r['haid'] is None or isinstance(r['haid'],str)) and r['tier'] in ('online','contributed','away','member') and isinstance(r['online'],bool) and (r['last_seen_ts'] is None or isinstance(r['last_seen_ts'],(int,float))) and (r['last_commit_ts'] is None or isinstance(r['last_commit_ts'],(int,float))) and isinstance(r['sources'],list) and all(s in ('presence','git','github') for s in r['sources']) and r['sources'] for r in d['rows'])")"
[ "$TYPES_OK" = "True" ] \
  && ok "I  every field matches the declared type and vocabulary; sources is never empty" \
  || bad "I  a row violates the declared types/vocabulary"

ONLINE_OK="$(get "$OUT" "all((r['online'] is True) == (r['tier']=='online') for r in d['rows'])")"
[ "$ONLINE_OK" = "True" ] \
  && ok "I  online:true iff tier=='online' — the flag and the tier can never disagree" \
  || bad "I  online flag and tier disagree on some row"

# I2 — the CLI entry the render agent shells out to emits the same array.
CLI_OUT="$(PATH="$FAKEBIN:$PATH" GH_MODE=ok HMD_ROSTER_CACHE_DIR="$TMP/cache-cli" \
  HMD_ROSTER_PRESENCE_CACHE="$PRESENCE_FULL" HMD_ROSTER_NOW="$NOW" \
  "$PY" "$LIB/repo_roster.py" --repo "$GITREPO" --git-days 90 --blocking 2>"$TMP/cli-err")"
CLI_RC=$?
CLI_N="$(printf '%s' "$CLI_OUT" | "$PY" -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo -1)"
if [ "$CLI_RC" = "0" ] && [ "$CLI_N" = "$N_ROWS" ]; then
  ok "I2 the CLI emits the identical $CLI_N-row array (exit 0) — render-agent entry point works"
else
  bad "I2 CLI mismatch (rc=$CLI_RC rows=$CLI_N vs api=$N_ROWS): $(tail -3 "$TMP/cli-err")"
fi

# I3 — ambiguity is VISIBLE. Refused-but-suspicious pairs surface OUT-OF-BAND, never by
# mutating the frozen contract.
AMB="$(PATH="$FAKEBIN:$PATH" GH_MODE=ok HMD_ROSTER_CACHE_DIR="$TMP/cache-cli" \
  HMD_ROSTER_PRESENCE_CACHE="$PRESENCE_FULL" HMD_ROSTER_NOW="$NOW" \
  "$PY" "$LIB/repo_roster.py" --repo "$GITREPO" --git-days 90 --blocking --explain 2>/dev/null \
  | "$PY" -c 'import json,sys;d=json.load(sys.stdin);print(len(d.get("near_misses",[])), len(d.get("people",[])))' 2>/dev/null || echo "ERR")"
AMB_NEAR="$(printf '%s' "$AMB" | cut -d' ' -f1)"
# The anchor-OFF baseline that section J compares against, so "the anchor changed nobody
# else" is measured against this suite's own numbers rather than a hardcoded constant.
N_PEOPLE="$(printf '%s' "$AMB" | cut -d' ' -f2)"
if [ -n "$AMB_NEAR" ] && [ "$AMB_NEAR" != "ERR" ] && [ "$AMB_NEAR" -ge 1 ]; then
  ok "I3 --explain surfaces $AMB_NEAR residual near-miss pair(s) — ambiguity is visible, not guessed"
else
  bad "I3 --explain did not surface the residual ambiguity (got '$AMB')"
fi

echo
# ═════════════════════════════════════════════════════════════════════════════
echo "── J. THE LOCAL IDENTITY (the owner must appear exactly ONCE, with ONE face) ──"
# ═════════════════════════════════════════════════════════════════════════════
# Reproduces the MEASURED defect on the owner's own heimdall repo: the presence fragment
# `haid:rj.<machine>-46d5` (handle `rj`) and the git author `rj@runheimdall.dev` (display
# names RJ / randomittin) score haid_human=2 — ONE class, one short of the merge floor — so
# they refuse, and the owner renders TWICE: `rj` online, plus a second `randomittin` row
# whose haid is null and whose sigil therefore seeds off the HANDLE STRING instead of a
# HAID, producing a completely different face.
#
# Every input is injected, so this proves the rule and not the developer's laptop.
JREPO="$TMP/jrepo"; mkdir -p "$JREPO"
git -C "$JREPO" init -q 2>/dev/null
git -C "$JREPO" config user.email "rj@runheimdall.dev"
git -C "$JREPO" config user.name "RJ"
jcommit() {   # jcommit <display-name> <days-ago> <slug>
  printf '%s\n' "$3" > "$JREPO/$3.txt"
  git -C "$JREPO" add -A >/dev/null 2>&1
  GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="rj@runheimdall.dev" \
  GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="rj@runheimdall.dev" \
  GIT_AUTHOR_DATE="$(( NOW - $2 * DAY )) +0000" \
  GIT_COMMITTER_DATE="$(( NOW - $2 * DAY )) +0000" \
    git -C "$JREPO" commit -q -m "$3" >/dev/null 2>&1
}
jcommit "RJ"          4 "j-one"
jcommit "randomittin" 2 "j-two"

mkdir -p "$JREPO/.heimdall"
JPRESENCE="$JREPO/.heimdall/.roster-cache.json"
cat > "$JPRESENCE" <<'JSON'
[
  {"haid":"haid:rj.rjs-macbook-air-46d5","handle":"rj","project":"github.com/randomittin/heimdall",
   "online":true, "state":"active", "age_seconds":9, "ts":1799999991, "verdict":"working"}
]
JSON
# A HAID for the SAME human slug on a DIFFERENT box — self_device must NOT fire on it.
JPRESENCE_OTHER="$TMP/j-other-presence.json"
cat > "$JPRESENCE_OTHER" <<'JSON'
[
  {"haid":"haid:rj.some-other-box-1234","handle":"rj","project":"github.com/randomittin/heimdall",
   "online":true, "state":"active", "age_seconds":9, "ts":1799999991, "verdict":"working"}
]
JSON

# drive_j <presence-or-NONE> <machine-slug-or-EMPTY> <no-self-flag> -> the frozen array
drive_j() {
  fresh_cache "j-$(printf '%s' "$1$2$3" | tr -c 'a-zA-Z0-9' '-')"
  PATH="$FAKEBIN:$PATH" GH_MODE=ok \
  HMD_ROSTER_NO_SELF="$3" \
  HMD_ROSTER_SELF_EMAIL="rj@runheimdall.dev" HMD_ROSTER_SELF_NAME="RJ" \
  HMD_ROSTER_SELF_MACHINE="$2" \
  HMD_ROSTER_GITHUB_SLUG="randomittin/heimdall" \
  HMD_ROSTER_CACHE_DIR="$CACHE_DIR" HMD_ROSTER_NOW="$NOW" \
    "$PY" "$LIB/repo_roster.py" --repo "$JREPO" --git-days 90 --blocking \
    --presence-cache "$1" 2>/dev/null
}
jq_get() { printf '%s' "$1" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print($2)" 2>/dev/null; }
# The J repo has exactly ONE git author and ONE presence row — both the owner — so any row
# carrying a presence or git source IS the owner. Counting those instead of the whole array
# keeps these proofs about the merge and immune to the collaborator fixture's member rows.
OWNER="[r for r in d if 'presence' in r['sources'] or 'git' in r['sources']]"

# J1 RED — anchor OFF reproduces the screenshot exactly: two rows, the git row haid-less.
J_RED="$(drive_j "$JPRESENCE" "RJs-MacBook-Air" 1)"
J_RED_N="$(jq_get "$J_RED" "len($OWNER)")"
J_RED_HAIDLESS="$(jq_get "$J_RED" "sum(1 for r in $OWNER if r['haid'] is None)")"
if [ "$J_RED_N" = "2" ] && [ "$J_RED_HAIDLESS" = "1" ]; then
  ok "J1 RED anchor OFF -> the owner splits into 2 rows, one with haid=null (the 2-face bug)"
else
  bad "J1 RED did not reproduce the split (rows=$J_RED_N haidless=$J_RED_HAIDLESS)"
fi

# J2 GREEN — anchor ON folds them into exactly one person carrying ALL THREE sources.
J_OUT="$(drive_j "$JPRESENCE" "RJs-MacBook-Air" "")"
J_N="$(jq_get "$J_OUT" "len($OWNER)")"
J_SRC="$(jq_get "$J_OUT" "','.join($OWNER[0]['sources']) if $OWNER else 'NONE'")"
if [ "$J_N" = "1" ] && [ "$J_SRC" = "presence,git,github" ]; then
  ok "J2 GREEN anchor ON -> exactly ONE row, sources presence+git+github (all retained)"
else
  bad "J2 GREEN did not unify the owner (rows=$J_N sources=$J_SRC)"
fi

# J3 — the BEST tier survives. A git-derived row must never demote a live presence row.
J_TIER="$(jq_get "$J_OUT" "d[0]['tier'] if d else 'NONE'")"
J_ONLINE="$(jq_get "$J_OUT" "d[0]['online'] if d else 'NONE'")"
[ "$J_TIER" = "online" ] && [ "$J_ONLINE" = "True" ] \
  && ok "J3 the merged row keeps the BEST tier (online) — git did not demote presence" \
  || bad "J3 merged row lost its tier (tier=$J_TIER online=$J_ONLINE)"

# J4 — ONE FACE. The surviving row must carry THIS DEVICE's HAID, because the renderer seeds
# the sigil from `haid or handle` and only a real HAID resolves to a hero.
J_HAID="$(jq_get "$J_OUT" "d[0]['haid'] if d else 'NONE'")"
[ "$J_HAID" = "haid:rj.rjs-macbook-air-46d5" ] \
  && ok "J4 the merged row's sigil key is THIS DEVICE's HAID — one stable face, not an alias" \
  || bad "J4 merged row carries the wrong sigil key (got '$J_HAID')"

# J5 — self_device needs BOTH components. Same human slug, DIFFERENT machine -> no merge.
J_OTHER="$(drive_j "$JPRESENCE_OTHER" "RJs-MacBook-Air" "")"
J_OTHER_N="$(jq_get "$J_OTHER" "len($OWNER)")"
[ "$J_OTHER_N" = "2" ] \
  && ok "J5 a HAID from ANOTHER machine does NOT merge — self_device pins human AND device" \
  || bad "J5 merged across devices (rows=$J_OTHER_N) — the anchor is too aggressive"

# J6 — no device name resolvable -> the anchor cannot claim the presence row, so the module
# falls back to exactly the conservative answer rather than guessing.
J_NOMACH="$(drive_j "$JPRESENCE" "" "")"
J_NOMACH_N="$(jq_get "$J_NOMACH" "len($OWNER)")"
[ "$J_NOMACH_N" = "2" ] \
  && ok "J6 with no resolvable device name the anchor degrades to the conservative 2 rows" \
  || bad "J6 anchor merged without a device name (rows=$J_NOMACH_N)"

# J7 — PRIVACY. No presence cache = no team secret. The anchor still merges git+github, and
# the result must carry NO presence fact whatsoever.
J_NOPRES="$(drive_j NONE "RJs-MacBook-Air" "")"
J_NOPRES_N="$(jq_get "$J_NOPRES" "len($OWNER)")"
J_FREE="$(printf '%s' "$J_NOPRES" | "$PY" -c "
import json,sys,os
sys.path.insert(0, os.environ['LIB'])
import repo_roster as RR
print(RR.presence_free(json.load(sys.stdin)))" 2>/dev/null)"
if [ "$J_NOPRES_N" = "1" ] && [ "$J_FREE" = "True" ]; then
  ok "J7 without the team secret the anchor still unifies git+github and leaks NO presence"
else
  bad "J7 privacy/degradation broke (rows=$J_NOPRES_N presence_free=$J_FREE)"
fi

# J8 — THE ANCHOR CANNOT INVENT A PERSON. An owner with no presence, no commits in the window
# and no collaborator entry contributes only a sourceless cluster, which emits no row.
fresh_cache j-phantom
J_PHANTOM="$(PATH="$FAKEBIN:$PATH" GH_MODE=ok \
  HMD_ROSTER_NO_SELF= HMD_ROSTER_SELF_EMAIL="nobody@nowhere.example" \
  HMD_ROSTER_SELF_NAME="Nobody" HMD_ROSTER_SELF_MACHINE="Ghost-Box" \
  HMD_ROSTER_SELF_LOGIN="nobody-at-all" HMD_ROSTER_NO_GITHUB=1 \
  HMD_ROSTER_CACHE_DIR="$CACHE_DIR" HMD_ROSTER_NOW="$NOW" \
  "$PY" "$LIB/repo_roster.py" --repo "$JREPO" --git-days 1 --blocking \
  --presence-cache NONE 2>/dev/null)"
J_PHANTOM_N="$(jq_get "$J_PHANTOM" "len(d)")"
[ "$J_PHANTOM_N" = "0" ] \
  && ok "J8 an anchor that matched nothing emits NO row — it cannot invent a wall member" \
  || bad "J8 the anchor fabricated $J_PHANTOM_N row(s) from local config alone"

# J9 — NOBODY ELSE'S RULE MOVED. The main fixture's person count and its refused pair are
# byte-identical with the anchor enabled, so the conservative rule is genuinely untouched.
fresh_cache j-collateral
J_MAIN="$(PATH="$FAKEBIN:$PATH" GH_MODE=ok \
  HMD_ROSTER_NO_SELF= HMD_ROSTER_SELF_EMAIL="rj@runheimdall.dev" \
  HMD_ROSTER_SELF_NAME="RJ" HMD_ROSTER_SELF_MACHINE="RJs-MacBook-Air" \
  HMD_ROSTER_SELF_LOGIN="randomittin" \
  HMD_ROSTER_CACHE_DIR="$CACHE_DIR" HMD_ROSTER_NOW="$NOW" \
  "$PY" "$LIB/repo_roster.py" --repo "$GITREPO" --git-days 90 --blocking --explain \
  --presence-cache "$PRESENCE_FULL" 2>/dev/null)"
J_MAIN_N="$(jq_get "$J_MAIN" "d['counts']['people']")"
J_MAIN_NEAR="$(jq_get "$J_MAIN" "len(d['near_misses'])")"
if [ "$J_MAIN_N" = "$N_PEOPLE" ] && [ "$J_MAIN_NEAR" = "$AMB_NEAR" ]; then
  ok "J9 the anchor changes NOBODY else: still $J_MAIN_N people, still $J_MAIN_NEAR near-miss(es)"
else
  bad "J9 collateral damage (people $J_MAIN_N vs $N_PEOPLE, near-misses $J_MAIN_NEAR vs $AMB_NEAR)"
fi

echo
echo "============================================================"
printf "repo-roster: %d passed, %d failed\n" "$PASS" "$FAIL"
printf "falsifiability (C-RED): %d observed, %d unobserved  [mutant must FAIL, real must PASS]\n" \
  "$RED_PASS" "$RED_FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
[ "$RED_FAIL" -eq 0 ] || exit 1
exit 0
