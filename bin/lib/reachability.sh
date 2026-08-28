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

# reach_extract_tokens ROOT SCANSET — "path:token" for every alphabet-token run in
# every text file named in SCANSET (paths relative to ROOT), in one comment-aware pass.
# Binaries are skipped before they're ever opened for tokenizing (a -l pre-pass reusing
# grep's own -I heuristic, not a filter after the fact — a compiled artifact's byte soup
# was never a call site). A '#'-to-EOL comment is stripped before tokenizing UNLESS: the
# '#' sits inside a single- or double-quoted string (bash/python/jq all agree a quoted
# '#' isn't a comment start), the line is inside a heredoc body (that's the heredoc's own
# payload, not a comment — left verbatim, tokenized as-is), or the file has no '#'-comment
# syntax at all (*.md's '#' is a heading marker; *.json/*.c/*.h use different or no
# comment syntax — *.c/*.h diagnostic-string false positives are a separate, already-
# tracked gap, not this function's job) — see is_comment_aware() below. A name that only
# ever appears after a real comment marker is a mention, not an invocation, and must not
# read as an edge.
#
# PYTHON DOCSTRINGS ARE PROSE TOO, AND '#'-AWARENESS ALONE DOES NOT SEE THEM. A file
# is_py (FILENAME ends in .py, OR its first line is a `#!...python` shebang — most of
# this repo's bin/ Python tools are extensionless) gets a SECOND, separate strip pass
# (pystrip() below), because a triple-quoted string is a string literal, never a '#'
# comment, so strip_comment() never touches it. The content of a triple-quoted
# ('"'"''"'"''"'"' or \"\"\") block is dropped before tokenizing ONLY when it opens as a BARE
# EXPRESSION STATEMENT — the physical line, leading whitespace stripped, STARTS with
# the delimiter. That is what a real docstring looks like syntactically, and it is the
# one shape an executed string can never take: `SCRIPT = \"\"\"#!/bin/sh` opens
# mid-line, after `SCRIPT = `, so its close is still tracked (a bare docstring
# immediately after it must not be confused for a continuation of it) but its CONTENT
# is left untouched and keeps tokenizing normally — a real invocation can live inside a
# string a program builds and runs, and this pass must never blind the scanner to that.
reach_extract_tokens() {
  local root="$1" scanset="$2"
  ( cd "$root" \
      && export LC_ALL=C \
      && tr '\n' '\0' < "$scanset" \
      | xargs -0 grep -Il '.' 2>/dev/null \
      | tr '\n' '\0' \
      | xargs -0 awk '
      function is_comment_aware(fname) {
        if (fname ~ /\.md$/)   return 0
        if (fname ~ /\.json$/) return 0
        if (fname ~ /\.c$/)    return 0
        if (fname ~ /\.h$/)    return 0
        return 1
      }
      function strip_comment(line,    i, n, c, out, in_sq, in_dq) {
        n = length(line); out = ""; in_sq = 0; in_dq = 0
        for (i = 1; i <= n; i++) {
          c = substr(line, i, 1)
          if (in_sq) { out = out c; if (c == SQ) in_sq = 0; continue }
          if (in_dq) {
            out = out c
            if (c == "\\" && i < n) { i++; out = out substr(line, i, 1); continue }
            if (c == DQ) in_dq = 0
            continue
          }
          if (c == SQ) { in_sq = 1; out = out c; continue }
          if (c == DQ) { in_dq = 1; out = out c; continue }
          if (c == "\\" && i < n) { out = out c substr(line, i + 1, 1); i++; continue }
          if (c == "#") break
          out = out c
        }
        return out
      }
      # py_find_triple_open LINE — the first position of a genuine triple-quote run
      # (three IDENTICAL quote characters back to back, either flavor) anywhere in
      # LINE; sets py_delim_found to whichever 3-char delimiter matched. 0 if none.
      function py_find_triple_open(line,    i, n, c) {
        n = length(line)
        for (i = 1; i <= n - 2; i++) {
          c = substr(line, i, 1)
          if ((c == DQ || c == SQ) && substr(line, i, 3) == (c c c)) {
            py_delim_found = c c c
            return i
          }
        }
        return 0
      }
      # pystrip LINE — python-docstring-aware filter, called ONLY for is_py files,
      # ahead of the generic comment-stripper. Mutates the persistent in_pytriple /
      # pytriple_delim / pytriple_strip trio (reset at FNR==1, exactly like
      # in_heredoc/heredoc_term) and sets pytriple_skip when the whole physical line
      # is prose and must emit no tokens at all.
      #
      # Content is blanked (pytriple_strip=1) ONLY for a region that opened as a bare
      # expression statement. Any other opening — assigned to a name, passed to a
      # call, mid-expression — is tracked ONLY so its real close is recognized for
      # what it is, never mistaken for a fresh bare-docstring open; its content is
      # left completely untouched either way.
      function pystrip(line,    stripped, delim, tail, idx, after, p) {
        pytriple_skip = 0
        if (in_pytriple) {
          idx = index(line, pytriple_delim)
          if (idx > 0) {
            after = substr(line, idx + 3)
            in_pytriple = 0
            pytriple_delim = ""
            if (pytriple_strip) return after
            return line
          }
          if (pytriple_strip) { pytriple_skip = 1; return "" }
          return line
        }
        stripped = line
        sub(/^[ \t]+/, "", stripped)
        if (substr(stripped, 1, 3) == DQ3 || substr(stripped, 1, 3) == SQ3) {
          delim = substr(stripped, 1, 3)
          tail = substr(stripped, 4)
          idx = index(tail, delim)
          if (idx > 0) return substr(tail, idx + 3)
          in_pytriple = 1; pytriple_delim = delim; pytriple_strip = 1
          pytriple_skip = 1
          return ""
        }
        p = py_find_triple_open(line)
        if (p > 0) {
          delim = py_delim_found
          tail = substr(line, p + 3)
          if (!(index(tail, delim) > 0)) {
            in_pytriple = 1; pytriple_delim = delim; pytriple_strip = 0
          }
        }
        return line
      }
      function emit(fname, line,    rest, tok) {
        rest = line
        while (match(rest, /[A-Za-z0-9_.-]+/)) {
          tok = substr(rest, RSTART, RLENGTH)
          print fname ":" tok
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
      BEGIN {
        SQ = sprintf("%c", 39); DQ = sprintf("%c", 34)
        DQ3 = DQ DQ DQ; SQ3 = SQ SQ SQ
        heretok_re = "<<-?[ \t]*[" SQ DQ "]?[A-Za-z_][A-Za-z0-9_]*[" SQ DQ "]?"
      }
      FNR == 1 {
        in_heredoc = 0; heredoc_term = ""; heredoc_striptabs = 0; aware = is_comment_aware(FILENAME)
        is_py = (FILENAME ~ /\.py$/) || ($0 ~ /^#!.*python/)
        in_pytriple = 0; pytriple_delim = ""; pytriple_strip = 0
      }
      {
        line = $0
        if (in_heredoc) {
          chk = line
          if (heredoc_striptabs) sub(/^\t+/, "", chk)
          if (chk == heredoc_term) in_heredoc = 0
          emit(FILENAME, line); next
        }
        if (is_py) {
          line = pystrip(line)
          if (pytriple_skip) next
        }
        if (aware) {
          if (match(line, heretok_re)) {
            htok = substr(line, RSTART, RLENGTH)
            heredoc_striptabs = (htok ~ /^<<-/) ? 1 : 0
            term = htok
            sub(/^<<-?[ \t]*/, "", term); gsub(SQ, "", term); gsub(DQ, "", term)
            heredoc_term = term; in_heredoc = 1
          }
          if (index(line, "#") > 0) line = strip_comment(line)
        }
        emit(FILENAME, line)
      }' 2>/dev/null )
}

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

  # ONE pass over the whole tree, comment-aware (reach_extract_tokens). The old plain
  # grep -oIHE alternative was faster in isolation (a plain token run measured 3.8s vs
  # 52s for a 300-way name alternation) but counted a name mentioned only in a comment
  # as an invocation edge — 761/1761 code edges (43%) turned out to be comment-only, and
  # 24 LIVE bins were LIVE only via a comment-fed path. Matches are whole leftmost-
  # longest tokens, so a name occurring INSIDE a longer token comes back as that longer
  # token and fails the exact compare, same as before.
  reach_extract_tokens "$root" "$w/scanset" \
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
#   REACHABLE    the referrer is any other non-Markdown file, OR a commands/*.md file —
#                a real script, a real dispatch arm, a real config line, or a declared
#                slash-command entry point. Deterministic once triggered, but the
#                trigger is a deliberate act: a human types `hmd foo` or `/foo`, one
#                script execs another.
#   PROSE-ONLY   the referrer is a *.md file OUTSIDE commands/ — agents/, skills/,
#                docs, or anywhere else prose lives. An agent had to read that sentence
#                and choose to act on it. That choice is not automatic and is not
#                guaranteed, however confidently the sentence reads.
#
# COMMANDS/*.MD ARE A DECLARED ENTRY POINT, NOT PROSE. A file under commands/ is a
# Claude Code slash-command definition: a human types `/name` and the harness loads
# that file's body as the operative instruction for that one turn, for its one
# declared purpose. That is structurally identical to "a human types `hmd foo`" —
# already scored REACHABLE — not to agents/heimdall.md or a skills/**/*.md procedure
# doc, where a bin's name is one instruction among hundreds, mentioned in passing and
# conditionally acted upon. commands/debloat.md's entire body IS `bin/heimdall-debloat
# report [<path>]` and its sibling invocations — the command's only content, not an
# aside inside a larger document. Treating that the same as a stray mention in a
# 500-line persona doc under-counted real entry points: commands/reflect.md's whole
# purpose is to run `conflict-log unresolved` and `conflict-log reflect-all`, and
# scoring that PROSE-ONLY reported a declared, human-triggered command as merely
# something an agent "might" read and "might" act on. reach_root_seeds already trusts
# every file under commands/ enough to seed liveness FROM it with no path needed; it
# would be incoherent to then trust that same directory too little to vouch for a
# child it names. agents/ and skills/ get no such carve-out: those directories hold
# multi-purpose reference material where a bin's name is incidental, not the file's
# entire reason to exist.
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
# whose REFERRER is not a *.md file, OR is a commands/*.md file (a declared slash-command
# entry point — see COMMANDS/*.MD ARE A DECLARED ENTRY POINT above). Requires reach_build
# to have already written WORKDIR/{nodes,seeds,edges}; reads them, never re-scans the
# tree. A node reachable here is reachable without ever having to trust an agent's
# discretionary reading of a sentence — a strictly stronger claim than plain
# reachability, so this closure is always a subset of reach_build's. Because the
# underlying BFS still explores every node reachable via the allowed edges (not merely
# one path), "in this closure at all" is a sound test for "some all-code-or-declared-
# command path exists" — not just "the one path found happens to avoid prose". Writes
# WORKDIR/{edges-code,live-code,live-code-paths}.
reach_build_class() {
  local w="$1"
  LC_ALL=C awk -F'\t' '$1 !~ /\.md$/ || $1 ~ /^commands\// { print }' "$w/edges" > "$w/edges-code" 2>/dev/null

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
# edges-code; does not rebuild it). Writes WORKDIR/{edges-hook,hook-seeds,live-hook,live-hook-paths}.
#
# DISPATCHER HOP CEILING — bin/heimdall and bin/hmd are, by reach_root_seeds' own
# doc comment, "the CLI a human types": a multi-way `case` keyed on a subcommand
# argument that source-level tokenizing cannot see. Naming both of them once as a
# seed is right (a hook CAN legitimately invoke `bin/heimdall <fixed-subcommand>` and
# that one target really is automatic) — but crediting EVERY name the dispatcher's
# own source mentions is wrong, and it is not hypothetical: bin/heimdall contains on
# the order of 60 real (non-comment, post-stripping) mentions of other bin names in
# its dispatch table, and some hook names bin/heimdall directly for an unrelated,
# narrow purpose. Before this ceiling, that ONE hook edge into the dispatcher was
# enough for reach_build_hook_class's BFS to walk every one of those ~60 dispatch
# arms and report them all LIVE — e.g. bin/heimdall-metric's only path was
# `bin/heimdall-metric <- bin/heimdall [REACHABLE] <- hooks/hooks.json [LIVE]`, a
# REACHABLE-class hop in the middle laundered into a LIVE verdict at the end, exactly
# the "absorbing LIVE" rule (above) misapplied to a hop that is actually a runtime
# branch, not a deterministic relay. A dispatcher's outgoing edges are categorically
# REACHABLE (a human, or a hook's fixed argument, must still select the branch) and
# must never propagate LIVE onward, REGARDLESS of whether the dispatcher itself is
# hook-reachable. The dispatcher file can still classify LIVE if a hook names it
# directly — only its OWN outgoing mentions are excluded from this closure. edges-code
# itself (and therefore reach_build_class / REACHABLE) is untouched: a bin reachable
# ONLY through the dispatcher still correctly reads REACHABLE, never DEAD — this is a
# classification correction, not a reachability regression.
reach_build_hook_class() {
  local w="$1"
  LC_ALL=C awk '$0 == "hooks/hooks.json" || $0 == ".mcp.json"' "$w/seeds" > "$w/hook-seeds" 2>/dev/null
  LC_ALL=C awk -F'\t' '$1 != "bin/heimdall" && $1 != "bin/hmd"' "$w/edges-code" > "$w/edges-hook" 2>/dev/null

  LC_ALL=C awk -v nodesf="$w/nodes" -v seedsf="$w/hook-seeds" -v edgesf="$w/edges-hook" '
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
# is doing the naming, never from what it says. commands/*.md is checked BEFORE the
# general *.md case: it is a declared slash-command entry point (a human types `/name`),
# not incidental prose — see COMMANDS/*.MD ARE A DECLARED ENTRY POINT above.
reach_hop_class() {
  case "$1" in
    hooks/hooks.json|.mcp.json) printf 'LIVE\n' ;;
    commands/*.md)              printf 'REACHABLE\n' ;;
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

# reach_vacuity_ceiling — the maximum percentage of ALL scanned bin/ executables
# (reach_subject_count's denominator: every candidate this file's BFS ever considers,
# dead ones included, so the number moves only when a file is actually added or
# removed, never when an exemption row alone reclassifies something) that may
# legitimately classify LIVE before the caller-class census itself is evidence of a
# vacuous classifier rather than a genuinely automatic codebase.
#
# LIVE means "fires without a human typing it" — a STRUCTURAL claim about the mention
# graph, not an empirical one, so it will always read higher than any measured
# invocation frequency: the 2026-08-22 capability census
# (docs/analysis/2026-08-22-capability-census.md) found only ~43 distinct bins actually
# fired across 384 real sessions, roughly a quarter of the ~179 scanned here, but a
# rarely-triggered error-path hook is still honestly LIVE even in a sample where it
# never happened to fire. Pinning this ceiling down near that ~24-29% empirical floor
# would fail for the wrong reason as often as the right one.
#
# 60 is a judgment call, not a derived constant, chosen to sit strictly between the two
# real data points this file's own history produced:
#   - 131 of 179 (73%) — this classifier's actual PRE-FIX output, proven vacuous by
#     hand (comment-only mentions counted as invocation edges; bin/heimdall's ~65-arm
#     dispatch table laundering REACHABLE hops into LIVE). MUST fail this ceiling.
#   - 99 of 179 (55%) — the real tree today, after both fixes, ten bins of headroom
#     under the ceiling: loose enough that legitimate LIVE growth is not a false
#     alarm, tight enough that a THIRD hub-laundering bug re-inflating LIVE by more
#     than that has a real chance of tripping it rather than sliding underneath.
# Tighten this number only alongside real work that brings LIVE down further — never
# by widening it to wherever LIVE happens to have drifted, which would make the gate
# decorative in exactly the way bin/lib/reachability-exemptions.tsv's own dated-row
# discipline exists to prevent for individual bins.
reach_vacuity_ceiling() { printf '%s\n' 60; }

# reach_vacuity_check TOTAL LIVE — pass (rc 0) if LIVE is within reach_vacuity_ceiling
# percent of TOTAL, fail (rc 1) if over it, fail loudly (rc 2, message on stderr) if
# either argument is not a non-negative integer or TOTAL is 0. Pure integer arithmetic
# on two numbers the caller supplies, no filesystem access of its own — deliberately,
# so it is provable against ANY (total, live) pair, synthetic or real, without standing
# up a tree: see test/bin-reachability-gate.test.sh's RED call (this classifier's own
# real pre-fix 179/131 pair, which must fail) and GREEN call (this classifier's own
# real current 179/99 pair, which must pass) for the falsifiability proof, and the
# real-tree call a few lines later in that same file for the actual standing gate.
reach_vacuity_check() {
  local total="$1" live="$2" max_pct pct
  case "$total" in ''|*[!0-9]*) echo "reach_vacuity_check: TOTAL must be a non-negative integer, got '$total'" >&2; return 2 ;; esac
  case "$live"  in ''|*[!0-9]*) echo "reach_vacuity_check: LIVE must be a non-negative integer, got '$live'" >&2; return 2 ;; esac
  [ "$total" -gt 0 ] || { echo "reach_vacuity_check: TOTAL must be > 0" >&2; return 2; }
  max_pct="$(reach_vacuity_ceiling)"
  pct=$(( (live * 100) / total ))
  [ "$pct" -le "$max_pct" ]
}
