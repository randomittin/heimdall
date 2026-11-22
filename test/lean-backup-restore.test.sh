#!/usr/bin/env bash
#
# lean-backup-restore.test.sh — the backup `install.sh --reset` takes first and the restore that puts it back (lean-core plan T2.5,
# docs/superpowers/plans/2026-11-12-3x-lean-core.md; invariants INV-L9 and INV-L10: .planning/lean-core/INVARIANTS.md).
#
# bin/lib/lean_backup.py `backup` copies what a reset changes into $HEIMDALL_HOME/backups/<UTC-ts>/ (mode 0700) with a sha256 manifest, and
# `restore DIR` verifies every hash and then puts it all back. It covers skills-config.json, profile.json, the modules state files and the
# hmd-managed slice of the user-level Claude settings.json (the `agent` key, the env keys hmd routes with, the hook entries that run hmd).
# The contract proven here:
#   A. round trip (the plan's case 1): backup, mutate every tracked thing (change, delete, add), restore => every tracked file is byte-equal
#      to what it was, settings.json included; a second restore rewrites nothing;
#   B. settings.json is restored by slice: a key the backup does not manage, added or changed since, survives the restore;
#   C. tamper (the plan's case 2): a backup file changed, resized, deleted or swapped for a link, a manifest that names a file outside the
#      catalog, a modules root pointed into user data, a live settings.json that cannot be parsed: restore refuses (exit 1) and writes NOTHING;
#   D. absent (the plan's case 3): a file missing at backup time is recorded absent and removed on restore; a settings.json that did not exist
#      loses only the managed keys, and a container the restore empties goes with them;
#   E. INV-L10: ledger, receipts, memory, team, pairing and data/ are never copied (no byte of them, nor of settings.json's unmanaged content,
#      is in the backup), never touched by backup or restore (hash before == after), and a modules root pointed inside them is refused;
#   F. the backup dir is mode 0700 and its files 0600, a second backup gets its own dir, a failed backup leaves no debris, and a settings.json
#      that cannot be parsed fails the backup (a backup that silently skips what it promised is not one);
#   G. python3 -I (a planted json.py in the cwd is not imported); usage errors exit 2 and name the usage.
#
# Hermetic: HOME, HEIMDALL_HOME, CLAUDE_CONFIG_DIR and HMD_MODULES_STATE are throwaway dirs and the environment is cleared (env -i): the real
# ~/.heimdall, ~/.claude and keychain are never reached, and there is no network. bash 3.2 compatible.
#
# Usage: test/lean-backup-restore.test.sh      Exit 0 = every proof holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib/lean_backup.py"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# The real interpreter, not a version-manager wrapper: the sandbox below replaces HOME and clears the environment.
PY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -x "${PY:-}" ] || { echo "FATAL: python3 not found"; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }

WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
ROOT=""; HOME_DIR=""; HH=""; CC=""; MS=""; CALL_CWD=""; BK=""; OUT=""; ERR=""; RC=0

# fresh NAME: a new sandbox. HH is ~/.heimdall (the install dir and HEIMDALL_HOME), MS its .heimdall/modules, CC the Claude config dir.
fresh() {
  ROOT="$WORK/$1"; HOME_DIR="$ROOT/home"; HH="$HOME_DIR/.heimdall"; CC="$HOME_DIR/.claude"; MS="$HH/.heimdall/modules"
  rm -rf "$ROOT"; mkdir -p "$HH" "$CC"
}

# lb [VAR=value ...] -- ARGS...   run `python3 -I lean_backup.py ARGS` in the sandbox; sets OUT ERR RC.
lb() {
  local assign_args=(HOME="$HOME_DIR" PATH="$PATH" HEIMDALL_HOME="$HH" CLAUDE_CONFIG_DIR="$CC" HMD_MODULES_STATE="$MS")
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do assign_args+=("$1"); shift; done
  shift
  OUT="$(cd "${CALL_CWD:-$WORK}" && env -i "${assign_args[@]}" "$PY" -I "$LIB" "$@" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
}

eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
same()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/        /'; fi; }
w()     { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }     # w FILE CONTENT
fmode() { "$PY" -I -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"; }
fsha()  { "$PY" -I -c 'import hashlib, os, sys
p = sys.argv[1]
print(hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) else "-")' "$1"; }
# tree PATH...: one digest of every regular file under (or at) the paths, names included
tree() {
  "$PY" -I -c 'import hashlib, os, sys
h = hashlib.sha256()
def feed(p):
    h.update(p.encode() + b"\0" + hashlib.sha256(open(p, "rb").read()).digest())
for root in sys.argv[1:]:
    if os.path.isfile(root):
        feed(root)
    for d, _, fs in sorted(os.walk(root)):
        for f in sorted(fs):
            feed(os.path.join(d, f))
print(h.hexdigest())' "$@"
}

# every file the backup tracks, one line each: its sha256, or - when it is not there
state_digest() {
  local f
  for f in "$HH/skills-config.json" "$HH/profile.json" "$CC/settings.json" \
           "$MS/headroom/receipt.json" "$MS/headroom/wired.json" "$MS/headroom/invariants.json" \
           "$MS/.modstate/headroom/optout.json" "$MS/.modstate/headroom/failure.json" "$MS/.modstate/headroom/deferred.json" \
           "$MS/omniroute/receipt.json" "$MS/omniroute/wired.json" "$MS/.modstate/omniroute/deferred.json" \
           "$MS/zeta/receipt.json" "$MS/.modstate/zeta/optout.json"; do
    printf '%s %s\n' "$(fsha "$f")" "${f#"$ROOT"/}"
  done
}

# blob_of ID / state_of ID: the backup file of an entry of the manifest in $BK (empty when it is recorded absent) / its state
blob_of() { "$PY" -I -c 'import json, os, sys
m = json.load(open(os.path.join(sys.argv[1], "manifest.json")))
e = [e for e in m["entries"] if e["id"] == sys.argv[2]][0]
print(os.path.join(sys.argv[1], e["blob"]) if e["state"] == "present" else "")' "$BK" "$1"; }
state_of() { "$PY" -I -c 'import json, os, sys
m = json.load(open(os.path.join(sys.argv[1], "manifest.json")))
print([e for e in m["entries"] if e["id"] == sys.argv[2]][0]["state"])' "$BK" "$1"; }

# every present entry's sha256 and size match its file, one file per present entry, nothing else in files/, an absent entry has no file
manifest_ok() {
  "$PY" -I -c 'import hashlib, json, os, sys
d = sys.argv[1]
m = json.load(open(os.path.join(d, "manifest.json")))
assert m["schema"] == 1 and isinstance(m["entries"], list) and m["entries"]
ids = [e["id"] for e in m["entries"]]
assert len(ids) == len(set(ids)), "duplicate ids"
blobs = set()
for e in m["entries"]:
    if e["state"] == "present":
        data = open(os.path.join(d, e["blob"]), "rb").read()
        assert hashlib.sha256(data).hexdigest() == e["sha256"] and len(data) == e["size"], e["id"]
        blobs.add(e["blob"])
    else:
        assert e["state"] == "absent" and "blob" not in e, e["id"]
assert blobs == set("files/" + f for f in os.listdir(os.path.join(d, "files"))), "files/ differs from the manifest"
print("ok")' "$1" 2>&1
}

seed_plain() {
  w "$HH/skills-config.json" '{"consent": "auto", "grandfathered": true}'
  w "$HH/profile.json" '{"profile": "full"}'
  w "$MS/headroom/receipt.json" '{"module": "headroom", "version": "0.35.0"}'
  w "$MS/headroom/wired.json" '{"wired": true}'
  w "$MS/.modstate/headroom/failure.json" '{"at": "2026-11-01T00:00:00Z"}'
  w "$MS/omniroute/receipt.json" '{"module": "omniroute"}'
  w "$MS/zeta/receipt.json" '{"module": "zeta"}'                      # a module known only from its state dir
  w "$MS/.modstate/zeta/optout.json" '{"at": "2026-11-02T00:00:00Z"}'
}
seed_userdata() {
  w "$HH/ledger/events.ndjson" 'USERDATA-MARKER ledger'
  w "$HH/receipts/installs-run-1.ndjson" 'USERDATA-MARKER receipts'
  w "$HH/memory/notes.md" 'USERDATA-MARKER memory'
  w "$HH/team.json" 'USERDATA-MARKER team'
  w "$HH/pairing/phone.json" 'USERDATA-MARKER pairing'
  w "$HH/data/blob.bin" 'USERDATA-MARKER data'
}
udata() { tree "$HH/ledger" "$HH/receipts" "$HH/memory" "$HH/team.json" "$HH/pairing" "$HH/data"; }

# settings.json as a person's dotfile: other tools' keys and secrets around the keys hmd manages
seed_settings() {
  "$PY" -I - "$CC/settings.json" <<'PYEOF'
import json, sys
settings = {
    "theme": "dark",
    "agent": "heimdall",
    "env": {"EDITOR": "vim", "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787", "HEADROOM_PORT": "8787",
            "ANTHROPIC_AUTH_TOKEN": "sk-secret-token-do-not-copy"},
    "permissions": {"allow": ["Bash(ls)"]},
    "hooks": {
        "SessionStart": [
            {"matcher": "startup", "hooks": [{"type": "command", "command": "echo mine"}]},
            {"hooks": [{"type": "command", "command": "bash $HOME/.heimdall/bin/heimdall-presence connect"}]},
        ],
        "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}],
    },
}
open(sys.argv[1], "w").write(json.dumps(settings, indent=2) + "\n")
PYEOF
}
# every managed part of it changed, removed or added; the rest left as it is
mutate_settings() {
  "$PY" -I - "$CC/settings.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["agent"] = "heimdall-lean"
del d["env"]["ANTHROPIC_BASE_URL"]
del d["env"]["HEADROOM_PORT"]
d["env"]["HEADROOM_URL"] = "http://127.0.0.1:9"
del d["hooks"]["SessionStart"][1]
d["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "bash /x/.heimdall/bin/heimdall-added after"}]})
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PYEOF
}

# ╔═ A. round trip ═════════════════════════════════════════════════════════════════════╗
echo "A. round trip: backup, mutate everything, restore => byte-equal (the plan's case 1)"
fresh a; seed_plain; seed_settings; seed_userdata
before="$(state_digest)"; ubefore="$(udata)"
lb -- backup; BK="$OUT"
eq "A: backup exits 0" 0 "$RC"
eq "A: ... and prints exactly one line, the backup dir" 1 "$(printf '%s\n' "$OUT" | grep -c .)"
case "$BK" in "$HH"/backups/*) ok "A: ... which is a dir under HEIMDALL_HOME/backups" ;; *) bad "A: the backup dir is not under HEIMDALL_HOME/backups: [$BK]" ;; esac
same "A: backup read every source and changed none" "$before" "$(state_digest)"
eq "A: the manifest holds a sha256 and size per file and matches the files on disk" ok "$(manifest_ok "$BK")"
eq "A: INV-L9: the backup dir is mode 0700" 700 "$(fmode "$BK")"
eq "A: ... backups/ is mode 0700" 700 "$(fmode "$HH/backups")"
eq "A: ... files/ is mode 0700" 700 "$(fmode "$BK/files")"
eq "A: ... manifest.json is mode 0600" 600 "$(fmode "$BK/manifest.json")"
eq "A: ... every backed-up file is mode 0600" "600 " "$(for f in "$BK"/files/*; do fmode "$f"; done | sort -u | tr '\n' ' ')"
leaks=""
for needle in sk-secret-token-do-not-copy 'echo mine' 'echo stop' '"theme"' EDITOR permissions; do
  if grep -rqF -- "$needle" "$BK"; then leaks="$leaks [$needle]"; fi
done
eq "A: nothing of settings.json beyond the managed keys is in the backup (no token, theme, other env, other hook)" "" "$leaks"
missing=""
for needle in ANTHROPIC_BASE_URL HEADROOM_PORT heimdall-presence '"agent"' '"heimdall"'; do
  if ! grep -qF -- "$needle" "$(blob_of settings)"; then missing="$missing [$needle]"; fi
done
eq "A: ... and the managed keys are (agent, hmd env keys, the hook that runs hmd)" "" "$missing"
if grep -rq 'USERDATA-MARKER' "$BK"; then bad "A: INV-L10: a byte of ledger/receipts/memory/team/pairing/data is in the backup"; else ok "A: INV-L10: no byte of ledger, receipts, memory, team, pairing or data/ is in the backup"; fi
w "$HH/skills-config.json" '{"consent": "ask", "grandfathered": false}'
rm -f "$HH/profile.json" "$MS/headroom/wired.json" "$MS/.modstate/headroom/failure.json" "$MS/zeta/receipt.json"
printf 'garbage' >> "$MS/headroom/receipt.json"
w "$MS/.modstate/headroom/optout.json" '{"at": "now"}'
w "$MS/omniroute/wired.json" '{"wired": false}'
w "$MS/.modstate/zeta/optout.json" '{"at": "changed"}'
mutate_settings
lb -- restore "$BK"
eq "A: restore exits 0" 0 "$RC"
same "A: after mutating every tracked file, restore leaves every one byte-equal to what it was" "$before" "$(state_digest)"
eq "A: INV-L10: user data is untouched by backup and restore (hash before == after)" "$ubefore" "$(udata)"
lb -- restore "$BK"
eq "A: a second restore exits 0" 0 "$RC"
case "$OUT" in *"restored 0, removed 0,"*) ok "A: ... and rewrites and removes nothing" ;; *) bad "A: a second restore changed something: [$OUT]" ;; esac
same "A: ... the files are still byte-equal" "$before" "$(state_digest)"

# ╔═ B. settings.json by slice ═════════════════════════════════════════════════════════╗
echo "B. settings.json is restored by slice: what the backup does not manage is left alone"
fresh b; seed_settings
lb -- backup; BK="$OUT"
"$PY" -I - "$CC/settings.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["newKey"] = {"added": "after the backup"}
d["env"]["EDITOR"] = "emacs"
d["env"]["NEWVAR"] = "1"
d["agent"] = "heimdall-lean"
d["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "echo user-added-after"}]})
d["hooks"]["PreToolUse"] = [{"hooks": [{"type": "command", "command": "echo user-hook"}]}]
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PYEOF
lb -- restore "$BK"
eq "B: restore exits 0" 0 "$RC"
facts="$("$PY" -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(d["agent"], d["env"]["EDITOR"], d["env"]["NEWVAR"], d["env"]["ANTHROPIC_BASE_URL"], d["env"]["HEADROOM_PORT"],
      d["newKey"]["added"] == "after the backup", len(d["hooks"]["Stop"]), d["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
      len(d["hooks"]["SessionStart"]))' "$CC/settings.json")"
eq "B: the managed keys are back, a key and hooks the user added since, and an env value changed since, are not clobbered" \
  "heimdall emacs 1 http://127.0.0.1:8787 8787 True 2 echo user-hook 2" "$facts"

# ╔═ C. tamper ═════════════════════════════════════════════════════════════════════════╗
echo "C. tamper: restore refuses and writes nothing (the plan's case 2)"
damage_flip()     { printf 'X' | dd of="$(blob_of home/skills-config.json)" bs=1 seek=0 count=1 conv=notrunc 2>/dev/null; }
damage_settings() { printf 'X' | dd of="$(blob_of settings)" bs=1 seek=0 count=1 conv=notrunc 2>/dev/null; }
damage_append()   { printf 'x' >> "$(blob_of home/skills-config.json)"; }
damage_delete()   { rm -f "$(blob_of modules/headroom/receipt.json)"; }
damage_link()     { local b; b="$(blob_of home/profile.json)"; cp "$b" "$ROOT/copy"; rm -f "$b"; ln -s "$ROOT/copy" "$b"; }
damage_manifest() { "$PY" -I -c 'import json, os, sys
p = os.path.join(sys.argv[1], "manifest.json")
m = json.load(open(p))
m["entries"][0]["id"] = "home/../escaped.json"
json.dump(m, open(p, "w"))' "$BK"; }
tamper_case() {  # LABEL NEEDLE DAMAGE_FUNCTION: damage the backup, change live files so a write would show, restore must refuse
  local live
  fresh c; seed_plain; seed_settings; lb -- backup; BK="$OUT"
  "$3"
  w "$HH/skills-config.json" '{"changed": true}'; rm -f "$HH/profile.json"; mutate_settings
  live="$(state_digest)"
  lb -- restore "$BK"
  eq "C: $1: restore exits 1" 1 "$RC"
  case "$ERR" in
    *Traceback*) bad "C: $1: a traceback: $ERR" ;;
    *"$2"*)      ok "C: $1: ... and says why ($2)" ;;
    *)           bad "C: $1: stderr does not name [$2]: [$ERR]" ;;
  esac
  same "C: $1: ... and writes nothing (every live file is as it was)" "$live" "$(state_digest)"
  if [ -e "$HOME_DIR/escaped.json" ]; then bad "C: $1: a file was created outside the catalog"; fi
}
tamper_case "a byte of a backed-up file changed" sha256 damage_flip
tamper_case "a byte of the settings slice changed" sha256 damage_settings
tamper_case "a backed-up file made longer" "not the file" damage_append
tamper_case "a backed-up file deleted" missing damage_delete
tamper_case "a backed-up file swapped for a link to a copy with the same bytes" "not the file" damage_link
tamper_case "a manifest entry retargeted outside the catalog" "never backs up" damage_manifest
fresh c2; seed_plain; seed_settings; seed_userdata; lb -- backup; BK="$OUT"
w "$HH/skills-config.json" '{"changed": true}'; printf '{not json' > "$CC/settings.json"
live="$(state_digest)"; lb -- restore "$BK"
eq "C: a live settings.json that cannot be parsed: restore exits 1" 1 "$RC"
case "$ERR" in *settings.json*) ok "C: ... naming settings.json" ;; *) bad "C: stderr does not name settings.json: [$ERR]" ;; esac
same "C: ... and writes nothing, not even the plain files that were fine" "$live" "$(state_digest)"
fresh c3; seed_plain; seed_settings; seed_userdata; lb -- backup; BK="$OUT"
w "$HH/skills-config.json" '{"changed": true}'; live="$(state_digest)"; ubefore="$(udata)"
lb HMD_MODULES_STATE="$HH/memory" -- restore "$BK"
eq "C: a modules root pointed into user data at restore time: exit 1" 1 "$RC"
same "C: ... and writes nothing" "$live" "$(state_digest)"
eq "C: ... user data untouched" "$ubefore" "$(udata)"

# ╔═ D. absent ═════════════════════════════════════════════════════════════════════════╗
echo "D. absent: recorded as absent, removed on restore (the plan's case 3)"
fresh d      # none of it exists: no skills-config.json, profile.json, modules state or settings.json
lb -- backup; BK="$OUT"
eq "D: backup of a machine with none of it exits 0" 0 "$RC"
eq "D: home/profile.json is recorded absent" absent "$(state_of home/profile.json)"
eq "D: modules/headroom/receipt.json is recorded absent" absent "$(state_of modules/headroom/receipt.json)"
eq "D: ... an absent entry has no backup file" "" "$(blob_of home/profile.json)"
eq "D: ... the manifest still checks out" ok "$(manifest_ok "$BK")"
seed_plain
w "$MS/.modstate/headroom/optout.json" '{"at": "the reset"}'
"$PY" -I - "$CC/settings.json" <<'PYEOF'
import json, sys
d = {"theme": "dark",
     "agent": "heimdall-lean",
     "env": {"EDITOR": "vim", "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"},
     "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo mine"}]},
                                {"hooks": [{"type": "command", "command": "bash /x/.heimdall/bin/heimdall-presence connect"}]}]}}
open(sys.argv[1], "w").write(json.dumps(d, indent=2) + "\n")
PYEOF
lb -- restore "$BK"
eq "D: restore exits 0" 0 "$RC"
gone=""
# zeta (seeded by seed_plain) is no module of the registry and had no state dir at backup time: the names come from those two, so it is not tracked
for f in "$HH/skills-config.json" "$HH/profile.json" "$MS/headroom/receipt.json" "$MS/headroom/wired.json" "$MS/.modstate/headroom/failure.json" \
         "$MS/.modstate/headroom/optout.json" "$MS/omniroute/receipt.json"; do
  if [ -e "$f" ]; then gone="$gone [${f#"$ROOT"/}]"; fi
done
eq "D: every file that was missing at backup time is removed" "" "$gone"
facts="$("$PY" -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(sorted(d), d["theme"], sorted(d["env"]), len(d["hooks"]["SessionStart"]), d["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$CC/settings.json")"
eq "D: a settings.json that did not exist loses the managed keys only: theme, EDITOR and the user's own hook stay" \
  "['env', 'hooks', 'theme'] dark ['EDITOR'] 1 echo mine" "$facts"
fresh d2
lb -- backup; BK="$OUT"
"$PY" -I - "$CC/settings.json" <<'PYEOF'
import json, sys
d = {"theme": "dark", "agent": "x", "env": {"ANTHROPIC_BASE_URL": "u"},
     "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "bash /x/.heimdall/bin/heimdall-added"}]}]}}
open(sys.argv[1], "w").write(json.dumps(d, indent=2) + "\n")
PYEOF
lb -- restore "$BK"
eq "D: a container the restore empties (env, hooks) goes with its keys; the file survives" '{
  "theme": "dark"
}' "$(cat "$CC/settings.json")"

# ╔═ E. INV-L10 ════════════════════════════════════════════════════════════════════════╗
echo "E. INV-L10: user data is never copied, touched or reachable through the modules state path"
fresh e; seed_plain; seed_settings; seed_userdata
ubefore="$(udata)"
for d in receipts ledger memory pairing data team.json; do
  lb HMD_MODULES_STATE="$HH/$d" -- backup
  case "$ERR" in
    *"user data"*) if [ "$RC" -eq 1 ]; then ok "E: a modules state root inside $d is refused (exit 1, names user data)"; else bad "E: $d: rc=$RC"; fi ;;
    *)             bad "E: $d: rc=$RC, stderr does not name user data: [$ERR]" ;;
  esac
done
eq "E: ... the refused backups left no dir and no debris" "" "$(ls -A "$HH/backups" 2>/dev/null)"
eq "E: ... and user data is untouched" "$ubefore" "$(udata)"

# ╔═ F. backups ════════════════════════════════════════════════════════════════════════╗
echo "F. backups: unique dirs, no debris, a settings.json that cannot be parsed fails the backup"
fresh f; seed_plain; seed_settings
lb -- backup; b1="$OUT"; lb -- backup; b2="$OUT"
if [ -n "$b1" ] && [ "$b1" != "$b2" ] && [ -d "$b1" ] && [ -d "$b2" ]; then ok "F: a second backup gets its own dir"; else bad "F: b1=[$b1] b2=[$b2]"; fi
eq "F: ... backups/ holds exactly those two, no .partial debris" 2 "$(ls -A "$HH/backups" | wc -l | tr -d ' ')"
for body in '{not json' '[]'; do
  printf '%s' "$body" > "$CC/settings.json"
  lb -- backup
  eq "F: a settings.json holding [$body] fails the backup (exit 1)" 1 "$RC"
  case "$ERR" in *settings.json*) ok "F: ... naming settings.json" ;; *) bad "F: stderr does not name settings.json: [$ERR]" ;; esac
done
eq "F: ... and the failed backups left no dir and no debris" 2 "$(ls -A "$HH/backups" | wc -l | tr -d ' ')"

# ╔═ G. isolation and usage ════════════════════════════════════════════════════════════╗
echo "G. python3 -I, usage"
fresh g; seed_plain; seed_settings
mkdir -p "$WORK/cwdx"; printf 'import sys\nsys.exit(97)\n' > "$WORK/cwdx/json.py"
CALL_CWD="$WORK/cwdx"; lb -- backup; CALL_CWD=""
eq "G: a json.py planted in the cwd is not imported (python3 -I): backup exits 0" 0 "$RC"
usage_case() {
  lb -- "$@"
  case "$ERR" in
    *usage:*) if [ "$RC" -eq 2 ]; then ok "G: [$*] exits 2 and prints the usage"; else bad "G: [$*] rc=$RC"; fi ;;
    *)        bad "G: [$*] rc=$RC, no usage on stderr: [$ERR]" ;;
  esac
}
usage_case
usage_case frob
usage_case restore
usage_case restore a b
usage_case backup extra
lb -- restore "$WORK/does-not-exist"
eq "G: restore of a dir that is not there exits 1" 1 "$RC"
mkdir -p "$WORK/empty-backup"; lb -- restore "$WORK/empty-backup"
eq "G: restore of a dir with no manifest exits 1" 1 "$RC"
case "$ERR" in *manifest.json*) ok "G: ... naming manifest.json" ;; *) bad "G: stderr does not name manifest.json: [$ERR]" ;; esac

echo "--------------------------------------------------------------------"
printf 'lean-backup-restore: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
