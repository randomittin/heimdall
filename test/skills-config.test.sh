#!/usr/bin/env bash
#
# skills-config.test.sh — the per-operator skills settings (3.x M1, T0.2 of
# docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md).
#
# bin/lib/skills_config.py owns $HEIMDALL_HOME/skills-config.json: the `registry` flag the resolver
# call sites branch on, the `consent` mode and `allowlist` the install gate reads, and the
# `grandfathered` record the first-run rule leaves. The contract proven here:
#   A. defaults on an empty HEIMDALL_HOME: registry off, consent ask, no allowlist, not
#      grandfathered — and a read creates nothing on disk;
#   B. precedence env > file > default for the two keys with an env override (HMD_SKILLS_REGISTRY,
#      HMD_SKILLS_CONSENT); an empty variable is an unset one; the plan's documented full file reads;
#   C. never fatal on a read: a value that is not allowed, at the tier that wins, is reported on
#      stderr and replaced by the built-in default (a typo can never move consent toward install);
#      an unusable file (not JSON, not an object, nested past the parser, unreadable) is the same;
#   D. `set` validates, writes atomically with mode 0600, merges into the file (keys it does not know
#      survive), leaves no temp debris, never overwrites a file it cannot parse, and a failed write
#      keeps the old file;
#   E. the grandfather rule: `init --marker-present` records consent auto + grandfathered true,
#      `init --marker-absent` records consent ask — once: an existing file is never touched;
#   F. INV-S11: a repository cannot choose its operator's consent mode. A skills-config.json in the
#      project dir, .planning/, .heimdall/ or .claude/, and a stdlib module planted in the project
#      dir, change nothing; the file is always $HEIMDALL_HOME/skills-config.json (else
#      ~/.heimdall), never anything found from the cwd;
#   G. usage errors exit 2 and write nothing.
#
# Hermetic: HEIMDALL_HOME and HOME are throwaway dirs, no network, nothing outside $WORK is touched.
#
# Usage: test/skills-config.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CFG="$REPO/bin/lib/skills_config.py"
PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }

# The interpreter itself, not a version-manager shim: the sandbox below replaces HOME.
PY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -x "${PY:-}" ] || { echo "FATAL: python3 not found"; exit 2; }
[ -f "$CFG" ] || { echo "FATAL: $CFG missing"; exit 1; }

WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR"
HH=""            # HEIMDALL_HOME of the next call; empty = the variable is unset
CFG_CWD=""       # working directory of the next call; empty = $WORK
NONROOT=0; [ "$(id -u)" -ne 0 ] && NONROOT=1

# cfg [VAR=value ...] -- ARGS...   run `python3 -I skills_config.py ARGS` in the sandbox; sets OUT ERR RC.
# The operator's own HMD_SKILLS_* never leak in; HEIMDALL_HOME is $HH and HOME is the sandbox's.
cfg() {
  local unset_args=(-u HMD_SKILLS_REGISTRY -u HMD_SKILLS_CONSENT) assign_args=(HOME="$HOME_DIR")
  if [ -n "$HH" ]; then assign_args+=(HEIMDALL_HOME="$HH"); else unset_args+=(-u HEIMDALL_HOME); fi
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do assign_args+=("$1"); shift; done
  shift
  OUT="$(cd "${CFG_CWD:-$WORK}" && env "${unset_args[@]}" "${assign_args[@]}" "$PY" -I "$CFG" "$@" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
}
res() { printf '%s|%s|%s' "$OUT" "$RC" "$ERR"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
is_file()  { if [ -f "$2" ]; then ok "$1"; else bad "$1 (no file at $2)"; fi; }
no_path()  { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 ($2 exists)"; fi; }

# chk LABEL OUT [VAR=value ...] -- ARGS: the call prints OUT, exits 0 and says nothing on stderr
chk() { local label="$1" want="$2"; shift 2; cfg "$@"; eq "$label" "$want|0|" "$(res)"; }

# says LABEL OUT RC NEEDLE [VAR=value ...] -- ARGS: the call prints OUT, exits RC, names NEEDLE on stderr
# and never leaves a traceback there
says() {
  local label="$1" want_out="$2" want_rc="$3" needle="$4"; shift 4
  cfg "$@"
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
conf()   { printf '%s/skills-config.json' "$HH"; }

# ╔═ A. defaults ═══════════════════════════════════════════════════════════════════════╗
echo "A. defaults on an empty HEIMDALL_HOME"
HH="$WORK/hh-a"
chk "A: get registry prints off" off -- get registry
chk "A: get consent prints ask" ask -- get consent
chk "A: get allowlist prints nothing" "" -- get allowlist
chk "A: get grandfathered prints false" false -- get grandfathered
no_path "A: a read never creates HEIMDALL_HOME" "$HH"

# ╔═ B. precedence ═════════════════════════════════════════════════════════════════════╗
echo "B. precedence: env > file > default"
HH="$WORK/hh-b"
chk "B: HMD_SKILLS_REGISTRY=on flips registry to on" on HMD_SKILLS_REGISTRY=on -- get registry
chk "B: HMD_SKILLS_REGISTRY=off reads off" off HMD_SKILLS_REGISTRY=off -- get registry
chk "B: HMD_SKILLS_CONSENT=auto reads auto" auto HMD_SKILLS_CONSENT=auto -- get consent
chk "B: HMD_SKILLS_CONSENT=allowlist reads allowlist" allowlist HMD_SKILLS_CONSENT=allowlist -- get consent
chk "B: an env value is trimmed and case-folded" on "HMD_SKILLS_REGISTRY= ON " -- get registry
cfg -- set registry on
chk "B: the file beats the default (registry on)" on -- get registry
chk "B: env beats file: file on, env off" off HMD_SKILLS_REGISTRY=off -- get registry
cfg -- set registry off
chk "B: env beats file: file off, env on" on HMD_SKILLS_REGISTRY=on -- get registry
cfg -- set consent auto
chk "B: the file beats the default (consent auto)" auto -- get consent
chk "B: env beats file: file auto, env ask" ask HMD_SKILLS_CONSENT=ask -- get consent
chk "B: an empty variable counts as unset" auto HMD_SKILLS_CONSENT= -- get consent
HH="$WORK/hh-full"; mkdir -p "$HH"
printf '%s\n' '{"registry": "on", "consent": "auto", "allowlist": ["frontend-design", "slack"], "grandfathered": true}' > "$(conf)"
chk "B: the documented full file shape reads: registry" on -- get registry
chk "B: ... consent" auto -- get consent
chk "B: ... allowlist, one id per line" $'frontend-design\nslack' -- get allowlist
chk "B: ... grandfathered" true -- get grandfathered

# ╔═ C. never fatal on a read ══════════════════════════════════════════════════════════╗
echo "C. a value or file that cannot be used is reported, never fatal"
HH="$WORK/hh-c"
says "C: HMD_SKILLS_REGISTRY=maybe -> the default, named on stderr" off 0 HMD_SKILLS_REGISTRY HMD_SKILLS_REGISTRY=maybe -- get registry
says "C: HMD_SKILLS_CONSENT=yolo -> ask" ask 0 HMD_SKILLS_CONSENT HMD_SKILLS_CONSENT=yolo -- get consent
cfg -- set consent auto
says "C: a bad env value beats a good file and lands on the restrictive default (file auto, env yolo -> ask)" \
  ask 0 HMD_SKILLS_CONSENT HMD_SKILLS_CONSENT=yolo -- get consent
printf '%s\n' '{"registry": 5, "consent": "yolo", "allowlist": "x y", "grandfathered": "maybe"}' > "$(conf)"
says "C: a file registry of the wrong type -> off" off 0 registry -- get registry
says "C: a file consent that is not allowed -> ask" ask 0 consent -- get consent
says "C: a file allowlist that is not a list -> nothing pre-approved" "" 0 allowlist -- get allowlist
says "C: a file grandfathered that is not a boolean -> false" false 0 grandfathered -- get grandfathered
printf '%s\n' '{"allowlist": ["ok", "bad id", 7]}' > "$(conf)"
says "C: an allowlist with one bad entry is refused whole" "" 0 allowlist -- get allowlist
for body in '{not json' '' '[]' '"text"' 'null' '42'; do
  printf '%s' "$body" > "$(conf)"
  says "C: a file holding [$body] is reported and read as empty" off 0 skills-config.json -- get registry
done
"$PY" -I -c 'import sys; sys.stdout.write("[" * 100000)' > "$(conf)"
says "C: JSON nested past the parser's limit is reported, not a traceback" off 0 skills-config.json -- get registry
if [ "$NONROOT" -eq 1 ]; then
  printf '%s\n' '{"registry": "on"}' > "$(conf)"; chmod 000 "$(conf)"
  says "C: an unreadable file is reported and read as empty" off 0 skills-config.json -- get registry
  chmod 600 "$(conf)"
else
  skip "C: unreadable-file case (running as root: chmod 000 does not stop root)"
fi
HH="$WORK/hh-is-a-file"; : > "$HH"
says "C: HEIMDALL_HOME that is a regular file is reported and read as empty" off 0 skills-config.json -- get registry

# ╔═ D. set ════════════════════════════════════════════════════════════════════════════╗
echo "D. set: validated, atomic, 0600, merged"
HH="$WORK/hh-d"
chk "D: set registry on succeeds silently" "" -- set registry on
is_file "D: set created HEIMDALL_HOME and the file" "$(conf)"
eq "D: the file is mode 0600" 600 "$(fmode "$(conf)")"
eq "D: the file is sparse: only what was set" registry "$(jkeys "$(conf)")"
eq "D: registry is stored as the string on" '"on"' "$(jget "$(conf)" registry)"
chk "D: set consent auto succeeds silently" "" -- set consent auto
eq "D: a second set merges (registry survived)" "consent registry" "$(jkeys "$(conf)")"
chk "D: set grandfathered true" "" -- set grandfathered true
eq "D: grandfathered is stored as a JSON boolean" true "$(jget "$(conf)" grandfathered)"
chk "D: get grandfathered reads it back" true -- get grandfathered
chk "D: set grandfathered False (any case)" "" -- set grandfathered False
eq "D: ... stored false" false "$(jget "$(conf)" grandfathered)"
chk "D: set allowlist takes commas and spaces, dedupes, keeps order" "" -- set allowlist 'frontend-design, ui-ux-pro-max  frontend-design'
eq "D: allowlist is stored as a JSON list" '["frontend-design", "ui-ux-pro-max"]' "$(jget "$(conf)" allowlist)"
chk "D: get allowlist prints one id per line" $'frontend-design\nui-ux-pro-max' -- get allowlist
LONG128="$(printf '%0128d' 0 | tr 0 a)"
chk "D: an id of 128 characters is accepted" "" -- set allowlist "$LONG128"
chk "D: set allowlist '' clears it" "" -- set allowlist ''
eq "D: ... stored as an empty list" '[]' "$(jget "$(conf)" allowlist)"
chk "D: ... and get prints nothing" "" -- get allowlist
printf '%s\n' '{"future": [1, 2], "registry": "off"}' > "$(conf)"
chk "D: set into a file that has an unknown key" "" -- set registry on
eq "D: ... the unknown key survives" '[1, 2]' "$(jget "$(conf)" future)"
eq "D: ... and the set key changed" '"on"' "$(jget "$(conf)" registry)"
eq "D: no temp file is left in HEIMDALL_HOME" "skills-config.json" "$(ls -A "$HH")"

rejects() {  # KEY VALUE: set exits 2 naming the key, and the file is byte for byte what it was
  local before after
  before="$(cat "$(conf)" 2>/dev/null; echo end)"
  says "D: set $1 '$2' is rejected" "" 2 "$1" -- set "$1" "$2"
  after="$(cat "$(conf)" 2>/dev/null; echo end)"
  eq "D: ... and the file is untouched" "$before" "$after"
}
rejects consent yolo
rejects registry maybe
rejects registry ''
rejects grandfathered yes
rejects allowlist 'ok;rm'
rejects allowlist '../etc'
rejects allowlist "${LONG128}a"
rejects nosuchkey on

printf '%s' '{not json' > "$(conf)"
says "D: set refuses to overwrite a file it cannot parse" "" 1 skills-config.json -- set registry on
eq "D: ... and leaves it exactly as it was" '{not json' "$(cat "$(conf)")"

if [ "$NONROOT" -eq 1 ]; then
  HH="$WORK/hh-d-ro"
  cfg -- set registry on
  before="$(cat "$(conf)")"
  chmod 500 "$HH"
  says "D: a write that cannot be made exits 1 with a message" "" 1 failed -- set registry off
  chmod 700 "$HH"
  eq "D: ... the old file survives a failed write" "$before" "$(cat "$(conf)")"
  eq "D: ... and no temp file is left behind" "skills-config.json" "$(ls -A "$HH")"
else
  skip "D: failed-write case (running as root: chmod 500 does not stop root)"
fi

HH=""   # HEIMDALL_HOME unset: the launcher's own fallback, $HOME/.heimdall
chk "D: HEIMDALL_HOME unset -> set writes \$HOME/.heimdall" "" HOME="$WORK/home-unset" -- set consent auto
is_file "D: ... the file is \$HOME/.heimdall/skills-config.json" "$WORK/home-unset/.heimdall/skills-config.json"
chk "D: HEIMDALL_HOME empty -> the same fallback" "" HEIMDALL_HOME= HOME="$WORK/home-empty" -- set registry on
is_file "D: ... \$HOME/.heimdall/skills-config.json" "$WORK/home-empty/.heimdall/skills-config.json"
chk "D: HEIMDALL_HOME unset -> get reads \$HOME/.heimdall" auto HOME="$WORK/home-unset" -- get consent

# ╔═ E. the grandfather rule ═══════════════════════════════════════════════════════════╗
echo "E. init: the grandfather rule, once"
HH="$WORK/hh-e-present"
chk "E: init --marker-present succeeds silently" "" -- init --marker-present
eq "E: ... records consent auto" '"auto"' "$(jget "$(conf)" consent)"
eq "E: ... and grandfathered true" true "$(jget "$(conf)" grandfathered)"
eq "E: ... in a file of mode 0600" 600 "$(fmode "$(conf)")"
chk "E: get consent -> auto after init --marker-present" auto -- get consent
chk "E: get grandfathered -> true" true -- get grandfathered
HH="$WORK/hh-e-absent"
chk "E: init --marker-absent succeeds silently" "" -- init --marker-absent
eq "E: ... records consent ask" '"ask"' "$(jget "$(conf)" consent)"
eq "E: ... and grandfathered false" false "$(jget "$(conf)" grandfathered)"
chk "E: get consent -> ask after init --marker-absent" ask -- get consent
chk "E: init runs once: a marker that appears later changes nothing" "" -- init --marker-present
eq "E: ... consent is still ask" '"ask"' "$(jget "$(conf)" consent)"
eq "E: ... grandfathered is still false" false "$(jget "$(conf)" grandfathered)"
HH="$WORK/hh-e-existing"; mkdir -p "$HH"
printf '%s\n' '{"registry": "on"}' > "$(conf)"; before="$(cat "$(conf)")"
chk "E: init over an existing file succeeds" "" -- init --marker-present
eq "E: ... and leaves it byte for byte alone" "$before" "$(cat "$(conf)")"
chk "E: ... so consent is still the default, not grandfathered" ask -- get consent
HH="$WORK/hh-e-corrupt"; mkdir -p "$HH"
printf '%s' '{not json' > "$(conf)"
chk "E: init over a corrupt file succeeds" "" -- init --marker-present
eq "E: ... and does not touch it" '{not json' "$(cat "$(conf)")"
HH="$WORK/e/deep/er/hh"
chk "E: init creates missing parent directories" "" -- init --marker-absent
is_file "E: ... the file is there" "$(conf)"
if [ "$NONROOT" -eq 1 ]; then
  mkdir -p "$WORK/e-ro"; chmod 500 "$WORK/e-ro"
  HH="$WORK/e-ro/hh"
  says "E: init that cannot write exits 1 with a message" "" 1 failed -- init --marker-present
  chmod 700 "$WORK/e-ro"
else
  skip "E: unwritable-home case (running as root)"
fi

# ╔═ F. INV-S11: a repository cannot choose ═════════════════════════════════════════════╗
echo "F. INV-S11: nothing in the project dir is read or written"
PROJ="$WORK/proj"; mkdir -p "$PROJ/.planning" "$PROJ/.heimdall" "$PROJ/.claude"
DECOY='{"registry": "on", "consent": "auto", "allowlist": ["evil"], "grandfathered": true}'
for d in "$PROJ" "$PROJ/.planning" "$PROJ/.heimdall" "$PROJ/.claude"; do printf '%s\n' "$DECOY" > "$d/skills-config.json"; done
printf 'import sys\nsys.exit(97)\n' > "$PROJ/json.py"      # a planted stdlib module: -I must not import it
HH="$WORK/hh-f"; CFG_CWD="$PROJ"
chk "F: registry ignores every repo file and a planted json.py" off WORK_DIR="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" -- get registry
chk "F: consent ignores them" ask WORK_DIR="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" -- get consent
chk "F: allowlist ignores them" "" WORK_DIR="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" -- get allowlist
chk "F: grandfathered ignores them" false WORK_DIR="$PROJ" CLAUDE_PROJECT_DIR="$PROJ" -- get grandfathered
HH=""; mkdir -p "$WORK/home-f"
chk "F: with HEIMDALL_HOME unset, ~/.heimdall is read, not the cwd's .heimdall" off HOME="$WORK/home-f" -- get registry
HH="$WORK/hh-f"
before="$(cd "$PROJ" && find . -type f -exec cksum {} + | sort)"
cfg -- init --marker-absent
cfg -- set registry off
after="$(cd "$PROJ" && find . -type f -exec cksum {} + | sort)"
eq "F: init and set from inside a repo change no file in it and add none" "$before" "$after"
eq "F: ... they write HEIMDALL_HOME: init's record and set's key are both there" "consent grandfathered registry" "$(jkeys "$(conf)")"
HH="$WORK/hh-f-control"; mkdir -p "$HH"; cp "$PROJ/skills-config.json" "$(conf)"
chk "F: control: the same decoy at the real path IS read (so the decoy is well formed)" on -- get registry
CFG_CWD=""

# ╔═ G. usage ══════════════════════════════════════════════════════════════════════════╗
echo "G. usage errors exit 2 and write nothing"
HH="$WORK/hh-g"
says "G: no arguments" "" 2 usage: --
says "G: get with no key" "" 2 usage: -- get
says "G: get of an unknown key" "" 2 nosuchkey -- get nosuchkey
says "G: set with no value" "" 2 usage: -- set registry
says "G: an unknown subcommand" "" 2 usage: -- frob
says "G: init with no flag" "" 2 usage: -- init
says "G: init with both flags" "" 2 usage: -- init --marker-present --marker-absent
says "G: init with an unknown flag" "" 2 usage: -- init --bogus
no_path "G: none of them created HEIMDALL_HOME" "$HH"

echo "--------------------------------------------------------------------"
printf 'skills-config: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
