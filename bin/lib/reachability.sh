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
#   reach_build_class WORKDIR    second closure over non-*.md edges only (needs reach_build first).
#   reach_build_hook_class W     third closure: reach_build_class's own edges, seeded ONLY from
#                                hook/MCP entry points (needs reach_build_class first).
#   reach_hop_class REFERRER     LIVE / REACHABLE / PROSE-ONLY for one referrer path (pure).
#   reach_class WORKDIR NAME     the overall class for bin/NAME; empty/rc1 if dead.
#   reach_chain_classified W N   reach_chain's receipt, each hop tagged with its class.
#   reach_classify_all WORKDIR   "name<TAB>CLASS" for every live subject.

# DECLARATION SURFACES. A file that NAMES a program without invoking it must never confer
# liveness on it, or the graph bootstraps corpses into life. Two exist:
#
#   the exemption registry — writing an exemption would otherwise MAKE the name reachable
#     and silently vouch for the very thing it exempts;
#   the liveness manifest  — it DECLARES which subsystems owe a receipt, in a data column.
#     Naming a subsystem there is a statement that it SHOULD run, which is the opposite of
#     evidence that something runs it. This was not theoretical: once heimdall-weekly-log
#     began reading the manifest, the manifest went live and cost-report,
#     cost-model-refresh and registry-hygiene all inherited false reachability through it,
#     which would have deleted three correct exemptions and reported three unscheduled
#     jobs as live.
#
# Both are excluded from the node set AND the scan set, so they can neither be graded nor
# vouch for anything.
REACH_EXEMPT_REL="bin/lib/reachability-exemptions.tsv"
REACH_MANIFEST_REL="bin/lib/liveness-subsystems.conf"

# reach_strip_decl_surfaces — filter stdin, dropping every declaration surface.
reach_strip_decl_surfaces() {
  grep -vFx "$REACH_EXEMPT_REL" | grep -vFx "$REACH_MANIFEST_REL"
}

# ── node + seed enumeration ───────────────────────────────────────────────────────

# reach_nodes ROOT — every file whose liveness we track, as "basename<TAB>relpath".
reach_nodes() {
  ( cd "$1" 2>/dev/null || exit 0
    find bin hooks sentinels -type f \
         -not -path '*/__pycache__/*' -not -name '*.pyc' -not -name '__init__.py' 2>/dev/null \
      | reach_strip_decl_surfaces \
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

  # Scan every seed and every node once. Declaration surfaces are absent from both, so
  # neither the exemption registry nor the liveness manifest can vouch for a name it lists.
  { cut -f2 "$w/nodes"; cat "$w/seeds"; } | LC_ALL=C sort -u | reach_strip_decl_surfaces > "$w/scanset"
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

# ── CALLER CLASS: what KIND of thing is doing the naming ──────────────────────────
#
# reach_is_live / reach_dead answer "is there a path from a live entry point at all".
# That question stays exactly as strict as it has always been — nothing below loosens
# it, weakens RULE B, or changes one bit of reach_build's own output.
#
# But "reachable" was always hiding a second question: reachable BY WHAT? A hop through
# hooks/hooks.json fires on every matching tool call with no one in the loop. A hop
# through a real script is deterministic once triggered, but something — a human, a
# dispatcher — had to trigger it on purpose. A hop through a *.md file is neither: it is
# a sentence an LLM may or may not have read, may or may not act on, today or never.
# Three different kinds of evidence were being reported as one word, "REACHABLE", and
# the gap between them is exactly the gap the 2026-08-22 capability census measured: 51
# of 177 bin/ executables never fired across 384 real sessions while this engine called
# every one of them clean.
#
#   LIVE         the referrer is hooks/hooks.json or .mcp.json — the harness or an MCP
#                client executes this registration automatically. No judgment call
#                sits between "the file says so" and "it runs".
#   REACHABLE    the referrer is any other non-Markdown file — a real script, a real
#                dispatch arm, a real config line. Deterministic once triggered, but
#                the trigger is a deliberate act: a human types `hmd foo`, one script
#                execs another.
#   PROSE-ONLY   the referrer is a *.md file, anywhere. An agent had to read that
#                sentence and choose to act on it. That choice is not automatic and is
#                not guaranteed, however confidently the sentence reads.
#
# THE SHORTEST PATH IS NOT THE STRONGEST PATH. reach_build's BFS records exactly one
# parent per node — whichever predecessor reaches it in the FEWEST hops — because the
# only question it was ever asked is binary reachability, where shortest-vs-longest is
# irrelevant. That is the wrong chain to grade for evidence quality: in this very tree,
# bin/heimdall-brief is named directly by agents/heimdall.md (one hop from a seed) AND,
# two hops out, by a real, hook-fired path (hooks/hooks.json -> heimdall-precheck-agent
# -> heimdall-brief). The one-hop prose mention is shorter, so reach_chain reports IT —
# and classifying that chain verbatim would report a genuinely hook-wired tool as
# prose-summoned. That is a worse failure than the one this feature exists to catch:
# confidently wrong beats merely generous. So classification prefers ANY all-code path
# over EVERY path that needs a Markdown hop, no matter how many hops shorter the prose
# path is — see reach_build_class below.
#
# PROSE-ONLY IS ABSORBING; AN INTERMEDIATE REACHABLE HOP NEVER DILUTES A LIVE ROOT. A
# path with zero Markdown hops inherits the strength of its ROOT: if hooks.json or
# .mcp.json sits at the far end, everything downstream is automatic once that root
# fires, so the whole path reads LIVE even though some of its hops are individually
# only REACHABLE-class. This is provably safe, not a weakest-link judgment call: the
# only two referrers that ever classify LIVE (hooks/hooks.json, .mcp.json) are always
# seeds, and a seed's own parent is fixed to "<entry-point>" the instant reach_build's
# BFS starts — nothing can ever be an INTERMEDIATE hop after them. So "the path's root
# is LIVE" and "no hop downstream needs a Markdown mention" are the only two things
# reach_class has to check.
#
# TWO ALL-CODE PATHS CAN ALSO COMPETE, NOT JUST CODE-VS-PROSE. Excluding Markdown edges
# (above) only settles code-vs-prose. Within edges-code alone, a bin can still be
# reachable by TWO separate all-code routes — one rooted at a hook/MCP seed, one not —
# and reach_build_class's own BFS is still single-parent: it keeps whichever route it
# happened to traverse first, which turns on seed processing order (alphabetical), not
# on which route is stronger evidence. bin/heimdall-brief hit exactly this: a comment in
# bin/heimdall names bin/heimdall-deadcode, and a comment in bin/heimdall-deadcode names
# bin/heimdall-brief — an all-code, two-hop route with no Markdown in it anywhere. Because
# bin/heimdall sorts ahead of hooks/hooks.json in the seed list, that route gets recorded
# as live-code's parent before the real hooks.json -> heimdall-precheck-agent ->
# heimdall-brief route — equally all-code, equally two hops — gets its turn. Re-ordering
# a single-parent map's tie-break is fragile and re-breaks the next time an unrelated
# comment shuffles discovery order. So this is solved structurally instead:
# reach_build_hook_class computes a THIRD closure over the very same edges-code, seeded
# ONLY from hook/MCP entry points. "Is this bin a member of that closure at all" does not
# care which parent the BFS recorded; it is existence, not a race. reach_class checks
# live-hook-paths membership BEFORE live-code-paths, so a hook-rooted route always
# outranks a non-hook route no matter which one BFS happened to discover first.
#
# NOT A HARD GATE (YET). PROSE-ONLY is reported, tallied, and shown — it does not fail
# bin-reachability-gate and does not flip a verdict from CLEAN to ROT. 51 bins would go
# red in one commit and the gate would be disabled within a day. Absorbing this into the
# exemption registry is a follow-up, not this change.

# reach_build_class WORKDIR — a SECOND closure over the SAME scan, restricted to edges
# whose REFERRER is not a *.md file. Requires reach_build to have already written
# WORKDIR/{nodes,seeds,edges}; reads them, never re-scans the tree. A node reachable
# here is reachable without ever having to trust a sentence — a strictly stronger claim
# than plain reachability, so this closure is always a subset of reach_build's. Because
# the underlying BFS still explores every node reachable via the allowed edges (not
# merely one path), "in this closure at all" is a sound test for "some all-code path
# exists" — not just "the one path found happens to avoid prose". Writes
# WORKDIR/{edges-code,live-code,live-code-paths}.
reach_build_class() {
  local w="$1"
  LC_ALL=C awk -F'\t' '$1 !~ /\.md$/ { print }' "$w/edges" > "$w/edges-code" 2>/dev/null

  LC_ALL=C awk -v nodesf="$w/nodes" -v seedsf="$w/seeds" -v edgesf="$w/edges-code" '
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
    }' < /dev/null > "$w/live-code"

  cut -f1 "$w/live-code" | LC_ALL=C sort -u > "$w/live-code-paths"
  return 0
}

# reach_build_hook_class WORKDIR — a THIRD closure, over the SAME edges-code as
# reach_build_class, seeded ONLY from the hook/MCP entry points (hooks/hooks.json,
# .mcp.json) instead of the full seed set. A node in this closure is reachable WITHOUT
# ever leaving an automatic-execution root — strictly stronger evidence than "some
# all-code path exists" (reach_build_class) or "some path exists at all" (reach_build).
# This is what turns "strongest class wins" into a membership test instead of a
# single-parent tie-break: a bin can sit in BOTH this closure and a separate, non-hook
# branch of live-code's own BFS at once, and because reach_class checks THIS set first,
# the hook-rooted evidence always wins regardless of which parent live-code's map
# happened to record for it. Requires reach_build_class to have already run (reads its
# edges-code; does not rebuild it). Writes WORKDIR/{hook-seeds,live-hook,live-hook-paths}.
reach_build_hook_class() {
  local w="$1"
  LC_ALL=C awk '$0 == "hooks/hooks.json" || $0 == ".mcp.json"' "$w/seeds" > "$w/hook-seeds" 2>/dev/null

  LC_ALL=C awk -v nodesf="$w/nodes" -v seedsf="$w/hook-seeds" -v edgesf="$w/edges-code" '
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
    }' < /dev/null > "$w/live-hook"

  cut -f1 "$w/live-hook" | LC_ALL=C sort -u > "$w/live-hook-paths"
  return 0
}

# reach_hop_class REFERRER — the evidentiary weight of ONE hop, from what KIND of file
# is doing the naming, never from what it says.
reach_hop_class() {
  case "$1" in
    hooks/hooks.json|.mcp.json) printf 'LIVE\n' ;;
    *.md)                       printf 'PROSE-ONLY\n' ;;
    *)                          printf 'REACHABLE\n' ;;
  esac
}

# reach_class WORKDIR NAME — LIVE, REACHABLE, or PROSE-ONLY for bin/NAME: the STRONGEST
# class over ALL paths, never merely the one path reach_build_class's own BFS happened
# to record. Structural, not a tie-break: LIVE means some path stays entirely in code
# AND roots at a hook/MCP seed (membership in live-hook-paths); REACHABLE means some
# path stays entirely in code but none of those roots at a hook/MCP seed
# (live-code-paths, checked only once live-hook-paths has ruled LIVE out); PROSE-ONLY
# means reachable at all, but every all-code closure misses it. Checking live-hook-paths
# BEFORE live-code-paths is what makes "strongest wins": a bin can be a member of both at
# once, and membership does not care which parent either map's single-parent BFS
# recorded. rc 1 with no output if bin/NAME is dead. Requires reach_build_class AND
# reach_build_hook_class to have already run.
reach_class() {
  local w="$1" name="$2" path="bin/$2"
  if LC_ALL=C grep -qxF "$path" "$w/live-hook-paths" 2>/dev/null; then
    printf 'LIVE\n'
    return 0
  fi
  if LC_ALL=C grep -qxF "$path" "$w/live-code-paths" 2>/dev/null; then
    printf 'REACHABLE\n'
    return 0
  fi
  if reach_is_live "$w" "$name"; then
    printf 'PROSE-ONLY\n'
    return 0
  fi
  return 1
}

# reach_chain_classified WORKDIR NAME — reach_chain's receipt, each hop tagged with its
# reach_hop_class. Walks the STRONGEST closure bin/NAME belongs to: live-hook first (so a
# LIVE bin's receipt shows its real hook-rooted route, never a shorter or
# earlier-discovered non-hook route that live-code's own single-parent map might
# otherwise have recorded for it), then live-code (so a REACHABLE bin's receipt stays
# all-code, never a shorter prose hop), and only falls back to the ordinary transitive
# chain — which necessarily carries at least one Markdown hop — when no all-code path
# exists at all.
reach_chain_classified() {
  local w="$1" name="$2" cur="bin/$2" out="" par cur_cls="" map guard=0
  if LC_ALL=C grep -qxF "$cur" "$w/live-hook-paths" 2>/dev/null; then
    map="live-hook"
  elif LC_ALL=C grep -qxF "$cur" "$w/live-code-paths" 2>/dev/null; then
    map="live-code"
  elif reach_is_live "$w" "$name"; then
    map="live"
  else
    printf 'no path to any live entry point\n'
    return 1
  fi
  while [ "$guard" -lt 64 ]; do
    guard=$((guard + 1))
    if [ -n "$cur_cls" ]; then out="${out}${cur} [${cur_cls}]"; else out="${out}${cur}"; fi
    par="$(LC_ALL=C awk -F'\t' -v p="$cur" '$1 == p { print $2; exit }' "$w/$map")"
    [ -n "$par" ] || break
    out="${out} <- "
    if [ "$par" = "<entry-point>" ]; then out="${out}<entry-point>"; break; fi
    cur_cls="$(reach_hop_class "$par")"
    cur="$par"
  done
  printf '%s\n' "$out"
}

# reach_classify_all WORKDIR — "name<TAB>CLASS" for every live subject (dead ones are
# reach_dead's concern, unchanged: a class answers "how good is the evidence", and a
# dead name has none). Requires reach_build_class to have already run.
reach_classify_all() {
  local w="$1" name cls
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    cls="$(reach_class "$w" "$name")" || continue
    printf '%s\t%s\n' "$name" "$cls"
  done < "$w/subjects"
  return 0
}
