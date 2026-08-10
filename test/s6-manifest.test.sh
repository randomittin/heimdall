#!/usr/bin/env bash
# test/s6-manifest.test.sh — spec->runner manifest ADAPTER acceptance test.
#
# Proves bin/heimdall-s6-manifest converts the C3 spec OBJECT (.repos[], keyed
# `url`/`language`/...) into the runner's FLAT ARRAY (keyed `repo_url`/`lang`/...)
# and that the output is a manifest bin/heimdall-s6-sweep accepts — all WITHOUT a
# single model run, clone, or token (dry-run + pure data-transform only).
#
# Asserted:
#   (a) the converter on the REAL spec emits a valid JSON array of EXACTLY 10
#       entries (jq 'length==10').
#   (b) every entry carries repo_url (non-empty), sha (40-hex), task_prompt,
#       baseline_cmd, assertion_cmd.
#   (c) url -> repo_url is mapped correctly for a sample entry (slugify).
#   (d) reuse_measured:false is carried for cobra + anyhow; true for the other 8.
#   (e) a spec entry MISSING `sha` is REJECTED fail-closed (exit 2), emitting
#       nothing (preserves the SHA-pin discipline).
#   (f) END-TO-END GLUE: `heimdall-s6-manifest <spec> | heimdall-s6-sweep
#       --manifest - --dry-run` is accepted by the sweep and prints its 10-entry
#       plan — NO clone, NO hmd, NO spend (dry-run only).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONV="$ROOT/bin/heimdall-s6-manifest"
SWEEP="$ROOT/bin/heimdall-s6-sweep"
SPEC="$ROOT/docs/superpowers/specs/heimdall-S6-C3-repos.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the JSON assertions" >&2; exit 2; }
[ -x "$CONV" ]  || { echo "FATAL: converter not executable at $CONV" >&2; exit 2; }
[ -x "$SWEEP" ] || { echo "FATAL: sweep harness not executable at $SWEEP" >&2; exit 2; }
[ -f "$SPEC" ]  || { echo "FATAL: spec not found at $SPEC" >&2; exit 2; }

WORK="$(mktemp -d -t s6-manifest-test)"
trap 'rm -rf "$WORK"' EXIT

# Convert the REAL spec once; reuse the output across assertions.
OUT="$WORK/manifest.json"
set +e
"$CONV" "$SPEC" > "$OUT" 2>"$WORK/conv.err"
CONV_RC=$?
set -e

# ─────────────────────────────────────────────────────────────────────────────
# (a) valid JSON array of EXACTLY 10 entries.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$CONV_RC" -eq 0 ] && jq -e 'type=="array" and length==10' "$OUT" >/dev/null 2>&1; then
  ok "(a) converter emits a valid JSON array of exactly 10 entries"
else
  bad "(a) converter did not emit 10 entries (rc=$CONV_RC, len=$(jq 'length' "$OUT" 2>/dev/null))"
  cat "$WORK/conv.err"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (b) every entry has repo_url(non-empty), sha(40-hex), task_prompt, baseline_cmd,
#     assertion_cmd — the two RUNNABLE acceptance commands (no prose).
# ─────────────────────────────────────────────────────────────────────────────
if jq -e '
    all(.[];
      (.repo_url | type=="string" and (.|length)>0)
      and (.sha | type=="string" and test("^[0-9a-f]{40}$"))
      and (.task_prompt | type=="string" and (.|length)>0)
      and (.baseline_cmd | type=="string" and (.|length)>0)
      and (.assertion_cmd | type=="string" and (.|length)>0))
  ' "$OUT" >/dev/null 2>&1; then
  ok "(b) every entry has repo_url(non-empty) + sha(40-hex) + task_prompt + baseline_cmd + assertion_cmd"
else
  bad "(b) some entry is missing a required field or has a bad sha"
  jq -c '.[] | {repo_url, sha, task_prompt:(.task_prompt[0:20]), baseline_cmd:(.baseline_cmd[0:20]), assertion_cmd:(.assertion_cmd[0:20])}' "$OUT"
fi

# the old single prose `acceptance_cmd` must be GONE — proving the v2 split landed.
if jq -e 'all(.[]; has("acceptance_cmd") | not)' "$OUT" >/dev/null 2>&1; then
  ok "(b2) old prose acceptance_cmd dropped from every entry (eval-on-prose landmine removed)"
else
  bad "(b2) acceptance_cmd still present on some entry"
  jq -c '.[] | {repo_url, acceptance_cmd}' "$OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (c) url -> repo_url mapped correctly for a sample (slugify).
# ─────────────────────────────────────────────────────────────────────────────
SPEC_URL="$(jq -r '.repos[] | select(.id=="slugify") | .url' "$SPEC")"
MAN_URL="$(jq -r '.[] | select(.repo_url|test("/slugify$")) | .repo_url' "$OUT")"
if [ -n "$SPEC_URL" ] && [ "$SPEC_URL" = "$MAN_URL" ]; then
  ok "(c) url->repo_url mapped correctly for slugify ($MAN_URL)"
else
  bad "(c) url->repo_url mapping wrong for slugify (spec='$SPEC_URL' manifest='$MAN_URL')"
fi

# also prove language -> lang carried for the same sample.
SPEC_LANG="$(jq -r '.repos[] | select(.id=="slugify") | .language' "$SPEC")"
MAN_LANG="$(jq -r '.[] | select(.repo_url|test("/slugify$")) | .lang' "$OUT")"
if [ "$SPEC_LANG" = "$MAN_LANG" ] && [ -n "$MAN_LANG" ]; then
  ok "(c2) language->lang carried for slugify ($MAN_LANG)"
else
  bad "(c2) language->lang mapping wrong (spec='$SPEC_LANG' manifest='$MAN_LANG')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (d) reuse_measured:false carried for cobra + anyhow; true for the other 8.
# ─────────────────────────────────────────────────────────────────────────────
FALSE_URLS="$(jq -r '[.[] | select(.reuse_measured==false) | (.repo_url|split("/")|last)] | sort | join(",")' "$OUT")"
TRUE_N="$(jq -r '[.[] | select(.reuse_measured==true)] | length' "$OUT")"
if [ "$FALSE_URLS" = "anyhow,cobra" ] && [ "$TRUE_N" = "8" ]; then
  ok "(d) reuse_measured:false carried for cobra+anyhow; true for the other 8 (none dropped)"
else
  bad "(d) reuse_measured carry-through wrong (false=[$FALSE_URLS] true_count=$TRUE_N)"
  jq -c '.[] | {repo_url:(.repo_url|split("/")|last), reuse_measured}' "$OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (e) a spec entry MISSING `sha` is REJECTED fail-closed (exit 2), emits nothing.
# ─────────────────────────────────────────────────────────────────────────────
# Strip the sha from the first repo entry → a pinless spec → must fail-closed.
PINLESS_SPEC="$WORK/pinless-spec.json"
jq 'del(.repos[0].sha)' "$SPEC" > "$PINLESS_SPEC"
set +e
"$CONV" "$PINLESS_SPEC" > "$WORK/pinless.out" 2>"$WORK/pinless.err"
PINLESS_RC=$?
set -e
PINLESS_BYTES="$(wc -c < "$WORK/pinless.out" | tr -d ' ')"
if [ "$PINLESS_RC" -eq 2 ] \
   && grep -qiE 'sha' "$WORK/pinless.err" \
   && [ "$PINLESS_BYTES" = "0" ]; then
  ok "(e) spec entry missing sha rejected fail-closed (exit 2), emits nothing"
else
  bad "(e) pinless spec not rejected fail-closed (rc=$PINLESS_RC, stdout bytes=$PINLESS_BYTES)"
  cat "$WORK/pinless.err"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (f) END-TO-END GLUE: converter | sweep --manifest - --dry-run prints 10-entry
#     plan, NO clone, NO hmd, NO spend.
# ─────────────────────────────────────────────────────────────────────────────
set +e
GLUE_OUT="$("$CONV" "$SPEC" | "$SWEEP" --manifest - --dry-run 2>&1)"
GLUE_RC=$?
set -e
# the dry-run banner says "entries : 10" and lists all 10 repo rows; assert both
# the count line and that every spec repo_url appears in the printed plan.
ALL_URLS_PRESENT=1
while IFS= read -r short; do
  grep -q "$short" <<<"$GLUE_OUT" || ALL_URLS_PRESENT=0
done < <(jq -r '.repos[] | (.url|split("/")|last)' "$SPEC")
if [ "$GLUE_RC" -eq 0 ] \
   && grep -qiE 'dry.?run' <<<"$GLUE_OUT" \
   && grep -qE 'entries[[:space:]]*:[[:space:]]*10' <<<"$GLUE_OUT" \
   && [ "$ALL_URLS_PRESENT" = "1" ]; then
  ok "(f) glue: converter | sweep --manifest - --dry-run accepts + prints the 10-entry plan (no clone/hmd/spend)"
else
  bad "(f) end-to-end glue failed (rc=$GLUE_RC, all_urls=$ALL_URLS_PRESENT)"
  printf '%s\n' "$GLUE_OUT"
fi

echo
echo "  s6-manifest adapter tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
