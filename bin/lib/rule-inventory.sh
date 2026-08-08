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
#   4. A CHECKED row's enforcer is CONFIRMED ON DISK before the verdict is
#      issued. A named falsifier that does not exist enforces nothing, so the
#      row reads NON_VERIFIED instead — never CHECKED, never quietly demoted to
#      UNCHECKABLE (which would launder the overclaim into "unobservable by
#      design"), never omitted.
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

# ── enforcer existence ───────────────────────────────────────────────────────
# A CHECKED verdict names a falsifier. If that file is not on disk, NOTHING
# enforces the rule and the verdict is an overclaim — the exact failure this
# inventory exists to catch, living inside the inventory. So the name is
# resolved against the filesystem, never trusted.
#
# THE ENFORCER FIELD is "<path>[ <human descriptor>]". The hooks rows name
# hooks/hooks.json plus WHICH hook inside it; the leading path is the only part
# a filesystem can confirm, so that is what is confirmed.
#
# RESOLVED AGAINST HEIMDALL'S OWN CHECKOUT, never the scanned rulebook. The
# table hardcodes this repo's suites, hooks and tools, so pointing the extractor
# at another project must not report every enforcer missing — that would be a
# false NON_VERIFIED, which is its own kind of lie. `pwd -P` because the suites
# symlink bin/lib into fixture trees: the enforcers live where the code really
# is, not where it was reached from.
RULE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RULE_ENFORCER_ROOT="${RULE_ENFORCER_ROOT:-$(cd "$RULE_LIB_DIR/../.." && pwd -P)}"

# rule_enforcer_path <enforcer-field> -> the on-disk path it names
rule_enforcer_path() { printf '%s' "${1%% *}"; }

# rule_enforcer_present <root> <enforcer-field> -> 0 when the named file exists
rule_enforcer_present() {
  local p
  p="$(rule_enforcer_path "$2")"
  [ -n "$p" ] && [ -e "$1/$p" ]
}

# rule_enforcer_audit [root] -> one row per verdict-table entry:
#   <PRESENT|MISSING>\t<enforcer path>\t<rule pattern>
# exits: 0 every enforcer on disk · 1 at least one missing · 3 NON_VERIFIED
#
# ANTI-VACUOUS: a table that yields zero rows is a BROKEN table, not a clean
# one. An audit that scanned nothing would report "no missing enforcers" — the
# vacuous green this whole file was written to refuse — so it is loud instead.
rule_enforcer_audit() {
  local root="${1:-$RULE_ENFORCER_ROOT}" pat enf rows=0 missing=0
  while IFS='|' read -r pat enf; do
    [ -n "${pat:-}" ] || continue
    rows=$((rows + 1))
    if rule_enforcer_present "$root" "$enf"; then
      printf 'PRESENT\t%s\t%s\n' "$(rule_enforcer_path "$enf")" "$pat"
    else
      missing=$((missing + 1))
      printf 'MISSING\t%s\t%s\n' "$(rule_enforcer_path "$enf")" "$pat"
    fi
  done <<EOF
$(rule_checked_table)
EOF
  if [ "$rows" -eq 0 ]; then
    printf 'NON_VERIFIED\tthe verdict table yielded zero rows — the enforcer audit scanned nothing, which is a broken table and never a clean one\n' >&2
    return 3
  fi
  [ "$missing" -eq 0 ] || return 1
  return 0
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
# rule_classify <file> <text>
#   -> "CHECKED\t<enforcer>"                 the enforcer is named AND on disk
#   -> "NON_VERIFIED\t<enforcer>: <why>"     the enforcer is named and ABSENT
#   -> "UNCHECKABLE\t<class>: <reason>"      nothing observes it, reason stated
#   -> "UNCLASSIFIED\t"                      no verdict at all — a gate failure
#
# FAIL CLOSED. A matched row whose enforcer file is missing does NOT fall
# through to the UNCHECKABLE table: falling through would re-label a broken
# claim as a designed exemption, which is the same lie in a better suit. It
# stops here as NON_VERIFIED, naming the enforcer that is not there.
rule_classify() {
  local file="$1" text="$2" pat enf prefix class reason
  while IFS='|' read -r pat enf; do
    [ -n "${pat:-}" ] || continue
    if printf '%s' "$text" | grep -qE "$pat"; then
      if rule_enforcer_present "$RULE_ENFORCER_ROOT" "$enf"; then
        printf 'CHECKED\t%s' "$enf"
      else
        printf 'NON_VERIFIED\t%s: enforcer MISSING at %s — nothing on disk enforces this rule, and a CHECKED verdict naming a falsifier that does not exist is exactly the overclaim this inventory exists to prevent' \
          "$enf" "$(rule_enforcer_path "$enf")"
      fi
      return 0
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

  local out f l t verdict detail checked=0 unchecked=0 unverified=0 unclassified=0
  out="$(mktemp "${TMPDIR:-/tmp}/hmdrules.XXXXXX")"
  while IFS=$'\t' read -r f l t; do
    [ -n "${f:-}" ] || continue
    IFS=$'\t' read -r verdict detail <<EOF2
$(rule_classify "$f" "$t")
EOF2
    case "$verdict" in
      CHECKED)      checked=$((checked + 1)) ;;
      NON_VERIFIED) unverified=$((unverified + 1)) ;;
      UNCHECKABLE)  unchecked=$((unchecked + 1)) ;;
      *)            unclassified=$((unclassified + 1)) ;;
    esac
    printf '%s\t%s\t%s:%s\t%s\n' "$verdict" "$detail" "$f" "$l" "$t" >>"$out"
  done <<EOF
$rows
EOF

  if [ "$write" -eq 1 ]; then
    _rule_write_artifact "$out" "$total" "$checked" "$unchecked" "$unverified" "$unclassified"
  else
    cat "$out"
    printf 'SUMMARY\ttotal=%s checked=%s uncheckable=%s non_verified=%s unclassified=%s\n' \
      "$total" "$checked" "$unchecked" "$unverified" "$unclassified"
  fi
  rm -f "$out"
  # A rule with no verdict at all is a violation of the table (1). A rule whose
  # enforcer has gone missing is not a violation of the table — it is the repo
  # admitting it does not know whether the rule holds, which is exit 3 under
  # this tool's published contract. Neither may ever exit 0.
  [ "$unclassified" -eq 0 ] || return 1
  [ "$unverified" -eq 0 ] || return 3
  return 0
}

RULE_ARTIFACT_REL="skills/heimdall/references/protocol-rule-inventory.md"

_rule_write_artifact() {
  local rows="$1" total="$2" checked="$3" unchecked="$4" unverified="$5" unclassified="$6"
  local art="$REPO/$RULE_ARTIFACT_REL" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/hmdart.XXXXXX")"

  {
    cat <<HDR
# Protocol rule inventory

Every normative rule in this repo's rulebook, with a verdict: **CHECKED** (an
executable gate enforces it, and that gate is on disk), **NON_VERIFIED** (a gate
is named but the file is absent, so nothing enforces the rule) or
**UNCHECKABLE** (nothing mechanically observes it, with the reason stated).

This exists because of the honesty rule in the token-frugal brief: *"a protocol
that can't be checked gets a line saying so rather than silent exemption."* A
rule nobody checks and nobody lists reads exactly like a rule that passes. Every
rule below is listed either way, so an unenforceable rule is visibly
unenforceable.

<!-- HEIMDALL:RULE-INVENTORY:BEGIN -->
<!-- GENERATED by \`bin/heimdall-conformance inventory --write\` — do not hand-edit. -->
<!-- Regenerate after any rulebook change. NO automated drift gate exists yet: -->
<!-- nothing fails if this file goes stale, so treat it as of its generation date. -->

Sources scanned: \`$RULE_SOURCES_DEFAULT\`

| verdict | count |
|---|---|
| CHECKED | $checked |
| NON_VERIFIED | $unverified |
| UNCHECKABLE | $unchecked |
| UNCLASSIFIED | $unclassified |
| **total** | **$total** |

## CHECKED — an executable gate enforces this, and it is on disk

| rule | source | enforced by |
|---|---|---|
HDR
    awk -F'\t' '$1=="CHECKED"{gsub(/\|/,"\\|",$4); gsub(/\|/,"\\|",$2); printf "| %s | `%s` | `%s` |\n", $4, $3, $2}' "$rows"

    printf '\n## NON_VERIFIED — a gate is NAMED but is not on disk. Nothing enforces these.\n\n'
    printf 'These rules are UNENFORCED. The table claims a falsifier; the filesystem\n'
    printf 'disagrees. They are listed here rather than dropped, because a missing signal\n'
    printf 'reads NON_VERIFIED and never OK.\n\n'
    printf '| rule | source | claimed enforcer |\n|---|---|---|\n'
    awk -F'\t' '$1=="NON_VERIFIED"{
      gsub(/\|/,"\\|",$4);
      split($2, p, ": ");
      printf "| %s | `%s` | `%s` |\n", $4, $3, p[1]
    }' "$rows"

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
  printf 'wrote\t%s\ttotal=%s checked=%s uncheckable=%s non_verified=%s unclassified=%s\n' \
    "$RULE_ARTIFACT_REL" "$total" "$checked" "$unchecked" "$unverified" "$unclassified"
}
