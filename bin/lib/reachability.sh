#!/usr/bin/env bash
# bin/lib/reachability.sh — THE reachability engine. ONE implementation, every caller.
#
# WHY A LIBRARY AND NOT A SECOND AUDITOR. test/bin-reachability-gate.test.sh already
# audited bin/ and already cleared bin/heimdall-brief as "reachable" for two months
# while nothing on earth invoked it. The fix is NOT a second auditor that can disagree
# with the first — two gates with different verdicts is the drift this repo keeps
# hitting. The detector lives here exactly once; the gate, the CLI (bin/heimdall-deadcode)
# and the periodic sweep (bin/heimdall-cleanup --code) are thin callers over it.
#
# ── WHAT WENT WRONG BEFORE: A DEAD CHAIN CITING ITSELF READS AS REACHABLE ─────────
# The old rule was "some file under bin/ hooks/ sentinels/ skills/ agents/ commands/
# names this executable". bin/heimdall-protocol named bin/heimdall-brief, so
# heimdall-brief was "reachable" — except heimdall-protocol was itself invoked by
# nothing. A corpse vouched for a corpse and the gate believed it.
#
# So reachability here is TRANSITIVE FROM A LIVE ENTRY POINT, never "mentioned
# somewhere". The graph is seeded ONLY at surfaces the outside world actually enters
# through (reach_root_seeds below) and liveness propagates outward from them. A file
# nothing live can reach is dead no matter how many other dead files name it.
#
# ── THE ENTRY POINTS (the seed set — the only thing taken on faith) ───────────────
#   hooks/hooks.json      the harness executes these on real session events
#   .mcp.json             an MCP client launches what is registered here
#   install.sh            runs on install
#   bin/heimdall, bin/hmd the CLI a human types
#   commands/ agents/ skills/   the harness loads and dispatches these
#   .claude-plugin/       the plugin manifest
#   deploy/ .github/workflows/  what runs in CI and in production
# Everything else — every bin, every lib, every hook script, every sentinel — has to
# EARN liveness by being named from something already live. Documentation alone is not
# an entry point: README prose describing a command proves someone wrote a sentence,
# not that anything invokes it. `hmd <cmd>` counts because bin/heimdall is a seed and
# RULE A separately pins advertised-implies-dispatched.
#
# ── MATCHING: WORD-EXACT, NEVER SUBSTRING ────────────────────────────────────────
# A reference is a whole [A-Za-z0-9_-] token, or a whole [A-Za-z0-9_.-] token, equal
# to the target's basename. Both alphabets are needed and both are load-bearing:
#   • the dotted alphabet matches `source "$LIB/protocol.sh"` (name carries a dot);
#   • the dot-free alphabet matches `bin/heimdall-presence.py` naming heimdall-presence.
# A name that merely occurs INSIDE a longer token does NOT match — heimdall-git-guard
# must not be cleared by `heimdall-git-guard-DISABLED`, which is precisely the bug the
# first cut of the old gate shipped with. Extraction takes the leftmost-LONGEST token
# around each candidate, then compares for exact equality, so a longer name can never
# vouch for a shorter one.
#
# Self-reference never counts: a file naming its own basename (its header comment, its
# usage text) proves nothing.
#
# ── EXCLUSIONS, EACH FOR A REASON ────────────────────────────────────────────────
#   __pycache__/*, *.pyc  a stale .pyc carries the module name of a since-unwired
#                         command, so a build artifact would vouch for dead code.
#   __init__.py           package markers, one per package: the only basename that
#                         collides across directories, and it names nothing.
#   the exemption file    THE most important exclusion. That file lists, by name,
#                         every executable exempted from this audit. If it were a
#                         reference surface, writing an exemption would MAKE the
#                         binary look reachable — the escape hatch would silently
#                         become a second way to be dead. It is excluded from the node
#                         set and from the scan set, and reach_falsify_exemption_file()
#                         proves it.
#
# ── FAIL-CLOSED ──────────────────────────────────────────────────────────────────
# An empty scan is a FAILURE, never a pass. reach_build returns 2 if it enumerates no
# nodes, no seeds, or no subject executables — "the scanner found nothing" and "nothing
# is wrong" are different answers and must never render the same.
#
# ── PUBLIC API ───────────────────────────────────────────────────────────────────
#   reach_build ROOT WORKDIR    build the closure. 0 = built, 2 = refused (empty scan).
#   reach_dead WORKDIR          bin/ executables with no path to a live entry point.
#   reach_live_count WORKDIR    how many nodes are live.
#   reach_subject_count WORKDIR how many bin/ executables were audited.
#   reach_chain WORKDIR NAME    the invoker chain: "name <- caller <- ... <- <entry-point>"
#   reach_is_live WORKDIR NAME  0 if bin/NAME is reachable from an entry point.
#   reach_exempt_audit ROOT WORKDIR   rot findings against the exemption registry.
#   reach_exempt_reason ROOT NAME     the recorded reason for an exemption.
#   reach_exempt_valid ROOT NAME      0 iff exempt AND well-formed AND not past recheck.

# The exemption registry, relative to the repo root. Excluded from the graph on purpose.
REACH_EXEMPT_REL="bin/lib/reachability-exemptions.tsv"

# ── node + seed enumeration ───────────────────────────────────────────────────────

# reach_nodes ROOT — every file whose liveness we track, as "basename<TAB>relpath".
reach_nodes() {
  ( cd "$1" 2>/dev/null || exit 0
    find bin hooks sentinels -type f \
         -not -path '*/__pycache__/*' -not -name '*.pyc' -not -name '__init__.py' 2>/dev/null \
      | grep -vFx "$REACH_EXEMPT_REL" \
      | LC_ALL=C awk -F'/' '{ print $NF "\t" $0 }' \
      | LC_ALL=C sort
    exit 0 )
}

# reach_root_seeds ROOT — the LIVE ENTRY POINTS. Liveness starts here and nowhere else.
reach_root_seeds() {
  ( cd "$1" 2>/dev/null || exit 0
    for f in hooks/hooks.json .mcp.json install.sh bin/heimdall bin/hmd; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
    for d in commands agents skills .claude-plugin deploy .github/workflows; do
      [ -d "$d" ] || continue
      find "$d" -type f -not -path '*/__pycache__/*' -not -name '*.pyc' 2>/dev/null
    done
    exit 0 )
}

# reach_subjects ROOT — the audited set: executables directly in bin/. bin/lib is a
# library dir, not a command surface; sources and data are not commands.
reach_subjects() {
  local f name
  for f in "$1"/bin/*; do
    [ -f "$f" ] || continue
    [ -x "$f" ] || continue
    name="$(basename "$f")"
    case "$name" in *.c|*.h|*.md|*.json|*.py|*.tsv) continue ;; esac
    printf '%s\n' "$name"
  done
  return 0
}

# ── the closure ───────────────────────────────────────────────────────────────────

# reach_build ROOT WORKDIR — one grep pass over the tree, then a BFS from the seeds.
# Writes WORKDIR/{nodes,names,seeds,scanset,hits,edges,live,subjects,dead}.
reach_build() {
  local root="$1" w="$2"
  [ -d "$root" ] || return 2
  mkdir -p "$w" 2>/dev/null || return 2

  reach_nodes "$root" > "$w/nodes"
  [ -s "$w/nodes" ] || return 2
  cut -f1 "$w/nodes" | LC_ALL=C sort -u > "$w/names"

  reach_root_seeds "$root" | LC_ALL=C sort -u > "$w/seeds"
  [ -s "$w/seeds" ] || return 2

  reach_subjects "$root" | LC_ALL=C sort -u > "$w/subjects"
  [ -s "$w/subjects" ] || return 2

  # Scan every seed and every node once. The exemption file is absent from both, so it
  # can never vouch for the names it exempts.
  { cut -f2 "$w/nodes"; cat "$w/seeds"; } | LC_ALL=C sort -u | grep -vFx "$REACH_EXEMPT_REL" > "$w/scanset"
  [ -s "$w/scanset" ] || return 2

  # A path containing ':' would make the grep -H output ambiguous and could silently
  # mis-attribute an edge. Refuse rather than guess.
  if grep -q ':' "$w/scanset"; then return 2; fi

  # A basename outside the tokenizer's alphabet could never be produced as a token and
  # would therefore read DEAD forever, silently. Refuse rather than mis-report.
  if grep -qvE '^[A-Za-z0-9_.-]+$' "$w/names"; then return 2; fi

  # ONE pass over the whole tree. The regex is deliberately SIMPLE (a plain token run,
  # not a 300-way alternation of every node name): the alternation form measured 52s of
  # grep CPU against 3.8s here for byte-identical results, and a scan too slow to run is
  # a scan that gets switched off. -I skips binaries — a compiled artifact's byte soup
  # is not a call site. Matches are whole leftmost-longest tokens, so a name occurring
  # INSIDE a longer token comes back as that longer token and fails the exact compare.
  ( cd "$root" && tr '\n' '\0' < "$w/scanset" \
      | xargs -0 grep -oIHE '[A-Za-z0-9_.-]+' 2>/dev/null ) \
    | LC_ALL=C awk -v namesf="$w/names" '
    BEGIN { while ((getline l < namesf) > 0) nm[l] = 1 }
    {
      i = index($0, ":"); if (i == 0) next
      f = substr($0, 1, i - 1); t = substr($0, i + 1)
      if (t in nm) { k = f SUBSEP t; if (!(k in seen)) { seen[k] = 1; print f "\t" t } }
      n = split(t, p, ".")
      if (n > 1) for (j = 1; j <= n; j++)
        if (p[j] != "" && (p[j] in nm)) { k = f SUBSEP p[j]; if (!(k in seen)) { seen[k] = 1; print f "\t" p[j] } }
    }' > "$w/edges" || true

  LC_ALL=C awk -v nodesf="$w/nodes" -v seedsf="$w/seeds" -v edgesf="$w/edges" '
    BEGIN {
      while ((getline l < nodesf) > 0) {
        split(l, a, "\t")
        n2p[a[1]] = ((a[1] in n2p) ? n2p[a[1]] " " : "") a[2]
        base[a[2]] = a[1]
      }
      while ((getline s < seedsf) > 0)
        if (!(s in live)) { live[s] = 1; par[s] = "<entry-point>"; q[++qn] = s }
      while ((getline e < edgesf) > 0) {
        split(e, b, "\t")
        ed[b[1]] = ((b[1] in ed) ? ed[b[1]] " " : "") b[2]
      }
      h = 0
      while (h < qn) {
        p = q[++h]
        if (!(p in ed)) continue
        m = split(ed[p], t, " ")
        for (j = 1; j <= m; j++) {
          # a file naming its own basename vouches for nothing
          if (t[j] == base[p]) continue
          k = split(n2p[t[j]], tp, " ")
          for (z = 1; z <= k; z++) {
            tg = tp[z]
            if (tg == p || (tg in live)) continue
            live[tg] = 1; par[tg] = p; q[++qn] = tg
          }
        }
      }
      for (p in live) printf "%s\t%s\n", p, par[p]
    }' < /dev/null > "$w/live"

  cut -f1 "$w/live" | LC_ALL=C sort -u > "$w/live-paths"
  sed 's|^|bin/|' "$w/subjects" | LC_ALL=C sort > "$w/subject-paths"
  LC_ALL=C comm -23 "$w/subject-paths" "$w/live-paths" | sed 's|^bin/||' > "$w/dead"
  return 0
}

reach_dead()          { cat "$1/dead"; }
reach_live_count()    { grep -c . "$1/live-paths" || true; }
reach_subject_count() { grep -c . "$1/subjects" || true; }
reach_is_live()       { grep -qxF "bin/$2" "$1/live-paths"; }

# reach_chain WORKDIR NAME — how bin/NAME is reached, walking parents back to a seed.
# This is the "name what invokes it" receipt: a green verdict prints its evidence.
reach_chain() {
  local w="$1" cur="bin/$2" out="" par guard=0
  reach_is_live "$w" "$2" || { printf 'no path to any live entry point\n'; return 1; }
  while [ "$guard" -lt 64 ]; do
    guard=$((guard + 1))
    out="${out}${cur}"
    par="$(LC_ALL=C awk -F'\t' -v p="$cur" '$1 == p { print $2; exit }' "$w/live")"
    [ -n "$par" ] || break
    out="${out} <- "
    if [ "$par" = "<entry-point>" ]; then out="${out}<entry-point>"; break; fi
    cur="$par"
  done
  printf '%s\n' "$out"
}

# ── the exemption registry ────────────────────────────────────────────────────────
# Format: name <TAB> recheck-by (YYYY-MM-DD) <TAB> reason. '#' comments and blanks skipped.
#
# An exemption that never expires is a second way to go quietly dead: someone writes
# "standalone by design" once and nobody ever looks again — which is how heimdall-brief
# would have survived even WITH this gate. So every row carries a recheck date, and the
# gate fails when one passes. Four rot conditions are checked, not one:
#   MALFORMED  a row missing a name, a valid ISO date, or a reason
#   EXPIRED    past its recheck date — someone must re-justify it or wire it up
#   STALE      the name is now genuinely reachable, so the exemption is a dead exclusion
#   ORPHAN     the file is gone; the row is litter that would silently pre-clear a future
#              executable that happens to reuse the name

reach_exempt_path() { printf '%s\n' "$1/$REACH_EXEMPT_REL"; }

# reach_today — the comparison date. HMD_REACH_TODAY is a TEST SEAM, never set in production.
reach_today() { printf '%s\n' "${HMD_REACH_TODAY:-$(date +%Y-%m-%d)}"; }

# reach_datenum DATE — YYYYMMDD for integer comparison; rc 1 if not a real ISO date.
reach_datenum() {
  printf '%s' "$1" | LC_ALL=C grep -qE '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' || return 1
  printf '%s' "$1" | tr -d '-'
  printf '\n'
}

# reach_exempt_rows ROOT — the registry's data rows.
reach_exempt_rows() {
  local f; f="$(reach_exempt_path "$1")"
  [ -f "$f" ] || return 0
  LC_ALL=C grep -v '^#' "$f" | LC_ALL=C grep -v '^[[:space:]]*$' || true
}

# reach_exempt_row ROOT NAME — the row for NAME, rc 1 if none.
reach_exempt_row() {
  local row
  row="$(reach_exempt_rows "$1" | LC_ALL=C awk -F'\t' -v n="$2" '$1 == n { print; exit }')"
  [ -n "$row" ] || return 1
  printf '%s\n' "$row"
}

reach_exempt_reason() { reach_exempt_row "$1" "$2" | cut -f3; }

# reach_exempt_valid ROOT NAME — 0 iff a well-formed, in-date exemption covers NAME.
# Fails closed: a malformed date is NOT a licence to be dead.
reach_exempt_valid() {
  local row d r today
  row="$(reach_exempt_row "$1" "$2")" || return 1
  d="$(printf '%s' "$row" | cut -f2)"
  r="$(printf '%s' "$row" | cut -f3)"
  [ -n "$r" ] || return 1
  d="$(reach_datenum "$d")" || return 1
  today="$(reach_datenum "$(reach_today)")" || return 1
  [ "$today" -le "$d" ]
}

# reach_exempt_audit ROOT WORKDIR — one "KIND<TAB>name<TAB>detail" line per rot finding.
reach_exempt_audit() {
  local root="$1" w="$2" name date reason today seen=""
  today="$(reach_datenum "$(reach_today)")" || { printf 'MALFORMED\t<today>\tHMD_REACH_TODAY is not an ISO date\n'; return 0; }
  while IFS="$(printf '\t')" read -r name date reason; do
    [ -n "$name" ] || continue
    case " $seen " in *" $name "*) printf 'DUPLICATE\t%s\tlisted more than once; one row per name or the later reason is invisible\n' "$name"; continue ;; esac
    seen="$seen $name"
    if [ -z "$reason" ]; then
      printf 'MALFORMED\t%s\tno reason recorded — an exemption without a written reason is unreviewable\n' "$name"
      continue
    fi
    if ! date="$(reach_datenum "$date")"; then
      printf 'MALFORMED\t%s\trecheck date is not a real ISO YYYY-MM-DD\n' "$name"
      continue
    fi
    if [ ! -f "$root/bin/$name" ]; then
      printf 'ORPHAN\t%s\tno bin/%s exists — remove the row before it pre-clears a future executable of the same name\n' "$name" "$name"
      continue
    fi
    if reach_is_live "$w" "$name"; then
      printf 'STALE\t%s\tnow reachable from a live entry point — remove the exemption so the gate keeps gating\n' "$name"
      continue
    fi
    if [ "$today" -gt "$date" ]; then
      printf 'EXPIRED\t%s\trecheck was due — wire it up, delete it, or re-justify it with a new date\n' "$name"
    fi
  done <<EOF
$(reach_exempt_rows "$root")
EOF
  return 0
}

# reach_unacknowledged ROOT WORKDIR — dead executables with no VALID exemption. This is
# the gate's failure set: the names nobody has written a live reason for.
reach_unacknowledged() {
  local root="$1" w="$2" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    reach_exempt_valid "$root" "$name" || printf '%s\n' "$name"
  done < "$w/dead"
  return 0
}
