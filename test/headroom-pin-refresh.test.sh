#!/usr/bin/env bash
#
# headroom-pin-refresh.test.sh — acceptance for the 2026-08-19 headroom-ai
# 0.33.0 -> 0.35.0 pin refresh in modules/headroom/manifest.json, and for the
# accompanying kompress health/log-discrepancy finding recorded in
# docs/analysis/headroom-did-it-help.md.
#
# WHY THIS SUITE EXISTS RATHER THAN RELYING ON test/headroom-module.test.sh
# ALONE. That suite's H0/H7 checks are deliberately FORMAT-only — 64 lowercase
# hex — because bin/heimdall-modules' own install_module() never verifies this
# digest against anything downloaded for an `installs_via.kind: upstream`
# module (bin/heimdall-modules:971-978: "the upstream branch hashes NOTHING...
# the pin is RECORDED rather than checked"). A wrong-but-well-formed digest
# would sail through H0 and H7 both. This suite is the one that checks the
# VALUE, cross-referenced against what PyPI itself reports for the exact
# pinned filename — from two independent PyPI surfaces (the JSON API and the
# PEP 503 simple index), fetched once during the investigation that produced
# this pin and hardcoded here rather than re-fetched live on every run (a test
# must be hermetic — AGENTS.md — and a live PyPI dependency in a test loop is
# exactly the kind of flake that principle exists to rule out).
#
# Guarantees proved:
#   P1  pinned_version.version / .artifact / .artifact_sha256 in the shipped
#       manifest are internally consistent AND match the exact values this
#       investigation verified against PyPI (both surfaces agreed, digest is
#       not yanked).
#   P2  FALSIFIER for P1 — a wrong-but-well-formed digest (still 64 lowercase
#       hex, so it would still pass headroom-module.test.sh's H0/H7 format
#       checks untouched) is caught by THIS suite's value comparison. Proves
#       P1 checks the VALUE, not just that a check ran.
#   P3  the storage-codec re-verification note (permission_class_note and the
#       storage-codec-backend wire detail) carries 2026-08-19 evidence and
#       names the 0.35.0 pin — it does not silently carry the 2026-08-04/
#       0.33.0 measurement forward unedited with no fresh date.
#   P4  the superseded 0.33.0 digest string does not linger anywhere in the
#       manifest (e.g. copy-pasted into prose and never swapped).
#   Q1  the kompress health-vs-log discrepancy this session found under real
#       traffic is recorded in docs/analysis/headroom-did-it-help.md, with
#       the specific evidence anchors this investigation actually produced
#       (the null-backend health readout, the onnx log lines, the live
#       /debug/warmup readout, and the source-level function it traced to) —
#       not just a vague "looked into it".
#
# Usage:  bash test/headroom-pin-refresh.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
MANIFEST="$REPO/modules/headroom/manifest.json"
DOC="$REPO/docs/analysis/headroom-did-it-help.md"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
cd "$REPO" || exit 2

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# The values this investigation verified against PyPI on 2026-08-19:
#   curl -s https://pypi.org/pypi/headroom-ai/0.35.0/json           (JSON API)
#   curl -s https://pypi.org/simple/headroom-ai/                    (PEP 503)
# both reported the same sha256 for the sdist filename below; `yanked: false`
# on both the release and every one of its six files.
EXPECT_VERSION="0.35.0"
EXPECT_ARTIFACT="headroom_ai-0.35.0.tar.gz"
EXPECT_SHA256="79f61a032f36608bf60eceec8411f9e94e28c889bf535ef02e893529733c0ce9"
OLD_SHA256="97d817e5923903d72bed24f75e0424e9cb7f86b3ddde0fc1acec4f3f85deeb5a"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The value-level check this suite exists to add. Operates on whatever
# manifest path is passed in, so the falsifier arm (P2) can point it at a
# mutated temp copy without ever touching the shipped file.
check_pin_matches() {
  local mf="$1"
  local v a s
  v="$(jq -r '.pinned_version.version' "$mf")"
  a="$(jq -r '.pinned_version.artifact' "$mf")"
  s="$(jq -r '.pinned_version.artifact_sha256' "$mf")"
  [ "$v" = "$EXPECT_VERSION" ] && [ "$a" = "$EXPECT_ARTIFACT" ] && [ "$s" = "$EXPECT_SHA256" ]
}

echo
echo "P1 — the shipped pin matches the PyPI-verified 0.35.0 values"
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  && ok "manifest is valid JSON" || bad "manifest is not valid JSON"
[ "$(jq -r '.pinned_version.version' "$MANIFEST")" = "$EXPECT_VERSION" ] \
  && ok "pinned_version.version is $EXPECT_VERSION" \
  || bad "pinned_version.version is $(jq -r '.pinned_version.version' "$MANIFEST"), expected $EXPECT_VERSION"
[ "$(jq -r '.pinned_version.artifact' "$MANIFEST")" = "$EXPECT_ARTIFACT" ] \
  && ok "pinned_version.artifact is $EXPECT_ARTIFACT" \
  || bad "pinned_version.artifact does not match $EXPECT_ARTIFACT"
[ "$(jq -r '.pinned_version.artifact_sha256' "$MANIFEST")" = "$EXPECT_SHA256" ] \
  && ok "pinned_version.artifact_sha256 matches the PyPI-reported sdist digest" \
  || bad "pinned_version.artifact_sha256 does not match the verified PyPI digest"
check_pin_matches "$MANIFEST" \
  && ok "check_pin_matches() holds against the real, shipped manifest" \
  || bad "check_pin_matches() rejects the real manifest"

echo
echo "P2 — FALSIFIER: a wrong-but-well-formed digest is caught by the VALUE check"
# A copy, never the tree — mirrors test/headroom-module.test.sh's own
# mutate-a-copy discipline so an interrupted run can never corrupt the real file.
cp "$MANIFEST" "$TMP/manifest.json"
# Still 64 lowercase hex (would still pass H0/H7's format-only checks) but a
# different value — proves this suite checks the VALUE, not the shape.
WRONG_BUT_WELLFORMED="$(printf '%064d' 0)"
printf '%s' "$WRONG_BUT_WELLFORMED" | grep -qE '^[0-9a-f]{64}$' \
  && ok "the falsifier's mutated digest is itself well-formed 64-hex (so it isolates the value check)" \
  || bad "the falsifier's own mutated digest is not well-formed — arm is invalid"
jq --arg s "$WRONG_BUT_WELLFORMED" '.pinned_version.artifact_sha256 = $s' "$MANIFEST" > "$TMP/mutated.json"
if check_pin_matches "$TMP/mutated.json"; then
  bad "RED ARM DID NOT GO RED — a wrong digest was accepted as matching"
else
  ok "RED ARM: a wrong-but-well-formed digest is correctly rejected by check_pin_matches()"
fi
check_pin_matches "$TMP/manifest.json" \
  && ok "GREEN ARM: the unmutated copy still matches — the check is not just always-false" \
  || bad "GREEN ARM FAILED: the unmutated copy no longer matches (check is broken)"

echo
echo "P3 — the storage-codec re-verification is dated to this pin, not carried forward"
NOTE="$(jq -r '.permission_class_note' "$MANIFEST")"
WIRE_DETAIL="$(jq -r '.wires[] | select(.kind=="storage-codec-backend") | .detail' "$MANIFEST")"
PROV="$(jq -r '.pinned_version.pin_provenance' "$MANIFEST")"
grep -q '2026-08-19' <<<"$NOTE" \
  && ok "permission_class_note carries a 2026-08-19 re-verification date" \
  || bad "permission_class_note has no 2026-08-19 date — looks carried forward unedited"
grep -q '0\.35\.0' <<<"$NOTE" \
  && ok "permission_class_note names the 0.35.0 pin it was re-verified against" \
  || bad "permission_class_note does not name 0.35.0"
grep -q '2026-08-19' <<<"$WIRE_DETAIL" \
  && ok "the storage-codec-backend wire detail carries a 2026-08-19 date" \
  || bad "the wire detail has no 2026-08-19 date"
grep -q '2026-08-19' <<<"$PROV" \
  && ok "pin_provenance itself is dated 2026-08-19" \
  || bad "pin_provenance is not dated 2026-08-19"

echo
echo "P4 — the superseded 0.33.0 digest does not linger in the manifest"
grep -qF "$OLD_SHA256" "$MANIFEST" \
  && bad "the OLD 0.33.0 digest is still present somewhere in the manifest" \
  || ok "the old 0.33.0 digest is gone — no stale copy-paste left behind"

echo
echo "Q1 — the kompress health/log discrepancy finding is recorded"
if [ -f "$DOC" ]; then
  ok "docs/analysis/headroom-did-it-help.md exists"
  DOCTXT="$(cat "$DOC")"
  grep -qF '"backend":null' <<<"$DOCTXT" \
    && ok "the doc quotes the null-backend /health readout" \
    || bad "the doc does not quote the null-backend /health field"
  grep -qF 'backend=onnx' <<<"$DOCTXT" \
    && ok "the doc quotes real onnx compression log lines" \
    || bad "the doc does not quote onnx log evidence"
  grep -qF '/debug/warmup' <<<"$DOCTXT" \
    && ok "the doc cites the live /debug/warmup confirmation" \
    || bad "the doc does not cite /debug/warmup"
  grep -qF '_reconcile_kompress_health' <<<"$DOCTXT" \
    && ok "the doc names the source-level function the discrepancy was traced to" \
    || bad "the doc does not name _reconcile_kompress_health"
else
  bad "docs/analysis/headroom-did-it-help.md is missing"
fi

echo
echo "--------------------------------------------------------------------"
printf 'headroom-pin-refresh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
