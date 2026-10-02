#!/usr/bin/env python3
"""phone_deny_risk.py -- what counts as a RISKY action for the phone-deny hook (A4 in
docs/HANDOFF-TO-HEIMDALL-product-asks.md, deny-only round), and the one-line summary the phone
shows for it.

    classify(tool_name, tool_input, root, cwd=None, scratch=None, home=None)
        -> {"why": <class>, "summary": <text>}   a risky action
        -> None                                  anything else

`why` is one of

    push          git push (any form)
    delete        recursive rm, find -delete, git reset --hard / clean -f / branch -D / stash drop,
                  shred, dd of=, mkfs, diskutil erase
    publish       npm / cargo / twine / gem / docker publish-or-push, mutating gh calls
    deploy        terraform apply, kubectl delete, helm upgrade, cloud CLIs creating or removing things
    network       a request that changes something (POST/PUT/PATCH/DELETE, uploads), a download piped
                  into a shell, ssh / scp / rsync to a remote, sockets
    privilege     sudo / doas / su
    system        launchctl / systemctl changes, crontab edits, defaults write, shutdown, networksetup
    outside-repo  a Write / Edit / MultiEdit / NotebookEdit whose real path is outside the project root
                  (scratch dirs and Claude's own ~/.claude/projects memory are not "outside")

The doc's list is "write outside repo, network, delete, push, spend"; privilege and system changes ride
along because they are the same kind of thing: hard to take back, or aimed at something that is not
this repo. Read-only network use (a plain curl GET, a download to a file) is NOT risky -- the phone is
asked about things that change the world, not about every fetch.

THE ERROR DIRECTION IS DELIBERATE. A false positive costs the operator one tool call held for the
window (10 s by default) with a phone that may or may not answer; a false negative costs nothing --
the action goes through Claude Code's normal permission flow exactly as it would without this hook.
So every ambiguity below resolves toward "not risky": an unparsable command line, a tool this gate does
not cover, a path that cannot be resolved, a command past the analysis cap.

This is not a security boundary and does not try to be one: it decides what the PHONE gets a chance to
veto, never what runs. A phone can only reduce what runs; nothing here can make an action run.

Shell analysis is lexical: the command is split into lines, each line into simple commands at the
operators ; & | || && ( ), quote-aware (shlex). Per simple command, leading VAR=value assignments and
wrapper words (env, nohup, time, nice, timeout, xargs, ...) are skipped to find the real command word;
`sh -c '...'`, `eval ...`, $( ... ) and `...` are analysed recursively (MAX_DEPTH deep). Only the first
MAX_COMMAND_CHARS of a command are looked at.

Stdlib only.
"""
import os
import re
import shlex
import tempfile

MAX_COMMAND_CHARS = 20000   # the tail of a longer command is not analysed
MAX_SUMMARY_CHARS = 8000    # what is handed on as the summary (the store cuts it to 200 for display)
MAX_DEPTH = 3
MAX_SUBSTITUTIONS = 50

_OP_CHARS = frozenset(";|&()")
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_SHORT_FLAGS_RE = re.compile(r"^-[A-Za-z]+$")
_DURATION_RE = re.compile(r"^[0-9.]+[smhd]?$")

_WRAPPERS = frozenset(("env", "command", "builtin", "exec", "nohup", "time", "nice", "ionice", "stdbuf",
                       "timeout", "xargs", "caffeinate", "setsid"))
_PRIVILEGE = frozenset(("sudo", "doas", "su", "pkexec"))
_SHELLS = frozenset(("sh", "bash", "zsh", "dash", "ksh", "fish"))
_INTERPRETERS = _SHELLS | frozenset(("python", "python3", "perl", "ruby", "node", "php"))
_DOWNLOADERS = frozenset(("curl", "wget"))

_FILE_TOOLS = {"Write": "file_path", "Edit": "file_path", "MultiEdit": "file_path",
               "NotebookEdit": "notebook_path"}

_GIT_VALUE_OPTS = frozenset(("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
                             "--config-env", "--super-prefix"))

_KUBE_VERBS = frozenset(("apply", "delete", "create", "replace", "patch", "scale", "rollout", "drain", "cordon",
                         "uncordon", "taint", "exec", "cp", "edit", "label", "annotate", "run", "expose",
                         "autoscale", "set"))

# command word -> (class, any one of these as an argument makes the call risky)
_BY_ARGUMENT = {
    "npm": ("publish", frozenset(("publish", "unpublish", "deprecate"))),
    "pnpm": ("publish", frozenset(("publish",))),
    "yarn": ("publish", frozenset(("publish",))),
    "bun": ("publish", frozenset(("publish",))),
    "poetry": ("publish", frozenset(("publish",))),
    "flit": ("publish", frozenset(("publish",))),
    "cargo": ("publish", frozenset(("publish", "yank"))),
    "twine": ("publish", frozenset(("upload",))),
    "gem": ("publish", frozenset(("push", "yank"))),
    "docker": ("publish", frozenset(("push",))),
    "podman": ("publish", frozenset(("push",))),
    "mvn": ("publish", frozenset(("deploy",))),
    "terraform": ("deploy", frozenset(("apply", "destroy", "import", "taint", "untaint"))),
    "tofu": ("deploy", frozenset(("apply", "destroy", "import", "taint", "untaint"))),
    "terragrunt": ("deploy", frozenset(("apply", "destroy", "run-all"))),
    "pulumi": ("deploy", frozenset(("up", "destroy", "import"))),
    "kubectl": ("deploy", _KUBE_VERBS),
    "oc": ("deploy", _KUBE_VERBS),
    "helm": ("deploy", frozenset(("install", "upgrade", "uninstall", "delete", "rollback", "push"))),
    "serverless": ("deploy", frozenset(("deploy", "remove"))),
    "sls": ("deploy", frozenset(("deploy", "remove"))),
    "cdk": ("deploy", frozenset(("deploy", "destroy"))),
    "sam": ("deploy", frozenset(("deploy", "delete"))),
    "wrangler": ("deploy", frozenset(("deploy", "publish", "delete", "rollback"))),
    "vercel": ("deploy", frozenset(("deploy", "remove", "rm", "promote", "rollback"))),
    "netlify": ("deploy", frozenset(("deploy",))),
    "firebase": ("deploy", frozenset(("deploy",))),
    "flyctl": ("deploy", frozenset(("deploy", "destroy", "scale", "launch"))),
    "fly": ("deploy", frozenset(("deploy", "destroy", "scale", "launch"))),
    "railway": ("deploy", frozenset(("up", "deploy", "down"))),
    "supabase": ("deploy", frozenset(("push", "deploy"))),
    "amplify": ("deploy", frozenset(("push", "publish", "delete"))),
    "launchctl": ("system", frozenset(("load", "unload", "bootstrap", "bootout", "kickstart", "remove",
                                        "enable", "disable", "submit"))),
    "systemctl": ("system", frozenset(("start", "stop", "restart", "enable", "disable", "mask", "unmask",
                                        "reload", "daemon-reload", "isolate", "kill"))),
    "defaults": ("system", frozenset(("write", "delete", "import"))),
}

# cloud CLIs whose verbs are spelled create-bucket / delete-object / terminate-instances / ...
_CLOUD_CLIS = frozenset(("aws", "gcloud", "az", "doctl", "ibmcloud", "oci", "linode-cli", "vultr-cli", "hcloud"))
_CLOUD_VERB_RE = re.compile(r"^(?:create|delete|destroy|terminate|remove|rm|rb|mb|sync|deploy|publish|push|"
                            r"release|promote|put|update|start|stop|reboot|attach|detach|modify|register|"
                            r"invoke)(?:$|[-_])|^run-")

_DELETE_ALWAYS = frozenset(("shred", "srm", "wipefs", "mke2fs"))
_DELETE_PREFIXES = ("mkfs", "newfs")
_SYSTEM_ALWAYS = frozenset(("networksetup", "scutil", "pmset", "csrutil", "spctl", "tccutil", "dscl",
                            "sysadminctl", "shutdown", "reboot", "halt", "poweroff", "nvram"))

_GH_GROUPS = frozenset(("pr", "release", "repo", "issue", "workflow", "secret", "variable", "gist", "label",
                        "run", "ruleset", "cache", "codespace", "project", "ssh-key", "gpg-key", "extension"))
_GH_MUTATING = frozenset(("create", "delete", "merge", "close", "reopen", "edit", "upload", "archive",
                          "unarchive", "rename", "run", "set", "remove", "transfer", "fork", "ready", "review",
                          "comment", "lock", "unlock", "cancel", "rerun", "disable", "enable", "sync", "deploy",
                          "add"))

_REMOTE_TOOLS = frozenset(("ssh", "sftp", "nc", "ncat", "netcat", "socat", "telnet", "ftp", "tftp"))
_FETCHERS = frozenset(("curl", "wget", "http", "https", "xh", "httpie"))
_HTTPIE = frozenset(("http", "https", "xh", "httpie"))
_MUTATING_METHODS = frozenset(("POST", "PUT", "PATCH", "DELETE"))
_CURL_BODY_LONG = ("--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode", "--form",
                   "--form-string", "--upload-file", "--json")
_WGET_BODY_LONG = ("--post-data", "--post-file", "--body-data", "--body-file")
_REMOTE_URL_PREFIXES = ("rsync://", "ssh://", "scp://", "sftp://")


# -- shell analysis ---------------------------------------------------------------------------
def _is_operator(token):
    return bool(token) and all(c in _OP_CHARS for c in token)


def _split_segments(line):
    """[(operator that preceded it, tokens)] for one physical line. A line shlex cannot parse (an
    unbalanced quote) is split on whitespace instead -- the conservative direction."""
    try:
        lex = shlex.shlex(line, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""
        tokens = list(lex)
    except ValueError:
        tokens = line.split()
    segments, current, op = [], [], ""
    for token in tokens:
        if _is_operator(token):
            if current:
                segments.append((op, current))
            current, op = [], token
        else:
            current.append(token)
    if current:
        segments.append((op, current))
    return segments


def _command_of(tokens):
    """(command word's basename, its arguments), looking past VAR=value assignments and wrappers."""
    i, n = 0, len(tokens)
    while i < n:
        token = tokens[i]
        if _ASSIGN_RE.match(token):
            i += 1
            continue
        base = os.path.basename(token)
        if base in _WRAPPERS:
            i += 1
            while i < n and (tokens[i].startswith("-") or _DURATION_RE.match(tokens[i])):
                i += 1
            continue
        return base, tokens[i + 1:]
    return None, []


def _short_flag(args, letters):
    """True when one of `args` is a cluster of single-dash flags (-rf, -fdx) containing a letter of `letters`."""
    return any(_SHORT_FLAGS_RE.match(a) and any(c in a for c in letters) for a in args)


def _substitutions(line):
    """The inner text of every $( ... ) (balanced) and `...` span of `line`, quoted or not."""
    found, i, n = [], 0, len(line)
    while i < n and len(found) < MAX_SUBSTITUTIONS:
        if line.startswith("$(", i):
            depth, j = 1, i + 2
            while j < n and depth:
                depth += (line[j] == "(") - (line[j] == ")")
                j += 1
            found.append(line[i + 2:j - 1] if depth == 0 else line[i + 2:])
            i = j
        elif line[i] == "`":
            j = line.find("`", i + 1)
            if j == -1:
                break
            found.append(line[i + 1:j])
            i = j + 1
        else:
            i += 1
    return found


def _inline_script(word, args):
    """The script text `sh -c '<script>'` / `eval <script...>` carries, or None."""
    if word == "eval":
        return " ".join(args) if args else None
    for i, arg in enumerate(args[:-1]):
        if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", arg):
            return args[i + 1]
    return None


def _git(args):
    i, n = 0, len(args)
    while i < n:
        if args[i] in _GIT_VALUE_OPTS:
            i += 2
        elif args[i].startswith("-"):
            i += 1
        else:
            break
    if i >= n:
        return None
    sub, rest = args[i], args[i + 1:]
    if sub == "push":
        return "push"
    if sub == "reset" and "--hard" in rest:
        return "delete"
    if sub == "clean" and (_short_flag(rest, "f") or "--force" in rest):
        return "delete"
    if sub == "branch" and (_short_flag(rest, "D") or ("--delete" in rest and "--force" in rest)):
        return "delete"
    if sub == "stash" and rest[:1] in (["drop"], ["clear"]):
        return "delete"
    if sub in ("filter-branch", "filter-repo"):
        return "delete"
    return None


def _find(args):
    if "-delete" in args:
        return "delete"
    for i, arg in enumerate(args[:-1]):
        if arg in ("-exec", "-execdir", "-ok", "-okdir") and os.path.basename(args[i + 1]) in ("rm", "shred", "unlink", "rmdir"):
            return "delete"
    return None


def _gh(args):
    words = [a for a in args if not a.startswith("-")]
    if not words:
        return None
    if words[0] == "api":
        method = None
        for i, arg in enumerate(args):
            if arg in ("-X", "--method") and i + 1 < len(args):
                method = args[i + 1].upper()
            elif arg.startswith("--method="):
                method = arg.split("=", 1)[1].upper()
            elif arg.startswith("-X") and len(arg) > 2:
                method = arg[2:].upper()
        if method is not None:
            return "publish" if method in _MUTATING_METHODS else None
        fields = ("-f", "-F", "--field", "--raw-field", "--input")
        return "publish" if any(a in fields or a.startswith(("--field=", "--raw-field=", "--input=")) for a in args) else None
    if len(words) >= 2 and words[0] in _GH_GROUPS and words[1] in _GH_MUTATING:
        return "publish"
    return None


def _fetch_mutates(word, args):
    """Does this curl / wget / httpie call change something on the far side?"""
    for i, arg in enumerate(args):
        if arg in ("-X", "--request"):
            if i + 1 < len(args) and args[i + 1].upper() in _MUTATING_METHODS:
                return True
            continue
        if arg.startswith("-X") and not arg.startswith("--") and len(arg) > 2:
            if arg[2:].upper() in _MUTATING_METHODS:
                return True
            continue
        if arg.startswith(("--request=", "--method=")):
            if arg.split("=", 1)[1].upper() in _MUTATING_METHODS:
                return True
            continue
        if word == "curl":
            if arg.startswith(_CURL_BODY_LONG) or _short_flag([arg], "dFT"):
                return True
        elif word == "wget":
            if arg.startswith(_WGET_BODY_LONG):
                return True
        elif word in _HTTPIE and not arg.startswith("-"):
            if arg.upper() in _MUTATING_METHODS:
                return True
            if "=" in arg and "==" not in arg and "://" not in arg:
                return True
    return False


def _looks_remote(arg):
    if arg.startswith("-"):
        return False
    if arg.startswith(_REMOTE_URL_PREFIXES):
        return True
    host, sep, _ = arg.partition(":")
    return bool(sep) and "/" not in host and "://" not in arg


def _segment_why(word, args, depth):
    if word in _PRIVILEGE:
        return "privilege"
    if word in _SHELLS or word == "eval":
        script = _inline_script(word, args) if depth < MAX_DEPTH else None
        return _bash_why(script, depth + 1) if script else None
    if word == "git":
        return _git(args)
    if word == "rm":
        return "delete" if (_short_flag(args, "rR") or "--recursive" in args) else None
    if word == "find":
        return _find(args)
    if word in _DELETE_ALWAYS or word.startswith(_DELETE_PREFIXES):
        return "delete"
    if word == "dd":
        return "delete" if any(a.startswith("of=") for a in args) else None
    if word == "diskutil":
        lowered = [a.lower() for a in args]
        return "delete" if any(a.startswith("erase") or a in ("partitiondisk", "zerodisk", "secureerase", "reformat")
                               for a in lowered) else None
    if word == "gh":
        return _gh(args)
    if word in _BY_ARGUMENT:
        why, verbs = _BY_ARGUMENT[word]
        return why if any(a in verbs for a in args) else None
    if word in _CLOUD_CLIS:
        return "deploy" if any(_CLOUD_VERB_RE.match(a) for a in args if not a.startswith("-")) else None
    if word in _REMOTE_TOOLS:
        return "network"
    if word in ("scp", "rsync"):
        return "network" if any(_looks_remote(a) for a in args) else None
    if word in _FETCHERS:
        return "network" if _fetch_mutates(word, args) else None
    if word == "crontab":
        return None if "-l" in args else "system"
    if word in _SYSTEM_ALWAYS:
        return "system"
    return None


def _line_why(line, depth):
    if not line.strip():
        return None
    prev_word = None
    for op, tokens in _split_segments(line):
        word, args = _command_of(tokens)
        if word is None:
            prev_word = None
            continue
        why = _segment_why(word, args, depth)
        if why:
            return why
        if op in ("|", "|&") and prev_word in _DOWNLOADERS and word in _INTERPRETERS:
            return "network"          # a download piped straight into an interpreter
        prev_word = word
    if depth < MAX_DEPTH:
        for inner in _substitutions(line):
            why = _bash_why(inner, depth + 1)
            if why:
                return why
    return None


def _bash_why(command, depth=0):
    for line in command.split("\n"):
        why = _line_why(line, depth)
        if why:
            return why
    return None


# -- file tools -------------------------------------------------------------------------------
def _default_scratch():
    dirs = {"/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders"}
    try:
        dirs.add(tempfile.gettempdir())
    except OSError:
        dirs.add("/tmp")
    if os.environ.get("TMPDIR"):
        dirs.add(os.environ["TMPDIR"])
    return tuple(sorted(dirs))


def _within(path, base):
    base = base.rstrip(os.sep)
    return base == "" or path == base or path.startswith(base + os.sep)


def _outside(path, root, cwd, scratch, home):
    """Is `path` (as the tool was given it) a real location outside the project root and outside every
    scratch dir and Claude's own per-project memory? A path that cannot be resolved is not outside."""
    home = home if home is not None else os.path.expanduser("~")
    scratch = _default_scratch() if scratch is None else scratch
    try:
        if path == "~" or path.startswith("~/"):
            path = os.path.join(home, path[2:])
        if not os.path.isabs(path):
            path = os.path.join(cwd or root, path)
        real = os.path.realpath(path)
        if _within(real, os.path.realpath(root)):
            return False
        exempt = [os.path.join(home, ".claude", "projects")] + list(scratch)
        return not any(_within(real, os.path.realpath(d)) for d in exempt)
    except (OSError, ValueError):
        return False


def classify(tool_name, tool_input, root, cwd=None, scratch=None, home=None):
    """{"why", "summary"} for a risky action, None for anything else. `root` is the project root,
    `cwd` the hook's working directory (relative paths resolve against it, else against `root`);
    `scratch` and `home` default to the real temp dirs and $HOME and exist so a test can pin them."""
    if not isinstance(tool_name, str) or not isinstance(tool_input, dict):
        return None
    if tool_name == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str):
            return None
        why = _bash_why(command[:MAX_COMMAND_CHARS])
        return {"why": why, "summary": command[:MAX_SUMMARY_CHARS]} if why else None
    field = _FILE_TOOLS.get(tool_name)
    if field is None:
        return None
    path = tool_input.get(field)
    if not isinstance(path, str) or not path.strip():
        return None
    if _outside(path, root, cwd, scratch, home):
        return {"why": "outside-repo", "summary": "%s %s" % (tool_name, path)}
    return None
