#!/usr/bin/env python3
r"""hmd_wait_guard -- would this Bash command WAIT in the foreground for something that should run in the background?

2026-11-10 (docs/analysis/2026-11-10-stale-general-purpose-agents.md): agents that "went stale after 1-2 h" were not hung, they sat inside their own shell. Over
every subagent transcript on the operator's machine (2102 agents) foreground poll loops took 167.8 h of general-purpose Bash time and 113.6 h of hmd:coder's:
`until grep -q DONE f; do sleep 30; done`, `for i in $(seq 1 58); do grep -q X f && break; sleep 10; done`, `perl -e 'alarm 595; sleep 595'`,
`while pgrep -f job; do sleep 5; done` -- each waiting for a job the agent had itself put in the background. A loop is cut at the 10-minute Bash cap and re-issued,
the agent's context grows with every poll result, and it ends at the turn cap or stale. Claude Code already blocks a bare foreground `sleep`; a sleep INSIDE a
loop is not blocked. bin/heimdall-precheck-bash therefore asks this file, for a command that mentions sleep, alarm or tail -f, whether the command is one of those
waits. It reads the command the way a shell does by reusing bin/lib/hmd_kill_guard.py's lexer and wrapper handling (quotes and escapes, env / nice / timeout / sudo /
xargs, ; && || | & and newlines, subshells, substitutions, if / for / while bodies, sh -c, eval, heredocs fed to a shell), as bin/lib/hmd_ci_guard.py does. The lexer
hands over simple commands flat (`until c; do b; done` is three of them), so loops are counted: until / while / for / select open one, `done` closes one, and a
command read while one is open is inside it (a substitution is lexed in place, so what it holds is read as part of the command that has it).

  denied   a loop that sleeps   until / while / for / select with a command in its condition or body that runs sleep, whatever the duration (even `sleep 0.2`: the
                                loop is the wait), also behind env / timeout / nohup / time / a path, through a substitution, in an sh -c or eval string, in a
                                shell string that a loop runs
           a process poll       a while or until loop whose CONDITION is pgrep or kill -0 (kill -s 0, kill -n 0), with a sleep or without (busy-waiting); a probe
                                in the BODY of a loop (a for over pids, a while read) is no wait
           a long sleep         a standalone sleep of 60 s or more: 60, 1m, 2h, 1e2, infinity, 30 30 (arguments add up, as in GNU sleep); a duration held in a
                                variable cannot be told and is not denied
           an interpreter wait  perl / python / ruby / awk / ... with its script on the command line or on stdin that calls sleep together with an alarm
                                (perl -e 'alarm 595; sleep 595') or sleeps for 60 s or more (time.sleep(300))
           a follow             tail -f, tail -F, --follow (or an abbreviation of it), alone or in a cluster of flags (-fn 100, -n100 -F, -20f), also after the file
  allowed  everything else: sleep under 60 s outside a loop, a loop without sleep, tail without a follow flag, perl -e 'alarm 45; exec @ARGV' (the bound the guard
           recommends), a for over pids that probes each, and text that only MENTIONS a form (echo, grep, a commit message or its heredoc, a script written to
           disk). A call with run_in_background: true is allowed whatever it runs: the hook reads that flag from the payload's tool_input and never starts this
           file for it, because the harness tells the agent when a background job ends
  unread   a command that mentions a trigger and that this cannot read: an unbalanced quote, substitution or brace, a heredoc body the shell expands, $'...', shell
           strings nested more than 8 deep, an internal error, a timeout. Exit 4: the hook warns on stderr and ALLOWS. This is a COST guard, not a security gate
           (the CI waste guard's and the disk floor's convention), so what it could not read is never a deny. A form it DID read wins over what it could not
  unseen   what no reading sees: a command name or shell string held in a variable, a wait loop inside a python or node script, a script on disk that polls, a
           wait on another machine (ssh ... 'until ...'), kubectl / docker logs -f, read -t, `watch`, a sleep spelled in pieces (sl''eep: the hook's pre-filter looks
           for the plain word). Over-held: a sleep or loop sent to the background with & (the lexer does not say which commands end in &) -- use run_in_background.
           Best effort, not a security boundary

Protocol: the command text on stdin; stdout `ok` and exit 0 = nothing found; one reason line and exit 3 = deny; one reason line and exit 4 = could not read (allow,
warn). Anything else (a crash, another status) is the hook's "the guard itself failed" warning, also an allow. HMD_WAIT_GUARD_TIMEOUT_S (default 5) bounds the run.
HMD_WAIT_ALLOW=1 is read by the hook, bin/heimdall-precheck-bash, which then never starts this file.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_kill_guard as kg  # noqa: E402  (the shell reader: lex, unwrap, plain, opaque, the run-time budget)

MAX_DEPTH = kg.MAX_DEPTH  # shell strings (sh -c, eval, heredocs) read inside shell strings
try:
    TIMEOUT_S = float(os.environ.get("HMD_WAIT_GUARD_TIMEOUT_S", "5"))
except ValueError:
    TIMEOUT_S = 5.0

LONG_S = 60  # a standalone sleep of this many seconds or more is a wait; a sleep inside a loop is one whatever its length
OPENS_LOOP = frozenset(("while", "until", "for", "select"))
DURATION = re.compile(r"^((?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|(?i:inf(?:inity)?))([smhd]?)$")
UNIT_S = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
TAIL_VALUE_LONG = frozenset(("--bytes", "--lines", "--pid", "--sleep-interval", "--max-unchanged-stats"))
TAIL_VALUE_SHORT = "ncbs"  # -n N, -c N, -b N (BSD), -s N: the rest of the cluster is the value, or the next word when nothing is left
SLEEP = re.compile(r"\bsleep\b")
ALARM = re.compile(r"\balarm\b")
SLEEP_CALL = re.compile(r"\bsleep\b[\s(]*([0-9]+(?:\.[0-9]+)?)")  # sleep 595, sleep(120), time.sleep(300)
INLINE = re.compile(r"[\s(;]")  # an argument that holds code, not a file name

# Reasons are fixed one-liners without quotes or backslashes: the hook puts them into a JSON deny.
R_LOOP = "a loop that runs sleep (until, while or for ... do sleep ...; done) waits in the foreground"
R_POLL = "a while or until loop that polls pgrep or kill -0 waits in the foreground for a process"
R_SLEEP = "sleep for 60 seconds or more waits in the foreground"
R_TAIL = "tail -f or tail -F follows a file with no end, so it waits in the foreground"
R_SCRIPT = "an interpreter script that sleeps with an alarm, or for 60 seconds or more, waits in the foreground"
U_DEEP = "shell strings nested more than %d deep, so the guard cannot read the command" % MAX_DEPTH
U_TIMEOUT = "reading the command took longer than %gs (HMD_WAIT_GUARD_TIMEOUT_S), so the guard gave up"
U_ERROR = "an internal error (%s), so the guard cannot read the command"


def sleep_seconds(args):
    """The seconds a sleep waits, its arguments added up as GNU sleep does (1m 30s is 90), or None when that cannot be told: no argument, a variable, a word that
    is no duration."""
    total = 0.0
    for w in args:
        m = None if w.dynamic else DURATION.match(w.text)
        if not m:
            return None
        total += float(m.group(1)) * UNIT_S[m.group(2)]
    return total if args else None


def follows(args):
    """Does this tail follow its file: -f, -F or --follow (or an abbreviation of it), alone or in a cluster of flags? A value (-n 5, --lines 5) and a word after
    `--` are not flags."""
    k = 0
    while k < len(args):
        w = args[k]
        k += 1
        t = w.text
        if t == "--":
            return False
        if w.dynamic:
            continue
        if t.startswith("--"):
            name, eq, _ = t.partition("=")
            if len(name) > 2 and "--follow".startswith(name):
                return True
            if name in TAIL_VALUE_LONG and not eq:
                k += 1
        elif t.startswith("-") and len(t) > 1:
            cluster = t[1:]
            for i, c in enumerate(cluster):
                if c in "fF":
                    return True
                if c in TAIL_VALUE_SHORT:
                    if i == len(cluster) - 1:
                        k += 1
                    break
    return False


def probes(base, rest):
    """Does this simple command probe a process: pgrep, or kill -0 (also kill -s 0 and kill -n 0), which sends no signal?"""
    if base == "pgrep":
        return True
    if base != "kill" or not rest or rest[0].dynamic:
        return False
    first = rest[0].text
    return first == "-0" or (first in ("-s", "-n") and len(rest) > 1 and not rest[1].dynamic and rest[1].text == "0")


def lead(words):
    """The loop keywords a simple command begins with, in order: `until c` gives (until,), `then while c` gives (while,), `done` gives (done,)."""
    found = []
    for w in kg.plain(words):
        t = w.text
        if w.dynamic:
            break
        if t in OPENS_LOOP or t == "done":
            found.append(t)
            if t not in ("while", "until"):  # for / select / done: what follows is a name or a word list, not a command
                break
        elif not (t in kg.RESERVED or t == "time" or kg.ASSIGN.match(t)):
            break
    return found


def check_script(rest, bodies):
    """An interpreter (perl, python, ruby, awk, ...) with its script on the command line or on stdin: does it sleep with an alarm, or for 60 s or more?"""
    for text in [w.text for w in rest if INLINE.search(w.text)] + bodies:
        if SLEEP.search(text) and (ALARM.search(text) or any(float(m.group(1)) >= LONG_S for m in SLEEP_CALL.finditer(text))):
            return R_SCRIPT
    return None


def check_shell(cmd, rest, depth, unread, looped):
    """sh / bash / ...: the -c string, and a heredoc or here-string fed to the shell, are commands too (as hmd_kill_guard.check_shell reads them); a shell that a
    loop runs is read as inside that loop."""
    sources, k = list(cmd.bodies), 0
    while k < len(rest) and not rest[k].dynamic:
        t = rest[k].text
        if t == "--" or not t.startswith(("-", "+")) or t in ("-", "+"):
            break
        if t in ("-o", "+o", "-O", "+O"):
            k += 2
        elif t.startswith("-") and not t.startswith("--") and "c" in t[1:]:
            if k + 1 < len(rest) and not kg.opaque(rest[k + 1]):
                sources.append(rest[k + 1].text)
            break
        else:
            k += 1
    for source in sources:
        why = analyze(source, depth + 1, unread, looped)
        if why:
            return why
    return None


def check(cmd, polling, looped, depth, unread):
    """One simple command. `polling`: it begins a while or until loop, so what it runs is that loop's condition. `looped`: it runs inside a loop."""
    args, via_xargs = kg.unwrap(cmd.words)
    if not args or args[0].dynamic:
        return None
    base, rest = os.path.basename(args[0].text).lower(), args[1:]
    if polling and probes(base, rest):
        return R_POLL
    if base == "sleep":
        if looped:
            return R_LOOP
        secs = None if via_xargs else sleep_seconds(rest)
        return R_SLEEP if secs is not None and secs >= LONG_S else None
    if base == "tail":
        return R_TAIL if follows(rest) else None
    if base in kg.SHELLS:
        return check_shell(cmd, rest, depth, unread, looped)
    if base == "eval" and not (rest and kg.opaque(rest[0])):
        return analyze(" ".join(w.text for w in rest), depth + 1, unread, looped)
    if kg.INTERP.match(base):
        return check_script(rest, cmd.bodies)
    return None


def analyze(text, depth, unread, looped=False):
    """The reason this command text must be denied, or None. Whatever could not be read is appended to `unread`. `looped`: the text runs inside a loop."""
    if depth > MAX_DEPTH:
        unread.append(U_DEEP)
        return None
    cmds, unparsed = kg.lex(text)
    if unparsed:
        unread.append(unparsed)
    open_loops = 0
    for cmd in cmds:
        starts = lead(cmd.words)
        for kw in starts:
            open_loops = max(0, open_loops - 1) if kw == "done" else open_loops + 1
        why = check(cmd, "while" in starts or "until" in starts, looped or open_loops > 0, depth, unread)
        if why:
            return why
    return None


def verdict(text):
    """(the reason to deny or None, the reason it could not be read or None): something found wins over something not read."""
    unread = []
    why = analyze(text, 0, unread)
    return why, (unread[0] if unread else None)


def main():
    why = unread = None
    try:
        kg.arm(TIMEOUT_S)
        why, unread = verdict(sys.stdin.buffer.read().decode("utf-8", "replace"))
    except kg.GuardTimeout:
        unread = U_TIMEOUT % TIMEOUT_S
    except Exception as exc:  # a command this could not read is one it cannot judge: say so, and let it through (a cost guard, not a gate)
        unread = U_ERROR % type(exc).__name__
    kg.arm(0)
    if why:
        sys.stdout.write(why + "\n")
        return 3
    if unread:
        sys.stdout.write(unread + "\n")
        return 4
    sys.stdout.write("ok\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
