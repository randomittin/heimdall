#!/usr/bin/env bash
# test/false-green-taskgen.test.sh: the mechanical Study A task selection (evals/benchmark/false-green/PREREG.md
# section 5 and Amendment 2), bin/lib/fg_taskgen.py.
#
# WHAT THIS PROVES
#   [O] ORDER    the selection order is the sha256 of the issue URL, ascending, whatever order the candidates
#                are listed in; candidates.txt parses back to what was written and a malformed line is an error.
#   [F] FILTER   the structural filters keep exactly the issues whose closing pull request is merged, small, and
#                changes a test module and a source file, and say why each other issue is dropped.
#   [H] HARVEST  `harvest` against a stub `gh` (no network): the pool is the recorded queries' repositories, one
#                task per pull request, candidates sorted by URL, the header records the queries, the filters
#                and the counts; a failing gh is an error, never an empty pool.
#
# Hermetic: HOME and TMPDIR point into a throwaway dir; no network (gh is a stub).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fg-taskgen-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" TMPDIR="$TMP/tmp"; mkdir -p "$HOME" "$TMPDIR"

# A python white-box section prints "PASS<TAB>desc<TAB>detail" / "FAIL..." lines and a final "END" line;
# a crash before END is itself a failure, never a silent skip.
report() {  # report <output file>
  local verdict desc detail seen_end=0
  while IFS=$'\t' read -r verdict desc detail; do
    case "$verdict" in
      PASS) ok "$desc" ;;
      FAIL) bad "$desc  [$detail]" ;;
      END)  seen_end=1 ;;
      *)    bad "unexpected line from the python section: $verdict $desc" ;;
    esac
  done <"$1"
  [ "$seen_end" -eq 1 ] || bad "the python section did not run to its end: $(tail -3 "$1.err" 2>/dev/null | tr '\n' ' ')"
}

# ══════════════════════════════════════════════════════════════════════════════
echo "[O] order: sha256 of the issue URL, ascending"
# ══════════════════════════════════════════════════════════════════════════════
python3 - "$REPO" >"$TMP/o.out" 2>"$TMP/o.out.err" <<'PY'
import os, random, sys
repo = sys.argv[1]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
import fg_taskgen

out = []
def t(desc, cond, detail=""):
    out.append("%s\t%s\t%s" % ("PASS" if cond else "FAIL", desc, "" if cond else detail))

t("the rank is the lower-case hex sha256 of the UTF-8 URL (the standard 'abc' vector)",
  fg_taskgen.issue_rank("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", fg_taskgen.issue_rank("abc"))

cands = [{"issue": "https://github.com/acme/r%d/issues/%d" % (i % 7, i), "pr": "https://github.com/acme/r%d/pull/%d" % (i % 7, 100 + i), "merge": "%040x" % i,
          "license": "MIT", "kind": "bugfix" if i % 2 else "feature", "tests": ["tests/test_%d.py" % i, "tests/conftest.py"]} for i in range(40)]
first = fg_taskgen.ordered(cands)
ranks = [fg_taskgen.issue_rank(c["issue"]) for c in first]
t("candidates come out in ascending rank", ranks == sorted(ranks), ranks[:3])
shuffled = list(cands)
random.Random(7).shuffle(shuffled)
t("the order does not depend on the order the candidates are listed in", [c["issue"] for c in fg_taskgen.ordered(shuffled)] == [c["issue"] for c in first])
t("the order is not the listing order (the test would be vacuous otherwise)", [c["issue"] for c in first] != [c["issue"] for c in cands])

text = "# comment\n# another\n" + "".join(fg_taskgen.format_candidate(c) + "\n" for c in cands) + "\n"
t("candidates.txt parses back to exactly what was written, comments and blank lines skipped", fg_taskgen.parse_candidates(text) == cands)
try:
    fg_taskgen.parse_candidates("https://x\tonly three\tcolumns\n")
    t("a line with the wrong number of columns is an error", False, "no exception")
except ValueError as exc:
    t("a line with the wrong number of columns is an error, naming the line", "line 1" in str(exc), str(exc))

print("\n".join(out))
print("END")
PY
report "$TMP/o.out"

# ══════════════════════════════════════════════════════════════════════════════
echo "[F] filter: which issues become candidates, and why the others do not"
# ══════════════════════════════════════════════════════════════════════════════
python3 - "$REPO" >"$TMP/f.out" 2>"$TMP/f.out.err" <<'PY'
import os, sys
repo = sys.argv[1]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
import fg_taskgen

out = []
def t(desc, cond, detail=""):
    out.append("%s\t%s\t%s" % ("PASS" if cond else "FAIL", desc, "" if cond else detail))

OID = "a" * 40
def issue(files, merged=True, adds=10, dels=5, total=None, oid=OID, prs=1):
    pr = {"url": "https://github.com/acme/r/pull/9", "merged": merged, "additions": adds, "deletions": dels,
          "mergeCommit": {"oid": oid} if oid else None,
          "files": {"totalCount": total if total is not None else len(files), "nodes": [{"path": p, "changeType": c} for p, c in files]}}
    return {"url": "https://github.com/acme/r/issues/1", "title": "t", "closedByPullRequestsReferences": {"nodes": [pr] * prs if prs else []}}

GOOD = [("src/pkg/a.py", "MODIFIED"), ("tests/test_a.py", "ADDED")]
def why(node):
    cand, reason = fg_taskgen.candidate_from(node, "bugfix", "acme/r", "MIT")
    return reason if cand is None else None

cand, reason = fg_taskgen.candidate_from(issue(GOOD), "bugfix", "acme/r", "MIT")
t("a merged, small pull request with a test module and a source file is a candidate", reason is None and cand is not None, reason)
t("the candidate carries issue, pull request, merge commit, licence, kind and test paths",
  cand == {"issue": "https://github.com/acme/r/issues/1", "pr": "https://github.com/acme/r/pull/9", "merge": OID, "license": "MIT", "kind": "bugfix", "tests": ["tests/test_a.py"]}, cand)
c2, _ = fg_taskgen.candidate_from(issue(GOOD + [("tests/conftest.py", "MODIFIED"), ("tests/data/x.json", "ADDED")]), "feature", "acme/r", "ISC")
t("conftest and test data are test paths the ground truth will copy, and the kind is passed through",
  c2["tests"] == ["tests/test_a.py", "tests/conftest.py", "tests/data/x.json"] and c2["kind"] == "feature" and c2["license"] == "ISC", c2)

t("no closing pull request: dropped", why(issue(GOOD, prs=0)) == "no merged pull request closes it")
t("a closing pull request that was not merged: dropped", why(issue(GOOD, merged=False, oid=None)) == "no merged pull request closes it")
t("a merged pull request without a merge commit: dropped", why(issue(GOOD, oid=None)) == "no merged pull request closes it")
t("more than 20 files: dropped", "more than 20 files" in (why(issue(GOOD, total=21)) or ""))
t("exactly 20 files: kept", why(issue(GOOD, total=20)) is None)
t("more than 600 lines: dropped", "more than 600 lines" in (why(issue(GOOD, adds=500, dels=101)) or ""))
t("exactly 600 lines: kept", why(issue(GOOD, adds=500, dels=100)) is None)
t("only conftest.py changed among the tests (no test module): dropped", why(issue([("src/a.py", "MODIFIED"), ("tests/conftest.py", "MODIFIED")])) == "the pull request changes no test module")
t("a test module that the pull request deleted does not count", why(issue([("src/a.py", "MODIFIED"), ("tests/test_old.py", "DELETED")])) == "the pull request changes no test module")
t("a *_test.py module counts", why(issue([("src/a.py", "MODIFIED"), ("pkg/a_test.py", "ADDED")])) is None)
t("tests only, no source: dropped", why(issue([("tests/test_a.py", "ADDED")])) == "the pull request changes no python source file")
t("a change under docs/ is not source: dropped", why(issue([("docs/conf.py", "MODIFIED"), ("tests/test_a.py", "ADDED")])) == "the pull request changes no python source file")
t("a non-python source file is not source: dropped", why(issue([("README.md", "MODIFIED"), ("tests/test_a.py", "ADDED")])) == "the pull request changes no python source file")
t("a test path with a comma cannot be written to candidates.txt: dropped", "comma or whitespace" in (why(issue([("src/a.py", "MODIFIED"), ("tests/test_a,b.py", "ADDED")])) or ""))
t("a second, unmerged closing pull request does not hide a merged first one", why({**issue(GOOD), "closedByPullRequestsReferences": {"nodes": [
    {"url": "u", "merged": False, "additions": 1, "deletions": 1, "mergeCommit": None, "files": {"totalCount": 0, "nodes": []}}, issue(GOOD)["closedByPullRequestsReferences"]["nodes"][0]]}}) is None)

print("\n".join(out))
print("END")
PY
report "$TMP/f.out"

# ══════════════════════════════════════════════════════════════════════════════
echo "[H] harvest: against a stub gh, no network"
# ══════════════════════════════════════════════════════════════════════════════
mkdir -p "$TMP/stubbin"
cat >"$TMP/stubbin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
if os.environ.get("STUB_GH_FAIL"):
    sys.stderr.write("stub gh: forced failure\n")
    sys.exit(1)
if a[:1] == ["--version"]:
    print("gh version 0.0.0-test (stub)")
    sys.exit(0)

def pr(n, merged=True, files=None, adds=5, dels=5):
    files = files if files is not None else [("src/m.py", "MODIFIED"), ("tests/test_m.py", "ADDED")]
    return {"url": "https://github.com/acme/%s/pull/%d" % ("%s", n), "merged": merged, "additions": adds, "deletions": dels,
            "mergeCommit": {"oid": ("%040x" % n)} if merged else None,
            "files": {"totalCount": len(files), "nodes": [{"path": p, "changeType": c} for p, c in files]}}

def issue(repo, n, prs):
    for p in prs:
        p["url"] = p["url"] % repo if "%s" in p["url"] else p["url"]
    return {"url": "https://github.com/acme/%s/issues/%d" % (repo, n), "title": "t", "closedByPullRequestsReferences": {"nodes": prs}}

if "search/repositories" in a:
    # the same repositories answer every licence query: a repository found under several stays once
    items = [{"full_name": "acme/alpha"}, {"full_name": "acme/beta"}] + ([{"full_name": "acme/boom"}] if os.environ.get("STUB_GH_BOOM") else [])
    print(json.dumps({"items": items}))
    sys.exit(0)
if "graphql" in a:
    # the real gh turns -F values that look like numbers, booleans or null into non-strings: owner and name must go as -f
    for i, x in enumerate(a):
        if x == "-F" and i + 1 < len(a) and a[i + 1].split("=", 1)[0] in ("owner", "name"):
            sys.stderr.write("gh: Variable $%s of type String! was provided invalid value\n" % a[i + 1].split("=", 1)[0])
            sys.exit(1)
    name = [x for x in a if x.startswith("name=")][0].split("=", 1)[1]
    if name == "boom":
        sys.stderr.write("gh: Could not resolve to a Repository with the name 'acme/boom'.\n")
        sys.exit(1)
    empty = {"nodes": []}
    if name == "alpha":
        shared = pr(11)
        data = {"rateLimit": {"remaining": 4000, "resetAt": "2026-10-05T00:00:00Z"},
                "repository": {"nameWithOwner": "acme/alpha", "licenseInfo": {"spdxId": "MIT"},
                               "l0": {"nodes": [issue("alpha", 1, [dict(shared)]), issue("alpha", 2, [dict(shared)]),
                                                issue("alpha", 3, [pr(12, files=[("src/m.py", "MODIFIED")])])]},
                               "l1": {"nodes": [issue("alpha", 4, [pr(13)])]}, "l2": empty}}
    else:
        data = {"rateLimit": {"remaining": 50, "resetAt": "2026-10-05T00:00:00Z"},
                "repository": {"nameWithOwner": "acme/beta", "licenseInfo": {"spdxId": "MIT"},
                               "l0": {"nodes": [issue("beta", 1, [pr(21, merged=False)]), issue("beta", 2, [pr(22)])]}, "l1": empty, "l2": empty}}
    print(json.dumps({"data": data}))
    sys.exit(0)
sys.exit(3)
PY
chmod +x "$TMP/stubbin/gh"
python3 - "$REPO" "$TMP" >"$TMP/h.out" 2>"$TMP/h.out.err" <<'PY'
import contextlib, io, os, sys
repo, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
os.environ["PATH"] = os.path.join(tmp, "stubbin") + os.pathsep + os.environ["PATH"]
import fg_taskgen
fg_taskgen.PACE_S = fg_taskgen.RETRY_S = fg_taskgen.RESET_SLACK_S = 0

def quiet(fn, *args, **kwargs):
    with contextlib.redirect_stdout(io.StringIO()):
        return fn(*args, **kwargs)

out = []
def t(desc, cond, detail=""):
    out.append("%s\t%s\t%s" % ("PASS" if cond else "FAIL", desc, "" if cond else detail))

path = os.path.join(tmp, "candidates.txt")
rc = quiet(fg_taskgen.harvest, path)
text = open(path, encoding="utf-8").read()
cands = fg_taskgen.parse_candidates(text)
t("harvest exits 0 and writes the file", rc == 0 and os.path.getsize(path) > 0, rc)
t("the candidates are the issues whose pull request passes the filters, one per pull request, sorted by issue URL",
  [c["issue"] for c in cands] == ["https://github.com/acme/alpha/issues/1", "https://github.com/acme/alpha/issues/4", "https://github.com/acme/beta/issues/2"],
  [c["issue"] for c in cands])
t("two issues closed by one pull request give one candidate, the lexicographically first issue", sum(1 for c in cands if c["pr"].endswith("/pull/11")) == 1)
t("the kind follows the label that found the issue", [c["kind"] for c in cands] == ["bugfix", "feature", "bugfix"], [c["kind"] for c in cands])
t("the licence is the repository's", all(c["license"] == "MIT" for c in cands))
t("the merge commit and test paths come from the pull request", cands[0]["merge"] == "%040x" % 11 and cands[0]["tests"] == ["tests/test_m.py"], cands[0])
header = [l for l in text.splitlines() if l.startswith("#")]
joined = "\n".join(header)
t("the header records one repository query per licence", all(("license:%s " % k) in joined for k in fg_taskgen.LICENSES), joined[:300])
t("the header records the label queries and the structural filters", '"bug" / "enhancement" / "feature"' in joined and "at most 20 files and 600 lines" in joined)
t("the header records the counts and why issues were dropped", "pool: 2 repositories, 6 issues examined, 3 candidates." in joined and "no merged pull request closes it: 1" in joined and "the pull request changes no test module: 1" in joined, joined[-500:])
t("the header records when and with what it ran", "harvested: 20" in joined and "gh version 0.0.0-test" in joined)
t("harvest --max-repos limits the pool (a trial run)", quiet(fg_taskgen.harvest, os.path.join(tmp, "trial.txt"), max_repos=1) == 0 and
  [c["issue"] for c in fg_taskgen.parse_candidates(open(os.path.join(tmp, "trial.txt")).read())] == ["https://github.com/acme/alpha/issues/1", "https://github.com/acme/alpha/issues/4"])

# one repository that cannot be queried is recorded and skipped, not fatal and not silent
os.environ["STUB_GH_BOOM"] = "1"
boom = os.path.join(tmp, "boom.txt")
t("a repository that cannot be queried does not stop the harvest", quiet(fg_taskgen.harvest, boom) == 0)
boom_text = open(boom, encoding="utf-8").read()
t("and the candidates are unchanged", [c["issue"] for c in fg_taskgen.parse_candidates(boom_text)] == [c["issue"] for c in cands])
t("and the header names it and the reason", "could not be queried: 1 (acme/boom: " in boom_text and "Could not resolve to a Repository" in boom_text, boom_text[-700:])
del os.environ["STUB_GH_BOOM"]

os.environ["STUB_GH_FAIL"] = "1"
try:
    quiet(fg_taskgen.harvest, os.path.join(tmp, "never.txt"))
    t("a failing gh is an error, not an empty pool", False, "no exception")
except RuntimeError as exc:
    t("a failing gh is an error, not an empty pool", "forced failure" in str(exc), str(exc))
t("and a failed harvest wrote nothing", not os.path.exists(os.path.join(tmp, "never.txt")))

print("\n".join(out))
print("END")
PY
report "$TMP/h.out"
check "the order subcommand prints rank and URL in ascending rank" bash -c "python3 '$REPO/bin/lib/fg_taskgen.py' order --candidates '$TMP/candidates.txt' | awk -F'\t' 'NR>1 && \$1 < prev {exit 1} {prev=\$1} END {exit NR==3 ? 0 : 1}'"

echo
echo "false-green-taskgen: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
