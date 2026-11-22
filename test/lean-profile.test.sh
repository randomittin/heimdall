#!/usr/bin/env bash
#
# lean-profile.test.sh — the install profile record (lean-core plan T1.1,
# docs/superpowers/plans/2026-11-12-3x-lean-core.md; invariants: .planning/lean-core/INVARIANTS.md).
#
# bin/lib/hmd_profile.py records which profile a machine runs, `lean` or `full`, in $HEIMDALL_HOME/profile.json. It moves
# no file and edits no settings: it is the record the install, `hmd lean on|off` and `install.sh --reset` read and write.
# The contract proven here:
#   A. defaults: no file, or a file without a profile, reads `full` (the default changes nothing), silently, and a read
#      creates nothing on disk;
#   B. init, once (INV-L2): the setup marker seen -> `full`, absent -> `lean`; a file that is already there is never
#      touched, valid or not, a dangling link included, so nothing flips by itself whichever flag a later run passes;
#   C. init also reads skills-config.json: `grandfathered: true` is `full` even with the marker gone, and anything that is
#      not plainly "not grandfathered" (another type, a file that cannot be read) errs toward `full`: lean needs positive
#      evidence of a fresh install. That file is only read, never written;
#   D. set validates, writes atomically with mode 0600, merges into the file (keys it does not know survive), leaves no
#      temp debris, never overwrites a file it cannot parse, and a failed write keeps the old file; it is the one way a
#      recorded profile changes;
#   E. never fatal on a read: a value that is not allowed, or a file that cannot be used, is said on stderr and read as
#      the default `full`, never a traceback;
#   F. never from a repository: a profile.json or skills-config.json in the project dir, .planning/, .heimdall/ or
#      .claude/, and a stdlib module planted in the project dir, change nothing;
#   G. INV-L12: lean is only a recorded value. Choosing it writes one file in HEIMDALL_HOME and nothing under HOME (no
#      `claude` wrapper, settings, rc file or proxy state), and the answer does not depend on a proxy route in the
#      environment (ANTHROPIC_BASE_URL, HEADROOM_*, HTTPS_PROXY): lean never routes a session anywhere;
#   H. usage errors exit 2 and write nothing; the plan's acceptance one-liner runs.
#
# Hermetic: HEIMDALL_HOME and HOME are throwaway dirs, the environment is cleared (env -i), no network, nothing outside
# $WORK is touched. bash 3.2 compatible.
#
# Usage: test/lean-profile.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib/hmd_profile.py"
PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }

# The real interpreter, not a version-manager wrapper: the sandbox below replaces HOME and clears the environment.
PY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -x "${PY:-}" ] || { echo "FATAL: python3 not found"; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }

WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR"
HH=""            # HEIMDALL_HOME of the next call; empty = the variable is unset
CALL_CWD=""      # working directory of the next call; empty = $WORK
CASE=0
NONROOT=0; [ "$(id -u)" -ne 0 ] && NONROOT=1

# pf [VAR=value ...] -- ARGS...   run `python3 -I hmd_profile.py ARGS` in the sandbox; sets OUT ERR RC.
# The environment is cleared: only PATH, HOME (the sandbox's, unless a VAR=value overrides it) and HEIMDALL_HOME ($HH) get in.
pf() {
  local assign_args=(HOME="$HOME_DIR" PATH="$PATH")
  if [ -n "$HH" ]; then assign_args+=(HEIMDALL_HOME="$HH"); fi
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do assign_args+=("$1"); shift; done
  shift
  OUT="$(cd "${CALL_CWD:-$WORK}" && env -i "${assign_args[@]}" "$PY" -I "$LIB" "$@" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
}
res() { printf '%s|%s|%s' "$OUT" "$RC" "$ERR"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
is_file()  { if [ -f "$2" ]; then ok "$1"; else bad "$1 (no file at $2)"; fi; }
no_path()  { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 ($2 exists)"; fi; }

# chk LABEL OUT [VAR=value ...] -- ARGS: the call prints OUT, exits 0 and says nothing on stderr
chk() { local label="$1" want="$2"; shift 2; pf "$@"; eq "$label" "$want|0|" "$(res)"; }

# says LABEL OUT RC NEEDLE [VAR=value ...] -- ARGS: the call prints OUT, exits RC, names NEEDLE on stderr
# and never leaves a traceback there
says() {
  local label="$1" want_out="$2" want_rc="$3" needle="$4"; shift 4
  pf "$@"
  if [ "$OUT" != "$want_out" ] || [ "$RC" -ne "$want_rc" ]; then bad "$label (out=[$OUT] rc=$RC err=[$ERR])"; return; fi
  case "$ERR" in
    *Traceback*) bad "$label (a traceback: $ERR)" ;;
    *"$needle"*) ok "$label" ;;
    *)           bad "$label (stderr does not name [$needle]: [$ERR])" ;;
  esac
}

fmode()  { "$PY" -I -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"; }
jget()   { "$PY" -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(json.dumps(d[sys.argv[2]]) if sys.argv[2] in d else "<absent>")' "$1" "$2"; }
jkeys()  { "$PY" -I -c 'import json, sys; print(" ".join(sorted(json.load(open(sys.argv[1])))))' "$1"; }
pjson()  { printf '%s/profile.json' "$HH"; }
sconf()  { printf '%s/skills-config.json' "$HH"; }

# ╔═ A. defaults ═══════════════════════════════════════════════════════════════════════╗
echo "A. defaults: no record reads full, and a read creates nothing"
HH="$WORK/hh-a"
chk "A: get on an empty HEIMDALL_HOME prints full" full -- get
no_path "A: a read never creates HEIMDALL_HOME" "$HH"
mkdir -p "$HH"; printf '%s\n' '{"future": 1}' > "$(pjson)"
chk "A: a file with no profile key reads full, silently" full -- get
HH=""   # HEIMDALL_HOME unset: the launcher's own fallback, $HOME/.heimdall
chk "A: HEIMDALL_HOME unset and no ~/.heimdall reads full" full HOME="$WORK/home-a-none" -- get
no_path "A: ... and a read creates no ~/.heimdall" "$WORK/home-a-none/.heimdall"

# ╔═ B. init, once ═════════════════════════════════════════════════════════════════════╗
echo "B. init: derived once (INV-L2)"
HH="$WORK/hh-b-present"
chk "B: init --marker-present succeeds silently" "" -- init --marker-present
chk "B: ... get prints full" full -- get
eq "B: ... the file is mode 0600" 600 "$(fmode "$(pjson)")"
eq "B: ... it holds only the profile key" profile "$(jkeys "$(pjson)")"
eq "B: ... stored as the string full" '"full"' "$(jget "$(pjson)" profile)"
HH="$WORK/hh-b-absent"
chk "B: init --marker-absent succeeds silently" "" -- init --marker-absent
chk "B: ... get prints lean" lean -- get
eq "B: ... the file is mode 0600" 600 "$(fmode "$(pjson)")"
eq "B: ... stored as the string lean" '"lean"' "$(jget "$(pjson)" profile)"
before="$(cat "$(pjson)"; echo end)"
chk "B: a marker that appears later changes nothing (init --marker-present over lean)" "" -- init --marker-present
eq "B: ... the file is byte for byte what it was" "$before" "$(cat "$(pjson)"; echo end)"
chk "B: ... get is still lean" lean -- get
HH="$WORK/hh-b-present"
chk "B: a marker that goes later changes nothing (init --marker-absent over full)" "" -- init --marker-absent
chk "B: ... get is still full" full -- get
HH="$WORK/hh-b-existing"; mkdir -p "$HH"
printf '%s\n' '{"future": 1}' > "$(pjson)"; before="$(cat "$(pjson)")"
chk "B: init over an existing file without a profile succeeds" "" -- init --marker-absent
eq "B: ... and leaves it byte for byte alone" "$before" "$(cat "$(pjson)")"
chk "B: ... so get reads the default full, not a derived lean" full -- get
HH="$WORK/hh-b-corrupt"; mkdir -p "$HH"
printf '%s' '{not json' > "$(pjson)"
chk "B: init over a corrupt file succeeds" "" -- init --marker-absent
eq "B: ... and does not touch it" '{not json' "$(cat "$(pjson)")"
HH="$WORK/hh-b-link"; mkdir -p "$HH"
ln -s "$WORK/nowhere" "$(pjson)"
chk "B: init over a dangling link succeeds" "" -- init --marker-absent
no_path "B: ... and writes nothing through it" "$WORK/nowhere"
if [ -L "$(pjson)" ]; then ok "B: ... the link is still a link"; else bad "B: ... the link was replaced"; fi
HH="$WORK/b/deep/er/hh"
chk "B: init creates missing parent directories" "" -- init --marker-absent
is_file "B: ... the file is there" "$(pjson)"
if [ "$NONROOT" -eq 1 ]; then
  mkdir -p "$WORK/b-ro"; chmod 500 "$WORK/b-ro"
  HH="$WORK/b-ro/hh"
  says "B: init that cannot write exits 1 with a message" "" 1 failed -- init --marker-absent
  chmod 700 "$WORK/b-ro"
else
  skip "B: unwritable-home case (running as root)"
fi

# ╔═ C. the grandfather read ═══════════════════════════════════════════════════════════╗
echo "C. init reads skills-config.json: lean needs positive evidence of a fresh install"
gf() {  # LABEL BODY WANT: skills-config.json holds BODY; init --marker-absent records WANT and only reads that file
  local label="$1" body="$2" want="$3" before
  CASE=$((CASE + 1)); HH="$WORK/hh-c-$CASE"; mkdir -p "$HH"
  printf '%s\n' "$body" > "$(sconf)"; before="$(cat "$(sconf)")"
  chk "$label: init --marker-absent succeeds silently" "" -- init --marker-absent
  eq "$label: ... records $want" "\"$want\"" "$(jget "$(pjson)" profile)"
  eq "$label: ... and skills-config.json is not touched" "$before" "$(cat "$(sconf)")"
}
gf "C: grandfathered true (the marker is gone, the install is not new)" '{"consent": "auto", "grandfathered": true}' full
gf "C: grandfathered false" '{"consent": "ask", "grandfathered": false}' lean
gf "C: a file without the key (the default is false)" '{"registry": "on"}' lean
gf "C: grandfathered of another type" '{"grandfathered": "maybe"}' full
gf "C: grandfathered 0, which is not the boolean false" '{"grandfathered": 0}' full
gf "C: grandfathered null" '{"grandfathered": null}' full
gf "C: a file that is not JSON" '{not json' full
gf "C: a file that is not an object" '[]' full
HH="$WORK/hh-c-marker"; mkdir -p "$HH"
printf '%s\n' '{"grandfathered": false}' > "$(sconf)"
chk "C: the marker present beats grandfathered false: init --marker-present" "" -- init --marker-present
eq "C: ... records full" '"full"' "$(jget "$(pjson)" profile)"
if [ "$NONROOT" -eq 1 ]; then
  HH="$WORK/hh-c-unreadable"; mkdir -p "$HH"
  printf '%s\n' '{"grandfathered": false}' > "$(sconf)"; chmod 000 "$(sconf)"
  chk "C: an unreadable skills-config.json: init --marker-absent succeeds" "" -- init --marker-absent
  eq "C: ... and records full, not lean" '"full"' "$(jget "$(pjson)" profile)"
  chmod 600 "$(sconf)"
else
  skip "C: unreadable-file case (running as root: chmod 000 does not stop root)"
fi

# ╔═ D. set ════════════════════════════════════════════════════════════════════════════╗
echo "D. set: validated, atomic, 0600, merged"
HH="$WORK/hh-d"
chk "D: set lean succeeds silently" "" -- set lean
is_file "D: set created HEIMDALL_HOME and the file" "$(pjson)"
eq "D: the file is mode 0600" 600 "$(fmode "$(pjson)")"
eq "D: the file holds only what was set" profile "$(jkeys "$(pjson)")"
eq "D: profile is stored as the string lean" '"lean"' "$(jget "$(pjson)" profile)"
chk "D: get reads it back" lean -- get
chk "D: set full succeeds silently" "" -- set full
chk "D: get reads full" full -- get
chk "D: set takes any case and trims" "" -- set ' LEAN '
eq "D: ... stored as lean" '"lean"' "$(jget "$(pjson)" profile)"
printf '%s\n' '{"future": [1, 2], "profile": "full"}' > "$(pjson)"
chk "D: set into a file that has an unknown key" "" -- set lean
eq "D: ... the unknown key survives" '[1, 2]' "$(jget "$(pjson)" future)"
eq "D: ... and the profile changed" '"lean"' "$(jget "$(pjson)" profile)"
eq "D: no temp file is left in HEIMDALL_HOME" "profile.json" "$(ls -A "$HH")"
HH="$WORK/hh-d-flip"
chk "D: init --marker-present records full" "" -- init --marker-present
chk "D: set lean is what flips a recorded profile" "" -- set lean
chk "D: ... get is lean" lean -- get
chk "D: set full flips it back" "" -- set full
chk "D: ... get is full" full -- get

rejects() {  # VALUE: set exits 2 naming the profile, and the file is byte for byte what it was
  local before after
  before="$(cat "$(pjson)" 2>/dev/null; echo end)"
  says "D: set '$1' is rejected" "" 2 profile -- set "$1"
  after="$(cat "$(pjson)" 2>/dev/null; echo end)"
  eq "D: ... and the file is untouched" "$before" "$after"
}
HH="$WORK/hh-d"
rejects yolo
rejects ''
rejects 'lean full'
rejects 'lean;rm'
rejects leaner
rejects on

printf '%s' '{not json' > "$(pjson)"
says "D: set refuses to overwrite a file it cannot parse" "" 1 profile.json -- set lean
eq "D: ... and leaves it exactly as it was" '{not json' "$(cat "$(pjson)")"

if [ "$NONROOT" -eq 1 ]; then
  HH="$WORK/hh-d-ro"
  pf -- set lean
  before="$(cat "$(pjson)")"
  chmod 500 "$HH"
  says "D: a write that cannot be made exits 1 with a message" "" 1 failed -- set full
  chmod 700 "$HH"
  eq "D: ... the old file survives a failed write" "$before" "$(cat "$(pjson)")"
  eq "D: ... and no temp file is left behind" "profile.json" "$(ls -A "$HH")"
else
  skip "D: failed-write case (running as root: chmod 500 does not stop root)"
fi

HH=""   # HEIMDALL_HOME unset: the launcher's own fallback, $HOME/.heimdall
chk "D: HEIMDALL_HOME unset -> set writes \$HOME/.heimdall" "" HOME="$WORK/home-unset" -- set lean
is_file "D: ... the file is \$HOME/.heimdall/profile.json" "$WORK/home-unset/.heimdall/profile.json"
chk "D: HEIMDALL_HOME empty -> the same fallback" "" HEIMDALL_HOME= HOME="$WORK/home-empty" -- set lean
is_file "D: ... \$HOME/.heimdall/profile.json" "$WORK/home-empty/.heimdall/profile.json"
chk "D: HEIMDALL_HOME unset -> get reads \$HOME/.heimdall" lean HOME="$WORK/home-unset" -- get

# ╔═ E. never fatal on a read ══════════════════════════════════════════════════════════╗
echo "E. a value or file that cannot be used is reported and read as full, never fatal"
HH="$WORK/hh-e"; mkdir -p "$HH"
for v in '"yolo"' '5' 'null' 'true' '""' '["lean"]' '{"x": 1}' '"Lean"' '"FULL"' '"lean "'; do
  printf '{"profile": %s}\n' "$v" > "$(pjson)"
  says "E: a stored profile of $v is reported and read as full" full 0 profile.json -- get
done
for body in '{not json' '' '[]' '"text"' 'null' '42'; do
  printf '%s' "$body" > "$(pjson)"
  says "E: a file holding [$body] is reported and read as full" full 0 profile.json -- get
done
"$PY" -I -c 'import sys; sys.stdout.write("[" * 100000)' > "$(pjson)"
says "E: JSON nested past the parser's limit is reported, not a traceback" full 0 profile.json -- get
if [ "$NONROOT" -eq 1 ]; then
  printf '%s\n' '{"profile": "lean"}' > "$(pjson)"; chmod 000 "$(pjson)"
  says "E: an unreadable file is reported and read as full" full 0 profile.json -- get
  chmod 600 "$(pjson)"
else
  skip "E: unreadable-file case (running as root: chmod 000 does not stop root)"
fi
HH="$WORK/hh-e-is-a-file"; : > "$HH"
says "E: HEIMDALL_HOME that is a regular file is reported and read as full" full 0 profile.json -- get
HH="$WORK/hh-e"
printf '%s\n' '{"profile": "lean"}' > "$(pjson)"
chk "E: control: a well-formed lean file reads lean" lean -- get

# ╔═ F. never from a repository ════════════════════════════════════════════════════════╗
echo "F. a repository cannot choose: nothing in the project dir is read or written"
PROJ="$WORK/proj"; mkdir -p "$PROJ/.planning" "$PROJ/.heimdall" "$PROJ/.claude"
for d in "$PROJ" "$PROJ/.planning" "$PROJ/.heimdall" "$PROJ/.claude"; do
  printf '%s\n' '{"profile": "lean"}' > "$d/profile.json"
  printf '%s\n' '{"grandfathered": true}' > "$d/skills-config.json"
done
printf 'import sys\nsys.exit(97)\n' > "$PROJ/json.py"      # a planted stdlib module: -I must not import it
HH="$WORK/hh-f"; CALL_CWD="$PROJ"
chk "F: get ignores every repo profile.json and a planted json.py" full WORK_DIR="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" -- get
before="$(cd "$PROJ" && find . -type f -exec cksum {} + | sort)"
chk "F: init ignores a repo skills-config.json that says grandfathered" "" WORK_DIR="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" -- init --marker-absent
chk "F: ... so what it records is lean" lean WORK_DIR="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" -- get
chk "F: set from inside a repo succeeds" "" WORK_DIR="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" -- set full
after="$(cd "$PROJ" && find . -type f -exec cksum {} + | sort)"
eq "F: init and set from inside a repo change no file in it and add none" "$before" "$after"
eq "F: ... they write HEIMDALL_HOME: the profile is there" profile "$(jkeys "$(pjson)")"
HH="$WORK/hh-f-control-profile"; mkdir -p "$HH"; cp "$PROJ/profile.json" "$(pjson)"
chk "F: control: the same decoy profile.json at the real path IS read (so the decoy is well formed)" lean -- get
HH="$WORK/hh-f-control-config"; mkdir -p "$HH"; cp "$PROJ/skills-config.json" "$(sconf)"
chk "F: control: the same decoy skills-config.json at the real path IS read" "" -- init --marker-absent
eq "F: ... and makes init record full" '"full"' "$(jget "$(pjson)" profile)"
HH=""; mkdir -p "$WORK/home-f"
chk "F: with HEIMDALL_HOME unset, ~/.heimdall is read, not the cwd's .heimdall" full HOME="$WORK/home-f" -- get
CALL_CWD=""

# ╔═ G. INV-L12: lean is a recorded value and nothing else ═════════════════════════════╗
echo "G. INV-L12: lean writes one file in HEIMDALL_HOME, nothing under HOME, and ignores the route"
HOME_G="$WORK/home-g"; mkdir -p "$HOME_G"
HH="$WORK/hh-g"
chk "G: init --marker-absent (lean) succeeds silently" "" HOME="$HOME_G" -- init --marker-absent
eq "G: ... HEIMDALL_HOME holds profile.json and nothing else" "profile.json" "$(ls -A "$HH")"
eq "G: ... nothing at all is written under HOME (no claude wrapper, settings, rc file or proxy state)" "" "$(ls -A "$HOME_G")"
chk "G: set lean succeeds silently" "" HOME="$HOME_G" -- set lean
eq "G: ... HEIMDALL_HOME still holds profile.json and nothing else" "profile.json" "$(ls -A "$HH")"
eq "G: ... and HOME is still empty" "" "$(ls -A "$HOME_G")"
chk "G: a live proxy route in the environment changes nothing: get reads lean" lean HOME="$HOME_G" \
  ANTHROPIC_BASE_URL=http://127.0.0.1:8787 HEADROOM_PORT=8787 HEADROOM_URL=http://127.0.0.1:8787 HTTPS_PROXY=http://127.0.0.1:8787 -- get
HH="$WORK/hh-g-route"
chk "G: init under that route records lean exactly as without it" "" HOME="$HOME_G" \
  ANTHROPIC_BASE_URL=http://127.0.0.1:8787 HEADROOM_PORT=8787 HEADROOM_URL=http://127.0.0.1:8787 HTTPS_PROXY=http://127.0.0.1:8787 -- init --marker-absent
eq "G: ... lean is what it recorded" '"lean"' "$(jget "$(pjson)" profile)"
eq "G: ... and HOME is still empty" "" "$(ls -A "$HOME_G")"
HH="$WORK/hh-g-config"; mkdir -p "$HH"
printf '%s\n' '{"consent": "ask", "grandfathered": false}' > "$(sconf)"; before="$(cat "$(sconf)")"
pf HOME="$HOME_G" -- set lean
eq "G: set lean leaves the consent record (skills-config.json) as it was" "$before" "$(cat "$(sconf)")"

# ╔═ H. usage and the plan's acceptance command ════════════════════════════════════════╗
echo "H. usage errors exit 2 and write nothing; the acceptance one-liner runs"
HH="$WORK/hh-h"
says "H: no arguments" "" 2 usage: --
says "H: get with an argument" "" 2 usage: -- get now
says "H: set with no value" "" 2 usage: -- set
says "H: set with two values" "" 2 usage: -- set lean full
says "H: an unknown subcommand" "" 2 usage: -- frob
says "H: init with no flag" "" 2 usage: -- init
says "H: init with both flags" "" 2 usage: -- init --marker-present --marker-absent
says "H: init with an unknown flag" "" 2 usage: -- init --bogus
no_path "H: none of them created HEIMDALL_HOME" "$HH"
if env -i HOME="$HOME_DIR" PATH="$PATH" HEIMDALL_HOME="$HH" "$PY" -I "$LIB" get | grep -qx 'lean\|full'; then
  ok "H: the plan's acceptance command (get | grep -qx 'lean\\|full') passes"
else
  bad "H: the plan's acceptance command (get | grep -qx 'lean\\|full') fails"
fi

echo "--------------------------------------------------------------------"
printf 'lean-profile: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
