#!/usr/bin/env python3
"""skills_cli_install.py -- `hmd skills suggest | install | consent | allow`: the consented way to add a skill or plugin.

    skills_cli_install.py suggest [--reset]
    skills_cli_install.py install ID | --recommended [--yes]
    skills_cli_install.py consent [ask|allowlist|auto]
    skills_cli_install.py allow ID

3.x M1, task T4.2 of docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md ("CLI surface", "Consent model"). The read-only
commands (list, why, lock) are skills_cli_read.py; bin/heimdall-skills dispatches `hmd skills ...` to both.

  suggest   prints what this project could use and never installs: the `recommended` entries that are not installed, plus the
            `detected` ones whose files are in the working directory (the manifest's detection rules and file triggers).
            Not listed: what is installed (a lock row installed or adopted, a plugin known to ~/.claude/settings.json, a
            directory in ~/.claude/skills), what was declined, install:false entries, and the bundled, on_demand and community
            tiers (INV-S9) -- except on a LEAN install (bin/lib/hmd_profile.py get): there the bundled entries it leaves out
            (on_demand_paths or a pack: stacks, designmatch, mac-deep-clean, system-health, self-improve), until `install` puts
            them back, are a block of their own after the project's, each `[on demand]`, so the first line (the count the session
            nudge reads) stays the project's. It makes no `claude` or `git` call and writes nothing; --reset first moves every
            declined row of the project and machine locks back to suggested.
  install   the single consented install path. Per id: refuse what hmd does not install (install:false, a bundled entry that names no
            path, unknown), skip what is installed, ask the consent gate, run the receipted install, record the lock row.
              consent   hmd_skills_consent ID hmd-skills-install (bin/lib/skills_consent.sh) decides: this module never
                        decides consent itself. --yes is "the person already said yes" (HMD_SKILLS_YES=1 for the gate). An entry
                        whose manifest says explicit_consent is asked EVERY time (the gate runs with HMD_SKILLS_CONSENT=ask, so
                        neither auto nor an allowlist approves it).
              install   hmd_install_known_plugin / hmd_skill_install (bin/lib/install-receipt.sh): the receipt line is theirs, and
                        only a marketplace on their allow-list is ever passed to `claude`, whatever the manifest says.
              lock      the PROJECT lock (<working directory>/.planning/skills.lock), the file the gate writes its suggested and
                        declined rows to for this via, so a row moves suggested -> installed in one place: state installed (or
                        failed), the consent basis the gate returned, the version, source and pin the receipt line holds, and
                        why.rule `explicit` unless a trigger already gave one (the caller's HMD_INSTALL_WHY_RULE and
                        HMD_INSTALL_WHY_EVIDENCE win). The lock is bookkeeping: a row that cannot be written is said on stderr and
                        the install result stands.
            --recommended does that for every recommended entry that is not installed, one gate question each.
            A BUNDLED entry that a lean tree leaves out (lean core, task T3.2 of docs/superpowers/plans/2026-11-12-3x-lean-core.md: the
            manifest gives it on_demand_paths and/or a pack, rules SM12 and SM13) is PUT BACK, not installed. After the same consent gate
              put back  `bin/lib/lean_sparse.sh add PATH` for each of its paths (on_demand_paths, then pack.paths), from the objects the
                        clone already holds, so it needs no network (INV-L4). Nothing is fetched or run: there is no receipt line. A path
                        put back before a later one fails stays; on a full tree the script says there is nothing to do. It is listed from
                        the next session, like any plugin.
              lock      ONE row in the MACHINE lock (the clone is the machine's, and bin/lib/skills_packs.py reads no other lock): state
                        installed (or failed), kind bundled, the entry's ref, source bundled, the consent basis, why.rule explicit, and for
                        a pack its version and its full sha256 as content_hash: the pin an installed pack must match to be read instead of
                        the bundled copy (INV-L5; that copy is never removed).
  consent   prints, or with a mode sets, `consent` in $HEIMDALL_HOME/skills-config.json. The operator's HMD_SKILLS_CONSENT beats
            the file; setting a mode it overrides says so on stderr.
  allow     adds a manifest id to the allowlist of that file (it is used in allowlist mode).

The gate's own seams reach it through the environment: HMD_SKILLS_ASSUME=tty|notty, HMD_SKILLS_YES, HEIMDALL_HOME.

EXIT. 0 done (installed, already installed, nothing to suggest); 1 an install failed, a write failed or the manifest cannot be used;
2 usage, an unknown id, or an entry hmd does not install; 3 consent required (the gate deferred: nothing was installed; whoever ran
this relays the question to the person and runs it again with --yes); 4 declined (Never ask again). --recommended answers with the
worst of its entries: 1, else 3, else 4, else 0. Never a traceback. stdlib only; run as `python3 -I`.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True  # importing the sibling modules must not leave a .pyc in the plugin directory
LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, LIB_DIR)  # python3 -I keeps the script's directory off sys.path
import hmd_profile  # noqa: E402
import skills_config  # noqa: E402
import skills_lock  # noqa: E402
import skills_resolver  # noqa: E402

MANIFEST = os.path.normpath(os.path.join(LIB_DIR, "..", "..", "skills.manifest.json"))
CONSENT_SH = os.path.join(LIB_DIR, "skills_consent.sh")
RECEIPT_SH = os.path.join(LIB_DIR, "install-receipt.sh")
LEAN_SPARSE_SH = os.path.join(LIB_DIR, "lean_sparse.sh")
VIA = "hmd-skills-install"
SCOPE = "project"
MACHINE = "machine"
MODES = ("ask", "allowlist", "auto")
GATE_DEFER, GATE_DECLINED = 10, 11
EXIT = {"installed": 0, "already": 0, "failed": 1, "refused": 2, "deferred": 3, "declined": 4}

# The consent gate runs in a bash that keeps this process's terminal (the menu draws there) and hands its answer back through a file.
CONSENT_SCRIPT = r'''. "$1" || exit 99
rc=0
hmd_skills_consent "$2" "$3" || rc=$?
printf '%s %s\n' "$rc" "${HMD_SKILLS_CONSENT_BASIS:-n/a}" > "$4"
'''
INSTALL_SCRIPT = r'''. "$1" || exit 99
case "$2" in
  plugin) hmd_install_known_plugin "$3" "$4" "$5" ;;
  skill) mkdir -p "$4" && hmd_skill_install "$3" "$6" "$4/$3" "$5" ;;
  *) exit 98 ;;
esac
'''
RECEIPT_SCRIPT = '. "$1" && hmd_install_receipt_file'
SPARSE_SCRIPT = 'exec bash "$1" add "$2"'
_reported = set()


def warn(message):
    sys.stderr.write("hmd skills: %s\n" % message)


def plain(text):
    """Untrusted text (an id typed on the command line) as one short printable line."""
    return re.sub(r"[^ -~]", "?", text)[:64]


def run_bash(script, args, env, capture=False):
    sys.stdout.flush()
    sys.stderr.flush()
    return subprocess.run([shutil.which("bash") or "/bin/bash", "-c", script, "hmd-skills"] + args, env=env, check=False,
                          stdout=subprocess.PIPE if capture else None)


# ---- what the manifest and the machine say ----------------------------------------------------------------------------

def sparse_paths(entry):
    """The tree paths that put a bundled entry back into a lean clone: its on_demand_paths, then its pack's paths (the manifest has checked
    that each is one literal path: SM12, SM13). Empty for every entry a lean tree does not leave out."""
    paths = list(entry.get("on_demand_paths", [])) + list(entry.get("pack", {}).get("paths", []))
    return list(dict.fromkeys(paths))


def installable(entry):
    """What `install` can do for the entry: a receipted plugin or skill install, or the put-back of a bundled skill a lean tree leaves out."""
    return (entry["install"] is True and entry["kind"] in ("plugin", "github-skill")) or bool(sparse_paths(entry))


def ref_of(entry):
    if entry["kind"] == "plugin":
        return entry["ref"]
    if entry["kind"] == "bundled":
        return entry.get("ref") or entry["id"]  # the in-tree path, as skills_cli_read.entry_ref gives it
    return entry["repo"]


def source_of(doc, entry):
    if entry["kind"] == "plugin":
        return doc["marketplaces"].get(entry["marketplace"], {}).get("source", "unknown")
    if entry["kind"] == "bundled":
        return "bundled"  # as skills_cli_read.declared gives it
    return "github.com/" + entry["repo"]


def lock_rows(scope):
    """The rows of one lock. A lock that cannot be read is said once and read as empty: this tool suggests and records, so a damaged
    file is the lock tool's to report (and to refuse to overwrite), never a reason to stop."""
    try:
        return skills_lock.load(skills_lock.lock_path(scope))["entries"]
    except skills_lock.LockError as exc:
        if str(exc) not in _reported:
            _reported.add(str(exc))
            warn(str(exc))
        return []


def present_ids(doc):
    """The ids already on this machine: a lock row installed or adopted (either scope), a plugin ~/.claude/settings.json knows
    (enabled or paused), a directory in ~/.claude/skills. No `claude` call."""
    found = {row["id"] for scope in ("project", "machine") for row in lock_rows(scope) if row["state"] in skills_lock.PRESENT}
    try:
        enabled = skills_resolver.read_enabled(os.path.expanduser("~/.claude/settings.json"))
    except skills_resolver.ResolverError as exc:
        warn(str(exc))
        enabled = {}
    skills_dir = os.path.expanduser("~/.claude/skills")
    for entry in doc["entries"]:
        if entry["kind"] == "plugin" and entry["ref"] in enabled:
            found.add(entry["id"])
        elif entry["kind"] == "github-skill" and os.path.isdir(os.path.join(skills_dir, entry["id"])):
            found.add(entry["id"])
    return found


def declined_ids():
    return {row["id"] for scope in ("project", "machine") for row in lock_rows(scope) if row["state"] == "declined"}


def fired(doc, entry, project):
    """What in `project` makes a detected entry relevant: a detection rule whose files are here, or one of the entry's own file
    triggers. The name of the rule or the path, else None."""
    for name, rule in doc.get("detection_rules", {}).items():
        if entry["id"] in rule["entries"] and any(skills_resolver.project_matches(project, pattern) for pattern in rule["files"]):
            return name
    for rule in entry.get("triggers", {}).get("files", []):
        if skills_resolver.file_trigger(project, rule):
            return rule["path"]
    return None


# ---- the lock ---------------------------------------------------------------------------------------------------------

def record(argv, scope=SCOPE):
    """`skills_lock.py record --scope SCOPE ...` in this process -> its exit status (it says what went wrong on stderr itself)."""
    try:
        return skills_lock.main(["record", "--scope", scope] + argv)
    except SystemExit as exc:  # argparse rejected a value
        return exc.code if isinstance(exc.code, int) else 2


def write_row(doc, entry, state, basis, receipt):
    """The lock row of an install this command attempted: installed or failed, with the consent the gate gave. A put-back is a MACHINE row
    (the clone it restores is the machine's, and skills_packs.py reads no other lock); every other install is a project row."""
    ident = entry["id"]
    receipt = receipt or {}
    pack = entry.get("pack")
    scope = MACHINE if sparse_paths(entry) else SCOPE
    argv = ["--id=" + ident, "--state=" + state, "--kind=" + entry["kind"], "--ref=" + ref_of(entry), "--consent=" + basis,
            "--via=" + VIA, "--source=" + (receipt.get("source") or source_of(doc, entry))]
    if state == "installed":
        version = receipt.get("version") or (pack or {}).get("version") or "unknown"
        argv += ["--version=" + version, "--pin=" + (receipt.get("pin") or "none")]
        if entry["kind"] == "github-skill" and skills_lock.HASH_RE.fullmatch(version):
            argv.append("--content-hash=" + version)  # the commit that was cloned
        if pack:
            argv.append("--content-hash=" + pack["sha256"])  # the build a pack under $HEIMDALL_HOME/packs must be to be read instead of the bundled copy
    rule = os.environ.get("HMD_INSTALL_WHY_RULE") or ("" if any(row["id"] == ident for row in lock_rows(scope)) else "explicit")
    if rule:  # a row that exists keeps the rule (and evidence) of the trigger that suggested it
        argv.append("--rule=" + rule)
    if os.environ.get("HMD_INSTALL_WHY_EVIDENCE"):
        argv.append("--evidence=" + os.environ["HMD_INSTALL_WHY_EVIDENCE"])
    if record(argv, scope) != 0:
        warn("the lock row for %s (%s) could not be written; the install result stands" % (ident, state))


def receipt_line(path, offset, kind, name):
    """The ok record the install just appended to the run's receipt for (kind, name), or None."""
    try:
        with open(path, "rb") as handle:
            handle.seek(offset)
            lines = handle.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        try:
            found = json.loads(line)
        except ValueError:
            continue
        if isinstance(found, dict) and found.get("kind") == kind and found.get("name") == name and found.get("result") == "ok":
            return found
    return None


# ---- install ----------------------------------------------------------------------------------------------------------

def ask_consent(entry, yes):
    """The gate's answer for `entry` -> (outcome, basis): proceed, deferred, declined or error."""
    env = dict(os.environ)
    env["HMD_INSTALL_WHY_RULE"] = env.get("HMD_INSTALL_WHY_RULE") or "explicit"  # the row a deferral leaves says it was asked by name
    if yes:
        env["HMD_SKILLS_YES"] = "1"
    if entry.get("explicit_consent") is True:
        env["HMD_SKILLS_CONSENT"] = "ask"
    handle, path = tempfile.mkstemp(prefix="hmd-skills-consent-")
    os.close(handle)
    try:
        run_bash(CONSENT_SCRIPT, [CONSENT_SH, entry["id"], VIA, path], env)
        with open(path, encoding="utf-8") as answer:
            words = answer.read().split()
    finally:
        os.unlink(path)
    if len(words) != 2 or not words[0].isdigit():
        return "error", "n/a"
    status, basis = int(words[0]), words[1]
    if status == 0:
        return "proceed", basis if basis in skills_lock.CONSENTS else "n/a"
    return {GATE_DEFER: "deferred", GATE_DECLINED: "declined"}.get(status, "error"), "n/a"


def sparse_add(entry, env):
    """`lean_sparse.sh add PATH` for each path of a bundled entry -> 0, or the first status that is not 0 (the script says why on stderr).
    It reads objects the clone already holds, so no network is involved (INV-L4); a path put back stays when a later one fails."""
    if not os.path.isfile(LEAN_SPARSE_SH):
        warn("%s is missing, so nothing can be put back" % LEAN_SPARSE_SH)
        return 1
    for path in sparse_paths(entry):
        status = run_bash(SPARSE_SCRIPT, [LEAN_SPARSE_SH, path], env).returncode
        if status:
            return status
    return 0


def run_install(entry, env):
    """The install of one entry -> (exit status, the receipt record it wrote or None). A bundled entry is put back with no receipt line:
    nothing is fetched or run, and its lock row is the record."""
    if sparse_paths(entry):
        return sparse_add(entry, env), None
    found = run_bash(RECEIPT_SCRIPT, [RECEIPT_SH], env, capture=True)
    path = found.stdout.decode("utf-8", "replace").strip() if found.returncode == 0 else ""
    offset = os.path.getsize(path) if path and os.path.exists(path) else 0
    if entry["kind"] == "plugin":
        done = run_bash(INSTALL_SCRIPT, [RECEIPT_SH, "plugin", entry["ref"].split("@")[0], entry["marketplace"], VIA], env)
        kind, name = "plugin", entry["ref"]
    else:
        done = run_bash(INSTALL_SCRIPT, [RECEIPT_SH, "skill", entry["id"], os.path.expanduser("~/.claude/skills"), VIA, entry["repo"]], env)
        kind, name = "skill", entry["id"]
    return done.returncode, (receipt_line(path, offset, kind, name) if done.returncode == 0 and path else None)


def install_one(doc, entry, yes, present):
    """One entry through the whole path -> installed, already, refused, deferred, declined or failed."""
    ident = entry["id"]
    if entry["kind"] == "bundled" and not sparse_paths(entry):
        warn("%s ships with hmd: nothing to install" % ident)
        return "refused"
    if not installable(entry):
        warn("hmd does not install %s: %s" % (ident, entry["why"]))
        return "refused"
    if ident in present:
        print("%s is already installed" % ident)
        return "already"
    outcome, basis = ask_consent(entry, yes)
    if outcome == "error":
        warn("the consent gate (%s) gave no answer: nothing was installed" % CONSENT_SH)
        return "failed"
    if outcome != "proceed":
        return outcome
    status, receipt = run_install(entry, dict(os.environ))
    if status != 0:
        write_row(doc, entry, "failed", basis, None)
        warn("install failed for %s (%s)" % (ident, "the lines above say why" if sparse_paths(entry) else "the line above says why; the receipt has it too"))
        return "failed"
    write_row(doc, entry, "installed", basis, receipt)
    present.add(ident)
    print("installed %s (%s, consent %s)" % (ident, ref_of(entry), basis))
    if sparse_paths(entry):
        print("%s is back on disk; it is listed from the next session" % " ".join(sparse_paths(entry)))
    return "installed"


def cmd_install(args):
    doc = skills_resolver.load_manifest(MANIFEST)
    if args.recommended:
        wanted = [entry for entry in doc["entries"] if entry["tier"] == "recommended" and installable(entry)]
    else:
        wanted = [entry for entry in doc["entries"] if entry["id"] == args.id]
        if not wanted:
            warn("unknown skill id %s (hmd skills suggest lists what is available)" % plain(args.id))
            return EXIT["refused"]
    present = present_ids(doc)
    outcomes = [install_one(doc, entry, args.yes, present) for entry in wanted]
    if not args.recommended:
        if outcomes[0] == "deferred":
            warn("consent required to install %s: ask the person, then run: hmd skills install %s --yes" % (args.id, args.id))
        elif outcomes[0] == "declined":
            warn("%s was declined (never ask again): hmd skills suggest --reset asks again" % args.id)
        return EXIT[outcomes[0]]
    count = {name: outcomes.count(name) for name in EXIT}
    print("%d installed, %d already installed, %d need consent, %d declined, %d failed"
          % (count["installed"], count["already"], count["deferred"], count["declined"], count["failed"]))
    if count["deferred"]:
        warn("consent required to install %d recommended skill(s): ask the person, then run: hmd skills install --recommended --yes"
             % count["deferred"])
    for name in ("failed", "deferred", "declined"):
        if count[name]:
            return EXIT[name]
    return 0


# ---- suggest ----------------------------------------------------------------------------------------------------------

def reset_declined():
    """Every declined row of either lock goes back to suggested -> how many."""
    moved = 0
    for scope in ("project", "machine"):
        for row in lock_rows(scope):
            if row["state"] == "declined" and record(["--id=" + row["id"], "--state=suggested"], scope) == 0:
                moved += 1
    return moved


def lean_install():
    """True when this machine runs the lean profile (bin/lib/hmd_profile.py get: no file, or one it cannot use, reads as full)."""
    return hmd_profile.resolve() == "lean"


def left_out(doc, present):
    """The bundled entries a lean install leaves out and this machine does not have back: those `install` puts back (on_demand_paths or a pack) whose id is not in
    `present`. Empty on a full install, where nothing was left out."""
    if not lean_install():
        return []
    return [entry for entry in doc["entries"] if entry["kind"] == "bundled" and sparse_paths(entry) and entry["id"] not in present]


def shown_why(entry):
    """The manifest's why as one clause for a person: cut where it turns to "ships in-tree, never installed" (true of the entry, wrong as an offer), and without
    the name of the coding agent underneath, which user-facing text never says."""
    return re.sub(r"\bClaude(?: Code)?\b\s*", "", entry["why"].split("; ")[0]).strip()


def cmd_suggest(args):
    doc = skills_resolver.load_manifest(MANIFEST)
    if args.reset:
        print("reset %d declined skill(s): they are suggested again" % reset_declined())
    present, declined, project = present_ids(doc), declined_ids(), os.getcwd()
    shown, held_back = [], 0
    for entry in doc["entries"]:
        if not installable(entry) or entry["id"] in present:
            continue
        if entry["tier"] == "recommended":
            label = "recommended"
        elif entry["tier"] == "detected":
            reason = fired(doc, entry, project)
            if reason is None:
                continue
            label = "detected: " + reason
        else:  # on_demand is for an explicit request, community is never suggested (INV-S9)
            continue
        if entry["id"] in declined:
            held_back += 1
        else:
            shown.append((entry, label))
    put_back = [entry for entry in left_out(doc, present) if entry["id"] not in declined]
    held_back += len(left_out(doc, present)) - len(put_back)
    if shown:
        print("%d skill(s) suggested for this project (this command installs nothing):" % len(shown))
        for entry, label in shown:
            print("  %s  [%s]  %s" % (entry["id"], label, entry["why"]))
        print("install one: hmd skills install ID    the recommended set: hmd skills install --recommended")
    else:
        print("no skills to suggest: what is recommended here is installed or declined")
    if put_back:
        print("%d bundled skill(s) this lean install leaves out (hmd skills install ID puts one back from this copy; nothing is downloaded):" % len(put_back))
        for entry in put_back:
            print("  %s  [on demand]  %s" % (entry["id"], shown_why(entry)))
    if held_back:
        print("%d declined (hmd skills suggest --reset asks again)" % held_back)
    return 0


# ---- consent and allow ------------------------------------------------------------------------------------------------

def cmd_consent(args):
    if args.mode is None:
        print("consent: %s" % skills_config.resolve("consent"))
        allowed = skills_config.resolve("allowlist")
        if allowed:
            print("allowlist: %s" % " ".join(allowed))
        return 0
    status = skills_config.cmd_set("consent", args.mode)
    if status != 0:
        return status
    override = os.environ.get("HMD_SKILLS_CONSENT", "").strip().lower()
    if override and override != args.mode:
        warn("HMD_SKILLS_CONSENT=%s in the environment still decides; the file now says %s" % (plain(override), args.mode))
    print("consent: %s" % args.mode)
    return 0


def cmd_allow(args):
    doc = skills_resolver.load_manifest(MANIFEST)
    if not any(entry["id"] == args.id for entry in doc["entries"]):
        warn("unknown skill id %s (hmd skills suggest lists what is available)" % plain(args.id))
        return EXIT["refused"]
    allowed = skills_config.resolve("allowlist")
    if args.id in allowed:
        print("already allowed: %s" % args.id)
    else:
        status = skills_config.cmd_set("allowlist", " ".join(allowed + [args.id]))
        if status != 0:
            return status
        print("allowed: %s" % args.id)
    mode = skills_config.resolve("consent")
    if mode != "allowlist":
        warn("note: the allowlist applies in allowlist mode only (consent is %s): hmd skills consent allowlist" % mode)
    return 0


# ---- the command line -------------------------------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(prog="skills_cli_install.py", allow_abbrev=False,
                                     description="Suggest, install and consent: the consented way to add a skill or plugin.")
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    suggest = commands.add_parser("suggest", allow_abbrev=False, help="print what this project could use; installs nothing")
    suggest.add_argument("--reset", action="store_true", help="ask again about the skills that were declined")
    install = commands.add_parser("install", allow_abbrev=False, help="install one skill, or the recommended set, with consent")
    install.add_argument("id", nargs="?", metavar="ID")
    install.add_argument("--recommended", action="store_true", help="every recommended entry that is not installed")
    install.add_argument("--yes", action="store_true", help="the person already said yes")
    consent = commands.add_parser("consent", allow_abbrev=False, help="show or set the consent mode")
    consent.add_argument("mode", nargs="?", choices=MODES)
    allow = commands.add_parser("allow", allow_abbrev=False, help="add a skill id to the allowlist")
    allow.add_argument("id", metavar="ID")
    return parser


HANDLERS = {"suggest": cmd_suggest, "install": cmd_install, "consent": cmd_consent, "allow": cmd_allow}


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)  # a usage error exits 2 on its own
    if args.command == "install" and bool(args.id) == args.recommended:
        parser.error("install takes one skill id or --recommended, not both and not neither")
    try:
        return HANDLERS[args.command](args)
    except skills_resolver.ResolverError as exc:
        warn(str(exc))
        return 1
    except Exception as exc:  # reported with a non-zero status, never a traceback: the callers read the exit code
        warn("%s failed: %s: %s" % (args.command, type(exc).__name__, exc))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
