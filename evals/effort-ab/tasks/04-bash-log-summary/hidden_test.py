"""Hidden acceptance test for 04-bash-log-summary (stdlib only).

Runs `bash summarize.sh` from the agent's workdir (cwd) against log files generated
into a scratch directory under cwd, which is removed on exit.
"""
import atexit
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from collections import Counter

WORK = os.getcwd()
SCRATCH = tempfile.mkdtemp(prefix=".accept-logs-", dir=WORK)
ENV = dict(os.environ, LC_ALL="C", LANG="C")
STAMP = "[10/Oct/2023:13:55:36 +0000]"
IPV4_PREFIX = re.compile(r"^[0-9]{1,3}(?:\.[0-9]{1,3}){3} ")
STATUS = re.compile(r"^[23][0-9]{2}$")


def _cleanup():
    shutil.rmtree(SCRATCH, ignore_errors=True)


def _watchdog(signum, frame):
    sys.stderr.write("hidden test timed out\n")
    _cleanup()
    os._exit(124)


atexit.register(_cleanup)
signal.signal(signal.SIGALRM, _watchdog)
signal.alarm(55)


def entry(ip, status, request="GET /index.html HTTP/1.1", size="512", tail=""):
    return f'{ip} - - {STAMP} "{request}" {status} {size}{tail}'


def write_log(name, lines, trailing_newline=True):
    path = os.path.join(SCRATCH, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    text = "\n".join(lines) + ("\n" if trailing_newline and lines else "")
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)
    return os.path.relpath(path, WORK)


def run(*args):
    return subprocess.run(
        ["bash", "summarize.sh", *args], cwd=WORK, env=ENV, stdin=subprocess.DEVNULL,
        capture_output=True, text=True, encoding="utf-8", timeout=20,
    )


def lines_for(counts, seed=7, status="200"):
    lines = [entry(ip, status) for ip, n in counts.items() for _ in range(n)]
    random.Random(seed).shuffle(lines)
    return lines


def oracle_counts(lines):
    """Independent restatement of the counting rules in the spec."""
    counts = Counter()
    for line in lines:
        if not IPV4_PREFIX.match(line):
            continue
        opening = line.find('"')
        closing = line.find('"', opening + 1) if opening >= 0 else -1
        if closing < 0:
            continue
        tokens = line[closing + 1:].split()
        if tokens and STATUS.match(tokens[0]):
            counts[line.split(" ", 1)[0]] += 1
    return counts


def ranked(counts):
    return [f"{n} {ip}" for ip, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]


class SummarizeHiddenTests(unittest.TestCase):
    def assertOutput(self, proc, expected_lines):
        self.assertEqual(proc.returncode, 0, f"exit {proc.returncode}, stderr={proc.stderr!r}")
        self.assertEqual(proc.stdout, "".join(line + "\n" for line in expected_lines))

    def test_ties_break_by_ip_in_plain_string_order(self):
        path = write_log("ties.log", lines_for({
            "10.0.0.2": 3, "10.0.0.10": 3, "9.9.9.9": 3, "10.0.0.1": 3, "100.0.0.1": 2, "2.2.2.2": 1,
        }))
        self.assertOutput(run(path, "10"), [
            "3 10.0.0.1", "3 10.0.0.10", "3 10.0.0.2", "3 9.9.9.9", "2 100.0.0.1", "1 2.2.2.2",
        ])
        self.assertOutput(run(path), ["3 10.0.0.1", "3 10.0.0.10", "3 10.0.0.2"])

    def test_counts_are_compared_numerically(self):
        path = write_log("numeric.log", lines_for({
            "1.1.1.1": 100, "2.2.2.2": 12, "3.3.3.3": 9, "4.4.4.4": 10,
        }))
        self.assertOutput(run(path, "10"), ["100 1.1.1.1", "12 2.2.2.2", "10 4.4.4.4", "9 3.3.3.3"])

    def test_only_2xx_and_3xx_statuses_count(self):
        lines = [entry("10.1.1.1", status) for status in ("200", "201", "204", "299", "300", "301", "304", "399")]
        lines += [entry("10.1.1.2", status)
                  for status in ("100", "101", "199", "400", "404", "418", "499", "500", "503", "600")]
        lines += [entry("10.1.1.3", status) for status in ("-", "20", "2000", "abc", "2xx", "+200")]
        lines.append(entry("10.1.1.3", "200"))
        path = write_log("status.log", lines)
        self.assertOutput(run(path, "10"), ["8 10.1.1.1", "1 10.1.1.3"])

    def test_ips_without_counted_requests_are_not_listed(self):
        path = write_log("only-failures.log", [entry("10.4.4.4", "404"), entry("10.4.4.5", "500")])
        self.assertOutput(run(path), [])
        self.assertOutput(run(path, "5"), [])

    def test_lines_that_do_not_start_with_an_ipv4_and_a_space_are_ignored(self):
        good = entry("10.0.0.1", "200")
        lines = [
            good,
            " " + entry("10.0.0.2", "200"),
            "\t" + entry("10.0.0.3", "200"),
            entry("::1", "200"),
            entry("2001:db8::1", "200"),
            entry("example.com", "200"),
            entry("1.2.3", "200"),
            entry("1.2.3.4.5", "200"),
            entry("1234.1.1.1", "200"),
            f'1.2.3.4- - - {STAMP} "GET / HTTP/1.1" 200 5',
            "",
            "   ",
            "garbage",
            "10.0.0.4",
            "10.0.0.5 ",
            good,
        ]
        path = write_log("not-ipv4.log", lines)
        self.assertOutput(run(path, "10"), ["2 10.0.0.1"])

    def test_lines_without_a_quoted_request_and_status_are_ignored(self):
        lines = [
            entry("10.0.0.1", "200"),
            f"10.0.0.6 - - {STAMP} GET / HTTP/1.1 200 5",
            f'10.0.0.7 - - {STAMP} "GET / HTTP/1.1 200 5',
            f'10.0.0.8 - - {STAMP} "GET / HTTP/1.1"',
            f'10.0.0.9 - - {STAMP} "GET / HTTP/1.1" ',
        ]
        path = write_log("no-status.log", lines)
        self.assertOutput(run(path, "10"), ["1 10.0.0.1"])

    def test_request_with_spaces_and_combined_log_format(self):
        lines = [
            entry("10.2.2.2", "200", request="GET /my file name.txt HTTP/1.1"),
            entry("10.2.2.2", "404", request="GET /a b c d e f HTTP/1.1"),
            entry("10.2.2.3", "404", tail=' "http://ref.example/ 200 " "Mozilla/5.0 (X11) 200 300"'),
            entry("10.2.2.3", "200", tail=' "-" "Mozilla/5.0 404 500"'),
            f'10.2.2.4 - frank {STAMP} "GET / HTTP/1.1" 304 -',
            f'10.2.2.5 - - {STAMP} "-" 408 -',
        ]
        path = write_log("combined.log", lines)
        self.assertOutput(run(path, "10"), ["1 10.2.2.2", "1 10.2.2.3", "1 10.2.2.4"])

    def test_final_line_without_a_trailing_newline_still_counts(self):
        path = write_log("no-newline.log", [entry("10.3.3.3", "200"), entry("10.3.3.4", "200")],
                         trailing_newline=False)
        self.assertOutput(run(path), ["1 10.3.3.3", "1 10.3.3.4"])
        single = write_log("single.log", [entry("10.3.3.5", "301")], trailing_newline=False)
        self.assertOutput(run(single), ["1 10.3.3.5"])

    def test_n_larger_than_the_number_of_distinct_ips_prints_what_exists(self):
        path = write_log("two.log", lines_for({"10.5.5.1": 2, "10.5.5.2": 1}))
        for args in ((path,), (path, "10"), (path, "2")):
            self.assertOutput(run(*args), ["2 10.5.5.1", "1 10.5.5.2"])
        self.assertOutput(run(path, "1"), ["2 10.5.5.1"])

    def test_default_is_three_and_n_limits_the_output(self):
        path = write_log("five.log", lines_for({
            "10.6.6.1": 5, "10.6.6.2": 4, "10.6.6.3": 3, "10.6.6.4": 2, "10.6.6.5": 1,
        }))
        top = ["5 10.6.6.1", "4 10.6.6.2", "3 10.6.6.3", "2 10.6.6.4", "1 10.6.6.5"]
        self.assertOutput(run(path), top[:3])
        for n in (1, 2, 4, 5, 6):
            self.assertOutput(run(path, str(n)), top[:n])

    def test_empty_and_all_ignored_files_print_nothing(self):
        empty = write_log("empty.log", [])
        self.assertOutput(run(empty), [])
        self.assertOutput(run(empty, "5"), [])
        junk = write_log("junk.log", ["", "not a log line", entry("::1", "200")])
        self.assertOutput(run(junk), [])

    def test_missing_file_reports_on_stderr_and_exits_2(self):
        spaced = os.path.join(SCRATCH, "no such dir", "missing log.txt")
        for args, shown in (
            (("no-such.log",), "no-such.log"),
            (("no-such.log", "5"), "no-such.log"),
            ((spaced,), spaced),
            (("/nonexistent-dir-for-accept/missing.log", "2"), "/nonexistent-dir-for-accept/missing.log"),
        ):
            with self.subTest(args=args):
                proc = run(*args)
                self.assertEqual(proc.returncode, 2)
                self.assertEqual(proc.stdout, "")
                self.assertEqual(proc.stderr.rstrip("\n"), f"error: no such file: {shown}")

    def test_path_with_spaces(self):
        path = write_log("dir with spaces/my access.log", lines_for({"10.7.7.1": 2, "10.7.7.2": 1}))
        self.assertOutput(run(path), ["2 10.7.7.1", "1 10.7.7.2"])

    def test_output_has_no_padding_around_the_count(self):
        path = write_log("pad.log", lines_for({"10.8.8.8": 12}))
        self.assertEqual(run(path).stdout, "12 10.8.8.8\n")

    def test_large_random_log_matches_the_spec(self):
        rng = random.Random(20261123)
        ips = [f"{rng.randint(1, 255)}.{rng.randint(0, 255)}.{rng.randint(0, 255)}.{rng.randint(0, 255)}"
               for _ in range(40)]
        ips += ["10.0.0.1", "10.0.0.10", "10.0.0.2", "9.9.9.9", "192.168.1.1", "192.168.10.1"]
        weird = [
            "", "garbage", "10.0.0.9",
            ' 10.0.0.1 - - [x] "GET / HTTP/1.1" 200 1',
            '::1 - - [x] "GET / HTTP/1.1" 200 1',
            '1.2.3 - - [x] "GET / HTTP/1.1" 200 1',
            "10.0.0.2 - - [x] GET / HTTP/1.1 200 1",
            '10.0.0.3 - - [x] "GET / HTTP/1.1"',
        ]
        statuses = ["200", "200", "200", "204", "301", "304", "404", "404", "500", "503", "-", "100", "399", "400"]
        lines = []
        for _ in range(800):
            if rng.random() < 0.07:
                lines.append(rng.choice(weird))
                continue
            lines.append(entry(
                rng.choice(ips[:12] + ips),
                rng.choice(statuses),
                request=rng.choice(["GET / HTTP/1.1", "GET /a b HTTP/1.1", "POST /api/v1/items HTTP/1.1", "-"]),
                tail=rng.choice(["", ' "-" "curl/8.0 200"', ' "http://x/ 404" "ua"']),
            ))
        path = write_log("big.log", lines)
        expected = ranked(oracle_counts(lines))
        self.assertGreater(len(expected), 10)
        self.assertOutput(run(path), expected[:3])
        self.assertOutput(run(path, "1000"), expected)


if __name__ == "__main__":
    unittest.main()
