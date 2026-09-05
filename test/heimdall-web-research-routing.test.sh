#!/usr/bin/env bash
# test/heimdall-web-research-routing.test.sh — falsifies that agents/heimdall.md
# actually DISPATCHES web/research work, instead of the capability sitting
# reachable-but-unrouted (a defect class this repo has shipped before: a tool
# live and reachable with nothing telling the orchestrator to use it).
#
# WHY THIS EXISTS. `hmd web` (bin/heimdall-web: fetch|crawl|batch|meta) and native
# WebSearch/WebFetch were wired onto six role agents on 2026-09-05
# (docs/analysis/2026-09-05-web-research-tools-rollout.md) — but that same task
# explicitly declined to touch agents/heimdall.md, reasoning the orchestrator
# "doesn't do hands-on technical research itself". That left a gap: nothing in
# the orchestrator's domain-identification (§2a), skill-matching (§2b), or
# agent-type (§4a) sections named this domain, so an obviously research-shaped
# prompt ("what does the Stripe API say about X", "is there a CVE for lodash
# 4.17") had no automatic route to a role that could look it up. This suite
# pins the fix: the domain is identified, the capability is named, each of the
# six tool-bearing roles gets an explicit routing row, the orchestrator stays
# delegate-only, and the four judges stay untouched.
#
# HERMETIC where it matters: sections [1]-[5] read the real agents/heimdall.md
# and the real agents/*.md tool lines — cross-checking a routing claim against
# the file it claims to route to, not a synthetic stand-in. Section [6] is the
# one red-proof case and runs against a throwaway temp file, never the real repo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FILE="$ROOT/agents/heimdall.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  PASS: %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL: %s\n" "$1"; }

[ -f "$FILE" ] || { echo "FATAL: $FILE missing"; exit 2; }

# have PATTERN LABEL — fixed-string grep against the real doc under test.
have() {
  if grep -qF -- "$1" "$FILE"; then ok "$2"; else bad "$2 (pattern not found: $1)"; fi
}

# between START END NEEDLE LABEL — NEEDLE must appear on some line at or after
# the line matching START (inclusive) and before the line matching END
# (exclusive). Proves a claim lives in the RIGHT section, not just anywhere.
between() {
  local start="$1" end="$2" needle="$3" label="$4" region
  region="$(awk -v s="$start" -v e="$end" '
    $0 ~ s { f=1 }
    f && $0 ~ e { exit }
    f { print }
  ' "$FILE")"
  if printf '%s' "$region" | grep -qF -- "$needle"; then
    ok "$label"
  else
    bad "$label (not found between /$start/ and /$end/)"
  fi
}

S2A='^### 2a\. Domain Identification'
S2B='^### 2b\. Skill Matching'
S2C='^### 2c\. Auto-Install Required Plugins'
S4A='^### 4a\. Agent Types'
S4B='^### 4b\. Spawning Strategy'

echo "[1] §2a Domain Identification names the research/web domain with concrete triggers"
between "$S2A" "$S2B" '**research/web**'            "§2a lists a research/web domain"
between "$S2A" "$S2B" 'a URL in the prompt'          "§2a trigger: a URL in the prompt"
between "$S2A" "$S2B" 'look up'                      "§2a trigger: look up / research phrasing"
between "$S2A" "$S2B" 'latest version of'            "§2a trigger: latest version of"
between "$S2A" "$S2B" 'CVE'                          "§2a trigger: CVE lookup"
between "$S2A" "$S2B" 'compare library'              "§2a trigger: compare library A vs B"
between "$S2A" "$S2B" 'absent from this repo'        "§2a trigger: a library/framework/vendor name absent from the repo"

echo "[2] §2b Skill Matching table names the real capability (native tools + hmd web)"
between "$S2B" "$S2C" 'WebSearch'      "§2b names native WebSearch"
between "$S2B" "$S2C" 'WebFetch'       "§2b names native WebFetch"
between "$S2B" "$S2C" 'hmd web fetch'  "§2b names hmd web fetch"
between "$S2B" "$S2C" 'hmd web crawl'  "§2b names hmd web crawl"
between "$S2B" "$S2C" 'hmd web batch'  "§2b names hmd web batch"
between "$S2B" "$S2C" 'hmd web meta'   "§2b names hmd web meta"

echo "[3] §4a Agent Types routes each of the six web-tool-bearing roles by task shape"
between "$S4A" "$S4B" '| Research: library/approach evaluation | `hmd:architect` |'          "§4a routes library/approach evaluation -> hmd:architect"
between "$S4A" "$S4B" '| Research: engine/extension comparison | `hmd:database-architect` |' "§4a routes engine/extension comparison -> hmd:database-architect"
between "$S4A" "$S4B" '| Research: CVE/advisory lookup | `hmd:security-auditor` |'            "§4a routes CVE/advisory lookup -> hmd:security-auditor"
between "$S4A" "$S4B" '| Research: upstream API docs | `hmd:docs-writer` |'                  "§4a routes upstream API docs -> hmd:docs-writer"
between "$S4A" "$S4B" '| Research: status page, time-pressured | `hmd:incident-responder` |'  "§4a routes status page under time pressure -> hmd:incident-responder"
between "$S4A" "$S4B" '| Research: upstream issue signature | `hmd:seeker` |'                 "§4a routes upstream issue signature -> hmd:seeker"

echo "[4] the six routing targets actually carry the tools the routing table promises"
for agent in architect database-architect security-auditor docs-writer incident-responder seeker; do
  AF="$ROOT/agents/$agent.md"
  if [ ! -f "$AF" ]; then
    bad "agents/$agent.md missing — §4a routes research to a role that doesn't exist"
    continue
  fi
  toolline="$(grep -m1 '^tools:' "$AF")"
  if printf '%s' "$toolline" | grep -q 'WebSearch' && printf '%s' "$toolline" | grep -q 'WebFetch'; then
    ok "agents/$agent.md really carries WebSearch+WebFetch (routing target is real)"
  else
    bad "agents/$agent.md tools: line lacks WebSearch/WebFetch — §4a routes research to a role without the capability: $toolline"
  fi
done

echo "[5] the orchestrator stays delegate-only; the four judges stay untouched"
orch_tools="$(grep -m1 '^tools:' "$FILE")"
if printf '%s' "$orch_tools" | grep -q 'WebSearch\|WebFetch'; then
  bad "agents/heimdall.md tools: line now carries WebSearch/WebFetch — orchestrator should delegate, not browse: $orch_tools"
else
  ok "agents/heimdall.md tools: line carries no WebSearch/WebFetch (delegates, never browses itself)"
fi
have 'orchestrator itself carries no `WebSearch`/`WebFetch`' \
  "doc states the delegate-only decision explicitly, not just by omission"
for judge in verifier reviewer lint-quality test-runner; do
  JF="$ROOT/agents/$judge.md"
  [ -f "$JF" ] || { bad "agents/$judge.md missing"; continue; }
  jtools="$(grep -m1 '^tools:' "$JF")"
  if printf '%s' "$jtools" | grep -q 'WebSearch\|WebFetch'; then
    bad "agents/$judge.md unexpectedly carries WebSearch/WebFetch — judges must stay web-free: $jtools"
  else
    ok "agents/$judge.md still carries no WebSearch/WebFetch (judge stays deterministic)"
  fi
done
have 'Never route research to `hmd:verifier`, `hmd:reviewer`, `hmd:lint-quality`, or `hmd:test-runner`' \
  "doc explicitly forbids routing research to any judge"

echo "[6] red-proof — the same style of check DOES fail on input missing the marker"
TMP="$(mktemp "${TMPDIR:-/tmp}/hmd-web-route-XXXXXX")"
trap 'rm -f "$TMP"' EXIT INT TERM
printf 'this fixture deliberately omits the research routing markers\n' > "$TMP"
if grep -qF -- '**research/web**' "$TMP"; then
  bad "red-proof: detector reported a marker present in a fixture that omits it"
else
  ok "red-proof: detector correctly reports research/web absent from a fixture that omits it"
fi
printf '%s\n' '**research/web**' >> "$TMP"
if grep -qF -- '**research/web**' "$TMP"; then
  ok "red-proof: same detector correctly flips to present once the marker is added back"
else
  bad "red-proof: detector failed to find a marker that was just written"
fi

echo ""
echo "heimdall-web-research-routing.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
