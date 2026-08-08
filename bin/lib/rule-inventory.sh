#!/usr/bin/env bash
# rule-inventory.sh — EVERY NORMATIVE RULE, WITH A VERDICT. NO SILENT EXEMPTION.
#
# The frugal brief states the honesty rule this file implements:
#
#     "a protocol that can't be checked gets a line saying so rather than
#      silent exemption."
#
# So an unenforceable rule must be VISIBLY unenforceable. The failure mode this
# prevents is the one that let the brief sit unwired for two months: a rule that
# nobody checks and nobody LISTS reads exactly like a rule that passes.
#
# HOW COMPLETENESS IS GUARANTEED
# ------------------------------
# The rule list is EXTRACTED, never hand-maintained. A hand-written inventory
# drifts the moment someone adds a rule, and the drift is invisible. Here:
#
#   1. `rule_extract` scans the source documents and emits every normative line.
#   2. `rule_classify` gives each extracted line a verdict from a small table.
#   3. The verdict table has NO default-pass. A rule matching no CHECKED pattern
#      falls to its source file's declared UNCHECKABLE class, and every class
#      must carry a reason string. A file with no declared class yields
#      UNCLASSIFIED, which the gate treats as a failure.
#
# So a new rule cannot be silently absent: it is extracted automatically, and it
# either matches a check or is printed under a stated reason.
#
# WHAT COUNTS AS A NORMATIVE LINE — stated openly so the extractor is auditable
# A list item, numbered step, table row, or bold directive that contains a
# normative token (MUST / NEVER / ALWAYS / MANDATORY / REQUIRED / SHALL /
# NON-NEGOTIABLE, or lowercase must / never / always / cannot / required /
# "do not" / "don't" / "may not"). Fenced code blocks are excluded — a code
# sample that contains the word "never" is not a rule.

RULE_SOURCES_DEFAULT="PROTOCOL.md CLAUDE.md AGENTS.md agents"

# The normative-token test, as one ERE.
RULE_TOKEN_RE='(MUST|NEVER|ALWAYS|MANDATORY|REQUIRED|SHALL|NON-NEGOTIABLE|[^A-Za-z]must[^A-Za-z]|[^A-Za-z]never[^A-Za-z]|[^A-Za-z]always[^A-Za-z]|[^A-Za-z]cannot[^A-Za-z]|[^A-Za-z]required[^A-Za-z]|[^A-Za-z]do not[^A-Za-z]|[^A-Za-z]may not[^A-Za-z]|don.t)'

# ── the verdict table ────────────────────────────────────────────────────────
# CHECKED rows:   <ere-on-rule-text>|<enforcer>
# Order matters only in that the first match wins.
rule_checked_table() {
  cat <<'TBL'
[Ee]ach completed task = one atomic git commit|test/conformance-commit-per-unit.test.sh
[Oo]ne completed task = one atomic commit|test/conformance-commit-per-unit.test.sh
commit in-worktree|test/conformance-commit-per-unit.test.sh
[Nn]ever the plan, prior conversation|test/conformance-brief-routing.test.sh
delta brief|test/conformance-brief-routing.test.sh
heimdall-brief|test/conformance-brief-routing.test.sh
brief INCOMPLETE|test/brief-fail-closed.test.sh
NON_VERIFIED|test/brief-fail-closed.test.sh
cannot drift into disagreeing|test/brief-fail-closed.test.sh
capsule that would exceed 10 lines|bin/protocol/test-protocol.sh
only protocol component that reads|bin/protocol/test-protocol.sh
[Nn]ever write stub|hooks/hooks.json PreToolUse content scan
[Nn]o .* TODO|hooks/hooks.json PreToolUse content scan
production-ready|hooks/hooks.json PreToolUse content scan
[Aa]ll tests passing|hooks/hooks.json PreToolUse git-push gate
[Ll]int clean|hooks/hooks.json PreToolUse git-push gate
[Qq]uality [Gg]ates|hooks/hooks.json PreToolUse git-push gate
before .*git push|hooks/hooks.json PreToolUse git-push gate
name:|hooks/hooks.json PreToolUse Agent R13 warn
[Ss]ession[- ]start|test/session-start-order.test.sh
checkpoint|test/session-start-order.test.sh
TBL
}

# UNCHECKABLE class per source path prefix: <path-prefix>|<class>|<reason>
rule_unchecked_table() {
  cat <<'TBL'
agents/|agent-instruction|An instruction to a model about how to reason, when to escalate, or what to say. It constrains a decision process, not an artifact on disk, so there is no post-hoc evidence a script could inspect. Enforcement is the model reading it.
PROTOCOL.md|protocol-untraced|bin/protocol/test-protocol.sh asserts 55 protocol properties, but its assertions are not mapped one-to-one onto these rule lines, so this specific sentence is not individually traceable to an assertion. Claiming it CHECKED would be the overclaim this repo exists to catch.
CLAUDE.md|house-convention|A convention about how a human or model should work in this repo (style, token budget, file placement). No artifact records compliance, so there is nothing to verify after the fact.
AGENTS.md|house-convention|A convention about how a human or model should work in this repo (style, token budget, file placement). No artifact records compliance, so there is nothing to verify after the fact.
TBL
}

# ── extraction ───────────────────────────────────────────────────────────────
# rule_extract <repo> [sources...]  ->  <file>\t<line>\t<text>
rule_extract() {
  local repo="$1"; shift
  local sources="${*:-$RULE_SOURCES_DEFAULT}"
  local s f
  for s in $sources; do
    if [ -d "$repo/$s" ]; then
      for f in "$repo/$s"/*.md; do
        [ -f "$f" ] || continue
        _rule_extract_file "$repo" "${f#$repo/}"
      done
    elif [ -f "$repo/$s" ]; then
      _rule_extract_file "$repo" "$s"
    fi
  done
}

_rule_extract_file() {
  local repo="$1" rel="$2"
  awk -v rel="$rel" -v tok="$RULE_TOKEN_RE" '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      # list item, numbered step, table row, or bold directive only
      if (line !~ /^[[:space:]]*([-*+]|[0-9]+\.|\||\*\*)/) next
      if (length(line) < 25) next
      if (line !~ tok) next
      gsub(/\t/, " ", line)
      sub(/^[[:space:]]+/, "", line)
      printf "%s\t%d\t%s\n", rel, NR, line
    }
  ' "$repo/$rel"
}

# ── classification ───────────────────────────────────────────────────────────
# rule_classify <file> <text> -> "CHECKED\t<enforcer>" | "UNCHECKABLE\t<class>: <reason>" | "UNCLASSIFIED\t"
rule_classify() {
  local file="$1" text="$2" pat enf prefix class reason
  while IFS='|' read -r pat enf; do
    [ -n "${pat:-}" ] || continue
    if printf '%s' "$text" | grep -qE "$pat"; then
      printf 'CHECKED\t%s' "$enf"; return 0
    fi
  done <<EOF
$(rule_checked_table)
EOF
  while IFS='|' read -r prefix class reason; do
    [ -n "${prefix:-}" ] || continue
    case "$file" in "$prefix"*) printf 'UNCHECKABLE\t%s: %s' "$class" "$reason"; return 0 ;; esac
  done <<EOF
$(rule_unchecked_table)
EOF
  printf 'UNCLASSIFIED\t'
}

# ── the public entry point ───────────────────────────────────────────────────
# rule_inventory [--write]
#   default : print the inventory as TSV  (verdict, detail, file:line, text)
#   --write : regenerate the markdown artifact in place
rule_inventory() {
  local write=0
  [ "${1:-}" = "--write" ] && write=1

  local rows
  rows="$(rule_extract "$REPO")"
  local total
  total="$(printf '%s' "$rows" | grep -c '[^[:space:]]')"
  # ANTI-VACUOUS: an inventory over zero rules is not an empty rulebook, it is a
  # broken extractor — and it would report "every rule accounted for".
  if [ "${total:-0}" -lt 50 ]; then
    printf 'NON_VERIFIED\trule extractor found only %s rule(s) in %s — expected the full rulebook, the extractor is broken\n' "${total:-0}" "$REPO" >&2
    return 3
  fi

  local out f l t verdict detail checked=0 unchecked=0 unclassified=0
  out="$(mktemp "${TMPDIR:-/tmp}/hmdrules.XXXXXX")"
  while IFS=$'\t' read -r f l t; do
    [ -n "${f:-}" ] || continue
    IFS=$'\t' read -r verdict detail <<EOF2
$(rule_classify "$f" "$t")
EOF2
    case "$verdict" in
      CHECKED)      checked=$((checked + 1)) ;;
      UNCHECKABLE)  unchecked=$((unchecked + 1)) ;;
      *)            unclassified=$((unclassified + 1)) ;;
    esac
    printf '%s\t%s\t%s:%s\t%s\n' "$verdict" "$detail" "$f" "$l" "$t" >>"$out"
  done <<EOF
$rows
EOF

  if [ "$write" -eq 1 ]; then
    _rule_write_artifact "$out" "$total" "$checked" "$unchecked" "$unclassified"
  else
    cat "$out"
    printf 'SUMMARY\ttotal=%s checked=%s uncheckable=%s unclassified=%s\n' \
      "$total" "$checked" "$unchecked" "$unclassified"
  fi
  rm -f "$out"
  [ "$unclassified" -eq 0 ] || return 1
  return 0
}

RULE_ARTIFACT_REL="skills/heimdall/references/protocol-rule-inventory.md"

_rule_write_artifact() {
  local rows="$1" total="$2" checked="$3" unchecked="$4" unclassified="$5"
  local art="$REPO/$RULE_ARTIFACT_REL" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/hmdart.XXXXXX")"

  {
    cat <<HDR
# Protocol rule inventory

Every normative rule in this repo's rulebook, with a verdict: **CHECKED** (an
executable gate enforces it, named) or **UNCHECKABLE** (nothing mechanically
observes it, with the reason stated).

This exists because of the honesty rule in the token-frugal brief: *"a protocol
that can't be checked gets a line saying so rather than silent exemption."* A
rule nobody checks and nobody lists reads exactly like a rule that passes. Every
rule below is listed either way, so an unenforceable rule is visibly
unenforceable.

<!-- HEIMDALL:RULE-INVENTORY:BEGIN -->
<!-- GENERATED by \`bin/heimdall-conformance inventory --write\` — do not hand-edit. -->
<!-- Regenerate after any rulebook change; test/conformance-inventory.test.sh fails if this drifts. -->

Sources scanned: \`$RULE_SOURCES_DEFAULT\`

| verdict | count |
|---|---|
| CHECKED | $checked |
| UNCHECKABLE | $unchecked |
| UNCLASSIFIED | $unclassified |
| **total** | **$total** |

## CHECKED — an executable gate enforces this

| rule | source | enforced by |
|---|---|---|
HDR
    awk -F'\t' '$1=="CHECKED"{gsub(/\|/,"\\|",$4); gsub(/\|/,"\\|",$2); printf "| %s | `%s` | `%s` |\n", $4, $3, $2}' "$rows"

    printf '\n## UNCHECKABLE — nothing mechanically observes this, and why\n\n'
    printf '| rule | source | class | why not checkable |\n|---|---|---|---|\n'
    awk -F'\t' '$1=="UNCHECKABLE"{
      gsub(/\|/,"\\|",$4);
      split($2, p, ": ");
      cls = p[1];
      reason = substr($2, length(cls) + 3);
      gsub(/\|/,"\\|",reason);
      printf "| %s | `%s` | %s | %s |\n", $4, $3, cls, reason
    }' "$rows"

    local nunc
    nunc="$(awk -F'\t' '$1=="UNCLASSIFIED"' "$rows" | grep -c '[^[:space:]]')"
    if [ "${nunc:-0}" -gt 0 ]; then
      printf '\n## UNCLASSIFIED — a rule with no verdict. This is a gate failure.\n\n'
      printf '| rule | source |\n|---|---|\n'
      awk -F'\t' '$1=="UNCLASSIFIED"{gsub(/\|/,"\\|",$4); printf "| %s | `%s` |\n", $4, $3}' "$rows"
    fi

    printf '\n<!-- HEIMDALL:RULE-INVENTORY:END -->\n'
  } >"$tmp"

  mv "$tmp" "$art"
  printf 'wrote\t%s\ttotal=%s checked=%s uncheckable=%s unclassified=%s\n' \
    "$RULE_ARTIFACT_REL" "$total" "$checked" "$unchecked" "$unclassified"
}
