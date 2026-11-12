#!/usr/bin/env bash
#
# skills-autoinstall-doc.test.sh — the agent instructions for installing plugins are consent-first (3.x M1, T5.3).
#
# skills/heimdall/references/plugin-autoinstall.md is what the orchestrator agent reads to decide what to install, and agents/heimdall.md §2c
# tells it to read that file. Both used to say "install it automatically. Don't ask". The consent model of the skill registry (plan "Consent
# model") is that a NEW install happens only with the person's yes, so the text now sends an agent through `hmd skills install <id>`, whose exit
# code carries the decision: 3 = consent required = the agent asks the person and re-runs with --yes only after they agree
# (bin/lib/skills_cli_install.py). Consent is COOPERATIVE for an agent (in M1 the Bash hook does not deny a raw `claude` plugin install), so the
# text is the control, and an LLM following it is not machine-verifiable (plan risk R5): this suite pins the text, not the model's behaviour.
#
# `verdict DOC AGENTS` prints one `key: reason` line per broken proof and nothing when every proof holds. The proofs:
#   generated    the doc's two tables are generated blocks (part=auto-install and part=mid-task, flavour=ask, no other) and
#                `skills_render_doc.py --check` finds them current: the doc cannot drift from skills.manifest.json
#   ask-flavour  the install-command column is `hmd skills install <id>`, so the doc holds no `claude plugins install` at all, in a
#                generated row or in prose (the plan: none outside the generated rows' install-command column)
#   exit-codes   the doc has a row for every exit code skills_cli_install.py can return (read from the module's own EXIT table)
#   exit-3       the exit 3 row says `consent required` and `ask the user`
#   yes-rule     `--yes` is for after the person agreed, never on the agent's own
#   old-rule     "install it automatically ... Don't ask" is gone, from the doc and from agents/heimdall.md
#   agents-2c    agents/heimdall.md §2c carries the consent wording (hmd skills install, consent required, ask the user) and its pointer
#   pointer      agents/heimdall.md still points at plugin-autoinstall.md
# Then every proof is shown to go RED: ONE line of a throwaway copy is changed at a time, and the verdict must name the proof that guards it.
#
# Hermetic: a throwaway WORK dir, no network, no `claude`, nothing outside WORK is written.
#
# Usage: test/skills-autoinstall-doc.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (0.3-0.8 s a call, and this suite starts about fifteen)
PYREAL="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
if [ -n "$PYREAL" ] && [ -x "$PYREAL" ]; then PY="$PYREAL"; fi

RENDER="$REPO/bin/lib/skills_render_doc.py"
DOC="$REPO/skills/heimdall/references/plugin-autoinstall.md"
AGENTS="$REPO/agents/heimdall.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The exit codes `hmd skills install` can return, read from the module that returns them (not copied here). dont_write_bytecode first:
# importing a module must not leave a .pyc in the plugin directory.
CODES="$("$PY" -I -c 'import sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1]); import skills_cli_install as m; print(" ".join(str(c) for c in sorted(set(m.EXIT.values()))))' "$REPO/bin/lib" 2>"$WORK/codes.err")"
case " $CODES " in
  *" 0 "*" 3 "*) ok "setup: skills_cli_install.py's EXIT table is readable and has 0 and 3 (codes: $CODES)" ;;
  *) bad "setup: could not read the exit codes of skills_cli_install.py (got '$CODES'): $(head -c 200 "$WORK/codes.err")" ;;
esac
[ -f "$DOC" ] && [ -f "$AGENTS" ] && ok "setup: the doc and agents/heimdall.md exist" || bad "setup: the doc or agents/heimdall.md is missing"

BEGIN_ASK='<!-- BEGIN GENERATED skills.manifest part=%s flavour=ask -->'

# verdict DOC AGENTS — one `key: reason` line per broken proof; nothing when they all hold. No backticks inside the double-quoted messages.
verdict() {
  local doc="$1" agents="$2" begins want rc err n row sec phrase need code
  # generated
  begins="$(grep '^<!-- BEGIN GENERATED skills.manifest' "$doc")"
  # shellcheck disable=SC2059  # BEGIN_ASK is a format string on purpose
  want="$(printf "$BEGIN_ASK" auto-install)"$'\n'"$(printf "$BEGIN_ASK" mid-task)"
  [ "$begins" = "$want" ] || echo "generated: want exactly the auto-install block then the mid-task block, both flavour=ask; found: $(printf '%s' "$begins" | tr '\n' ' ' | cut -c1-240)"
  err="$("$PY" -I "$RENDER" --check "$doc" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || echo "generated: skills_render_doc.py --check exited $rc: $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-240)"
  # ask-flavour
  n="$(grep -c 'claude plugins install' "$doc")"
  [ "$n" -eq 0 ] || echo "ask-flavour: $n line(s) of the doc still say claude plugins install (the command is hmd skills install)"
  # exit-codes
  for code in $CODES; do
    grep -q "^| $code |" "$doc" || echo "exit-codes: the doc has no table row for exit $code"
  done
  # exit-3
  row="$(grep '^| 3 |' "$doc" | head -1)"
  case "$row" in
    *"consent required"*"ask the user"*) ;;
    *) echo "exit-3: the exit 3 row must say consent required and then ask the user (row: ${row:0:200})" ;;
  esac
  # yes-rule
  grep -qE 'Only after the user agrees.*--yes' "$doc" || echo "yes-rule: no line says --yes is re-run only after the user agrees"
  grep -qF 'Never pass `--yes`' "$doc" || echo "yes-rule: no line says never to pass --yes on the agent's own"
  # old-rule
  sec="$(awk '/^### 2c\. /{f=1; print; next} f && /^### /{exit} f' "$agents")"
  for phrase in 'install it automatically' "Don't ask" 'just install'; do
    ! grep -qiF -- "$phrase" "$doc" || echo "old-rule: the doc still says '$phrase'"
    ! printf '%s\n' "$sec" | grep -qiF -- "$phrase" || echo "old-rule: agents/heimdall.md §2c still says '$phrase'"
  done
  # agents-2c
  if [ -z "$sec" ]; then
    echo "agents-2c: agents/heimdall.md has no ### 2c. section"
  else
    for need in 'hmd skills install' 'consent required' 'ask the user' 'references/plugin-autoinstall.md'; do
      printf '%s\n' "$sec" | grep -qF -- "$need" || echo "agents-2c: agents/heimdall.md §2c does not say '$need'"
    done
  fi
  # pointer
  grep -q 'plugin-autoinstall.md' "$agents" || echo "pointer: agents/heimdall.md no longer points at plugin-autoinstall.md"
}

describe() {  # KEY -> the claim it proves
  case "$1" in
    generated)   echo "the doc's two tables are generated blocks (auto-install, mid-task; flavour ask) and --check finds them current" ;;
    ask-flavour) echo "the install command is hmd skills install: no claude plugins install anywhere in the doc" ;;
    exit-codes)  echo "the doc has a table row for every exit code of skills_cli_install.py ($CODES)" ;;
    exit-3)      echo "the exit 3 row says consent required, then ask the user" ;;
    yes-rule)    echo "--yes only after the user agrees, never on the agent's own" ;;
    old-rule)    echo "install it automatically / Don't ask is gone from the doc and from agents/heimdall.md §2c" ;;
    agents-2c)   echo "agents/heimdall.md §2c carries the consent wording and the pointer to the doc" ;;
    pointer)     echo "agents/heimdall.md still points at plugin-autoinstall.md" ;;
  esac
}

# ── the repo's own files: every proof holds ──────────────────────────────────────────
real="$(verdict "$DOC" "$AGENTS")"
for key in generated ask-flavour exit-codes exit-3 yes-rule old-rule agents-2c pointer; do
  broken="$(printf '%s\n' "$real" | grep "^$key: " | head -3 | tr '\n' ' ')"
  if [ -z "$broken" ]; then ok "$key: $(describe "$key")"; else bad "$key: $(describe "$key") -- ${broken:0:400}"; fi
done

# ── every proof goes RED ─────────────────────────────────────────────────────────────
# mutant LABEL KEY WHICH SED-SCRIPT — a copy of the repo's files with ONE line changed (WHICH = doc | agents); the verdict must name KEY.
# A script that changes nothing is itself a failure: it would make the proof below it vacuous.
mutant() {
  local label="$1" key="$2" which="$3" script="$4" src out
  cp "$DOC" "$WORK/m-doc.md"; cp "$AGENTS" "$WORK/m-agents.md"
  if [ "$which" = doc ]; then src="$DOC"; else src="$AGENTS"; fi
  sed "$script" "$src" >"$WORK/m-$which.md"
  if cmp -s "$src" "$WORK/m-$which.md"; then bad "RED: $label (the edit changed nothing)"; return; fi
  out="$(verdict "$WORK/m-doc.md" "$WORK/m-agents.md")"
  if [[ "$out" == *"$key: "* ]]; then ok "RED: $label -> $key fires"; else bad "RED: $label should fire $key (verdict: ${out:0:300})"; fi
}

mutant "a generated cell edited (the seo command)"       generated   doc    's/hmd skills install seo`/hmd skills install seo-pro`/'
mutant "the mid-task block loses its BEGIN marker"       generated   doc    '/part=mid-task/d'
mutant "the auto-install block is set to flavour auto"   generated   doc    's/part=auto-install flavour=ask/part=auto-install flavour=auto/'
mutant "a prose line tells the agent the raw command"    ask-flavour doc    's/hmd skills install <plugin>/claude plugins install <plugin>@claude-plugins-official/'
mutant "the exit 4 row is deleted"                       exit-codes  doc    '/^| 4 |/d'
mutant "exit 3 says retry instead of ask the user"       exit-3      doc    '/^| 3 |/s/ask the user/retry it/'
mutant "--yes is no longer tied to the user agreeing"    yes-rule    doc    's/Only after the user agrees/Whenever you like/'
mutant "the doc says always pass --yes"                  yes-rule    doc    's/Never pass `--yes`/Always pass `--yes`/'
mutant "the doc says install it automatically again"     old-rule    doc    '1s/$/ install it automatically/'
mutant "agents §2c says install it automatically again"  old-rule    agents 's/covered by any installed skill,/covered by any installed skill, install it automatically,/'
mutant "agents §2c loses hmd skills install"             agents-2c   agents '/^### 2c\./,/^### 2d\./s/hmd skills install/the installer/g'
mutant "agents/heimdall.md points at another file"       pointer     agents 's#plugin-autoinstall\.md#plugin-install.md#g'

echo "--------------------------------------------------------------------"
printf 'skills-autoinstall-doc: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
