"""The measurement pass of test/heimdall-statusline-perf-budget.test.sh.

Kept out of the shell file: a python body inside `$( ... <<'PY' ... PY )` is parsed by bash
3.2 (this repo's floor) as shell text first, and it chokes on perfectly valid python.

One process, one hermetic Sandbox (test/lib/statusline_sandbox.py) shared by both sections, so
the identity / gitcount caches behave exactly as they do in a real session. Prints
machine-readable lines the shell asserts on:

    NOTE ...                        only when the built-in falsifier is active
    ALARM <survived> <n> <ms...>    renders that completed under the SIGALRM, then each ms
    SOFT <wall-median> <wall-max> <cpu-median> <loadavg>
    REFRESHED <names|->             throttles a render disturbed (- == the timed region was closed)

Environment: ROOT CLI FIXTURE ALARM_S ALARM_N SOFT_N, and INJECT (seconds; empty = off).
"""
import os
import resource
import statistics

from statusline_sandbox import Sandbox

root, cli = os.environ["ROOT"], os.environ["CLI"]
alarm_s, alarm_n, soft_n = int(os.environ["ALARM_S"]), int(os.environ["ALARM_N"]), int(os.environ["SOFT_N"])
inject = os.environ.get("INJECT", "")
sb = Sandbox(os.environ["FIXTURE"])

try:
    if inject:
        # The falsifier: a throwaway tree — every bin/ entry symlinked to the real one except the
        # wrapper, which is a copy with "sleep N" right after its HERE= line — judged by the very
        # same code path as the real CLI.
        fals = sb.base + "/falsifier"
        os.makedirs(fals + "/bin")
        for name in os.listdir(root + "/bin"):
            if name != "heimdall-statusline":
                os.symlink(root + "/bin/" + name, fals + "/bin/" + name)
        os.symlink(root + "/sentinels", fals + "/sentinels")
        lines, done = [], False
        for line in open(cli).read().split("\n"):
            lines.append(line)
            if not done and line.startswith("HERE="):
                lines.append("sleep " + inject)
                done = True
        with open(fals + "/bin/heimdall-statusline", "w") as f:
            f.write("\n".join(lines))
        os.chmod(fals + "/bin/heimdall-statusline", 0o755)
        cli = fals + "/bin/heimdall-statusline"
        print("NOTE falsifier active: wrapper copy with sleep %s injected" % inject)

    blob = sb.cursor_blob

    # 1) the hard-kill backstop: ALARM_N renders under a real SIGALRM; the median is judged.
    survived, ms_list = 0, []
    for _ in range(alarm_n):
        ms, rc, out = sb.render(cli, blob, alarm=alarm_s)
        ms_list.append(ms)
        if rc == 0 and len(out) > 0:
            survived += 1
    print("ALARM %d %d %s" % (survived, alarm_n, " ".join("%.0f" % m for m in ms_list)))

    # 2+3) the warm soft budgets. One untimed render first: it pays for everything first-run
    # (identity, sigil cache, bytecode) so the SOFT_N timed ones are what a running session sees.
    sb.render(cli, blob)
    wall, cpu = [], []
    for _ in range(soft_n):
        r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
        ms, rc, out = sb.render(cli, blob)
        r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
        wall.append(ms)
        cpu.append(((r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)) * 1000)
    print("SOFT %.1f %.1f %.1f %.1f" % (statistics.median(wall), max(wall), statistics.median(cpu), os.getloadavg()[0]))

    # the timed region must have been CLOSED: no refresh child may have been launched inside it
    print("REFRESHED %s" % (",".join(sb.refreshed()) or "-"))
finally:
    sb.close()
