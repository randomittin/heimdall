#!/usr/bin/env python3
"""test/lib/case_pool.py -- the cases of SEVERAL case files in ONE pool of processes, each file reported the way its own run prints it.

pair_code_harness.run_main runs the cases of ONE file, a process each, CASE_JOBS at a time. A suite with two such files that runs them one
after the other (test/app-pair-code.test.sh did) waits for the slowest case of the first before it starts the second: the pool is half
empty at the end of one file and at the start of the next. This puts the cases of every file in a single pool -- the file named first
starts first -- and reports each file as its own `python3 FILE` would: the result lines renumbered as one run's, in the order the file's
cases are declared, and one `P passed, F failed` tally.

usage: case_pool.py OUTDIR LABEL=CASE_FILE [LABEL=CASE_FILE ...]
  OUTDIR/LABEL.out  the file's report, its last line the tally
  OUTDIR/LABEL.rc   its exit status: 0 only when no case failed and every case ended with a tally
exit status: 0 when every file passed, 1 when one did not, 2 on a usage error.
A CASE_FILE is a module whose CASES tuple lists its case functions (its own main() hands the same tuple to pair_code_harness.run_main);
each case runs as `python3 CASE_FILE NAME` in a process of its own, for at most CASE_TIMEOUT_S seconds: past that it is killed and reported
as a case that ended without a tally, so a case that hangs is a failure, not a wait.
"""
import concurrent.futures
import importlib.util
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import pair_code_harness as H  # noqa: E402

CASE_TIMEOUT_S = 300


def case_names(path):
    """The names of the cases of the case file at `path`, in the order it declares them."""
    spec = importlib.util.spec_from_file_location("case_pool_" + os.path.basename(path).replace(".", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return [case.__name__ for case in module.CASES]


def run_case(path, name):
    """(exit code, everything it printed, stderr included) of one case run alone in a process of its own; the exit code is None for a case that
    outlived CASE_TIMEOUT_S and was killed."""
    try:
        proc = subprocess.run([sys.executable, path, name], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=CASE_TIMEOUT_S)
    except subprocess.TimeoutExpired as exc:
        return None, (exc.stdout or b"").decode("utf-8", "replace")
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


def report(results):
    """[(case name, exit code, output)] in declared order -> (the file's report, passed, failed): result lines renumbered as one run's, each
    case's own tally folded in, a case that ended without a tally one failure that says so."""
    lines, passed, failed, shown = [], 0, 0, 0
    for name, code, text in results:
        tallied = False
        for line in text.splitlines():
            counts, result = H.TALLY_LINE.match(line), H.RESULT_LINE.match(line)
            if counts:
                tallied = True
                passed, failed = passed + int(counts.group(1)), failed + int(counts.group(2))
            elif result:
                shown += 1
                lines.append("  %s%d. %s" % ("ok   " if result.group(1) == "ok" else "FAIL ", shown, result.group(2)))
            elif line.strip():
                lines.append(line)
        if not tallied:
            shown, failed = shown + 1, failed + 1
            lines.append("  FAIL %d. %s ended without a tally (exit %r) -- %s" % (shown, name, code, " ".join(text.split())[-300:]))
    lines += ["", "%d passed, %d failed" % (passed, failed)]
    return "\n".join(lines) + "\n", passed, failed


def main(argv):
    specs = [arg.split("=", 1) for arg in argv[2:]]
    if len(argv) < 3 or any(len(spec) != 2 or not spec[0] or not os.path.isfile(spec[1]) for spec in specs):
        print("usage: case_pool.py OUTDIR LABEL=CASE_FILE [LABEL=CASE_FILE ...]", file=sys.stderr)
        return 2
    outdir = argv[1]
    results = {label: [] for label, _path in specs}
    with concurrent.futures.ThreadPoolExecutor(max_workers=H.CASE_JOBS) as pool:
        children = [(label, name, pool.submit(run_case, path, name)) for label, path in specs for name in case_names(path)]
        for label, name, child in children:  # declared order: each file's report reads as its own run would
            code, text = child.result()
            results[label].append((name, code, text))
    status = 0
    for label, _path in specs:
        text, _passed, failed = report(results[label])
        with open(os.path.join(outdir, label + ".out"), "w", encoding="utf-8") as f:
            f.write(text)
        with open(os.path.join(outdir, label + ".rc"), "w", encoding="utf-8") as f:
            f.write("%d\n" % (1 if failed else 0))
        status = status or (1 if failed else 0)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
