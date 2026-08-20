#!/usr/bin/env bash
#
# cli-help-no-expansion.test.sh — a CLI's --help must be TEXT, not a script.
#
# The bug this locks down (real, found 2026-08-20 in bin/designmatch): usage()
# wrote its help body through an UNQUOTED heredoc (`cat <<EOF`), so every
# backtick-quoted subcommand name in the prose was command-SUBSTITUTED at print
# time. `designmatch --help` emitted
#
#     bin/designmatch: line 62: web: command not found
#     bin/designmatch: line 62: ci: command not found
#
# on stderr and, worse, the substituted words VANISHED from the help itself —
# "One command on any web repo.  reads the receipt and BLOCKS a PR" had lost the
# `ci --min 0.95` it was documenting. Help text that silently deletes the very
# flag it describes is worse than no help. Under `set -e` a substitution that
# exits nonzero can also take the whole --help down.
#
# Proofs (each prints PASS/FAIL; exit 0 iff all hold):
#   1. `designmatch --help` exits 0, writes to STDOUT, and writes NOTHING to
#      stderr — no "command not found", no expansion diagnostic of any kind.
#   2. The documented subcommand names survive the print verbatim: the literal
#      backticked `web` and `ci --min 0.95` are both present in the output.
#   3. --help, -h and `help` agree byte-for-byte (one help body, three doors).
#   4. REPO-WIDE guard: no bin/ script prints a help body from an unquoted
#      heredoc containing an unescaped backtick. This is the class, not the
#      instance — the next CLI to grow prose backticks fails here, at authoring
#      time, instead of shipping a self-corrupting --help.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
DM="$REPO/bin/designmatch"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$DM" ] || { echo "FATAL: designmatch not executable at $DM" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. designmatch --help is clean: rc 0, stdout body, empty stderr"
"$DM" --help >"$WORK/help.out" 2>"$WORK/help.err"
rc=$?
[ "$rc" -eq 0 ] && ok "--help exits 0 (got $rc)" || bad "--help exits 0 (got $rc)"
if [ -s "$WORK/help.out" ]; then
  ok "--help writes a body to stdout ($(wc -l <"$WORK/help.out" | tr -d ' ') lines)"
else
  bad "--help writes a body to stdout (stdout was empty)"
fi
if [ -s "$WORK/help.err" ]; then
  bad "--help writes nothing to stderr — got: $(head -3 "$WORK/help.err" | tr '\n' '|')"
else
  ok "--help writes nothing to stderr"
fi
if grep -q 'command not found' "$WORK/help.err" "$WORK/help.out" 2>/dev/null; then
  bad "no 'command not found' anywhere in --help output"
else
  ok "no 'command not found' anywhere in --help output"
fi

echo "== 2. documented subcommand names survive the print verbatim"
for lit in '`web`' '`ci --min 0.95`'; do
  if grep -qF -- "$lit" "$WORK/help.out"; then
    ok "help retains literal $lit"
  else
    bad "help retains literal $lit (expansion ate it)"
  fi
done

echo "== 3. --help, -h and help agree byte-for-byte"
"$DM" -h    >"$WORK/h.out"    2>/dev/null
"$DM" help  >"$WORK/word.out" 2>/dev/null
if cmp -s "$WORK/help.out" "$WORK/h.out"; then
  ok "-h matches --help byte-for-byte"
else
  bad "-h matches --help byte-for-byte"
fi
if cmp -s "$WORK/help.out" "$WORK/word.out"; then
  ok "help matches --help byte-for-byte"
else
  bad "help matches --help byte-for-byte"
fi

echo "== 4. repo-wide: no unquoted help heredoc carries an unescaped backtick"
# For every bin/ script: find each `cat <<DELIM` whose DELIM is UNQUOTED, walk to
# its terminator, and flag an unescaped backtick inside that body. An escaped
# \` is fine (line 277 of designmatch does exactly that, correctly).
offenders="$(
  for f in "$REPO"/bin/*; do
    [ -f "$f" ] || continue
    head -1 "$f" | grep -qE '^#!.*(bash|sh)' || continue
    awk -v F="$f" '
      # opening an unquoted heredoc: cat <<DELIM (no quote, no dash-quote)
      !inhd && match($0, /<<-?[A-Za-z_][A-Za-z0-9_]*/) {
        tok = substr($0, RSTART, RLENGTH)
        gsub(/^<<-?/, "", tok)
        inhd = 1; delim = tok; start = NR; hits = 0
        next
      }
      inhd && $0 == delim {
        if (hits > 0) printf "%s:%d: unquoted heredoc <<%s has %d unescaped backtick(s)\n", F, start, delim, hits
        inhd = 0; next
      }
      inhd {
        line = $0
        gsub(/\\`/, "", line)     # escaped backticks are safe
        n = gsub(/`/, "`", line)
        hits += n
      }
    ' "$f"
  done
)"
if [ -z "$offenders" ]; then
  ok "no bin/ script expands backticks inside an unquoted heredoc"
else
  bad "unquoted heredocs with live backticks found:"
  printf '%s\n' "$offenders" | sed 's/^/       /'
fi

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
