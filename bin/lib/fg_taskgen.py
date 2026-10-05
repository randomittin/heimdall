#!/usr/bin/env python3
"""fg_taskgen: builds the Study A task set mechanically (PREREG.md section 5 and Amendment 2).

  harvest   ask GitHub (gh api) for candidate issues and write tasks/candidates.txt      [network]
  order     print the candidates in ascending sha256(issue URL) order

Nothing is chosen by hand. The pool is whatever the recorded queries and structural filters return, the order
is the sha256 of the issue URL, and (in `verify`) a candidate is accepted only if the upstream pull request's
own tests fail at the commit before the merge and pass at the merge commit.

A candidate line in candidates.txt is tab-separated: issue URL, pull request URL, merge commit sha, licence,
kind (bugfix or feature), and the comma-separated test paths the pull request changed.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import subprocess
import sys
import time

LICENSES = {"mit": "MIT", "apache-2.0": "Apache-2.0", "bsd-3-clause": "BSD-3-Clause", "bsd-2-clause": "BSD-2-Clause", "isc": "ISC"}
REPO_QUERY = "language:python license:%s stars:>=500 size:<30000 archived:false"
REPOS_PER_LICENSE = 60
# issue label -> task category; a repo is asked once per label and keeps its most recently updated closed issues
LABELS = (("bug", "bugfix"), ("enhancement", "feature"), ("feature", "feature"))
ISSUES_PER_LABEL = 5
MAX_PR_FILES, MAX_PR_LINES = 20, 600
PACE_S, RETRY_S, RESET_SLACK_S = 3.0, 10.0, 5.0     # seconds: between search calls, per retry step, past a rate-limit reset

TEST_PATH = re.compile(r"(^|/)(tests?|testing)/|(^|/)test_[^/]*\.py$|_tests?\.py$|(^|/)conftest\.py$")
TEST_MODULE = re.compile(r"(^|/)(test_[^/]*|[^/]*_tests?)\.py$")
DOC_PATH = re.compile(r"(^|/)(docs?|examples?|benchmarks?|scripts?)/")

ISSUE_QUERY = """
query($owner:String!,$name:String!){
  rateLimit{remaining resetAt}
  repository(owner:$owner,name:$name){
    nameWithOwner
    licenseInfo{spdxId}
    %s
  }
}
fragment F on Issue{
  url title
  closedByPullRequestsReferences(first:2,includeClosedPrs:false){
    nodes{
      url merged additions deletions mergeCommit{oid}
      files(first:20){totalCount nodes{path changeType}}
    }
  }
}
""" % "\n    ".join(
    'l%d: issues(first:%d,states:CLOSED,labels:["%s"],orderBy:{field:UPDATED_AT,direction:DESC}){nodes{...F}}' % (i, ISSUES_PER_LABEL, label)
    for i, (label, _kind) in enumerate(LABELS))


def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def issue_rank(url):
    """The selection order of PREREG.md section 5: the sha256 of the issue URL, ascending."""
    return hashlib.sha256(url.encode("utf-8")).hexdigest()


def classify(files):
    """(test paths, source paths) among a pull request's changed files, ignoring deleted ones and documentation."""
    live = [f["path"] for f in files if f.get("changeType") != "DELETED"]
    tests = [p for p in live if TEST_PATH.search(p)]
    sources = [p for p in live if p.endswith(".py") and not TEST_PATH.search(p) and not DOC_PATH.search(p)]
    return tests, sources


def candidate_from(issue, kind, repo, spdx):
    """(candidate dict, None) when the issue passes the structural filters, else (None, reason)."""
    prs = [pr for pr in (issue.get("closedByPullRequestsReferences") or {}).get("nodes") or [] if pr and pr.get("merged") and (pr.get("mergeCommit") or {}).get("oid")]
    if not prs:
        return None, "no merged pull request closes it"
    pr = prs[0]
    files = pr["files"]
    if files["totalCount"] > MAX_PR_FILES:
        return None, "the pull request changes more than %d files" % MAX_PR_FILES
    if pr["additions"] + pr["deletions"] > MAX_PR_LINES:
        return None, "the pull request changes more than %d lines" % MAX_PR_LINES
    tests, sources = classify(files["nodes"])
    if not any(TEST_MODULE.search(p) for p in tests):
        return None, "the pull request changes no test module"
    if not sources:
        return None, "the pull request changes no python source file"
    if any(re.search(r"[\s,]", p) for p in tests):
        return None, "a test path holds a comma or whitespace"
    return {"issue": issue["url"], "pr": pr["url"], "merge": pr["mergeCommit"]["oid"], "license": spdx, "kind": kind, "tests": tests}, None


def format_candidate(c):
    return "\t".join([c["issue"], c["pr"], c["merge"], c["license"], c["kind"], ",".join(c["tests"])])


def parse_candidates(text):
    """The candidate dicts of a candidates.txt (comment lines start with #)."""
    out = []
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 6:
            raise ValueError("candidates line %d has %d columns, expected 6" % (number, len(cols)))
        out.append(dict(zip(("issue", "pr", "merge", "license", "kind"), cols[:5]), tests=[p for p in cols[5].split(",") if p]))
    return out


def ordered(cands):
    return sorted(cands, key=lambda c: issue_rank(c["issue"]))


def _gh(args, attempts=3):
    done = None
    for attempt in range(attempts):
        done = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=180)
        if done.returncode == 0:
            return json.loads(done.stdout)
        time.sleep(10 * (attempt + 1))
    raise RuntimeError("gh %s failed: %s" % (" ".join(args[:2]), done.stderr.strip()[:300]))


def _repo_pool():
    pool = {}
    for key, spdx in LICENSES.items():
        doc = _gh(["api", "-X", "GET", "search/repositories", "-f", "q=" + REPO_QUERY % key, "-f", "sort=stars", "-f", "order=desc",
                   "-f", "per_page=%d" % REPOS_PER_LICENSE])
        for item in doc["items"]:
            pool.setdefault(item["full_name"], spdx)
        time.sleep(3)
    return pool


def _repo_candidates(repo, spdx, tally):
    owner, name = repo.split("/")
    doc = _gh(["api", "graphql", "-f", "query=" + ISSUE_QUERY, "-F", "owner=" + owner, "-F", "name=" + name])["data"]
    if doc["rateLimit"]["remaining"] < 100:
        time.sleep(max(0, (datetime.datetime.fromisoformat(doc["rateLimit"]["resetAt"].replace("Z", "+00:00")) - datetime.datetime.now(datetime.timezone.utc)).total_seconds()) + 5)
    found = []
    for i, (_label, kind) in enumerate(LABELS):
        for issue in doc["repository"]["l%d" % i]["nodes"]:
            tally["issues"] += 1
            cand, why = candidate_from(issue, kind, repo, spdx)
            if cand:
                found.append(cand)
            else:
                tally[why] = tally.get(why, 0) + 1
    return found


def harvest(out_path, max_repos=None):
    started = _now()
    pool = _repo_pool()
    repos = sorted(pool)[:max_repos] if max_repos else sorted(pool)
    tally, by_pr = {"issues": 0}, {}
    for repo in repos:
        for cand in _repo_candidates(repo, pool[repo], tally):
            # one task per pull request: when several issues close through the same one, the lexicographically first URL stays
            if cand["pr"] not in by_pr or cand["issue"] < by_pr[cand["pr"]]["issue"]:
                by_pr[cand["pr"]] = cand
    cands = sorted(by_pr.values(), key=lambda c: c["issue"])
    header = [
        "# false-green Study A candidate pool (PREREG.md section 5, Amendment 2). Generated by bin/lib/fg_taskgen.py harvest; not edited by hand.",
        "# harvested: %s .. %s UTC, %s" % (started, _now(), subprocess.run(["gh", "--version"], capture_output=True, text=True).stdout.splitlines()[0]),
        "# repository pool, one query per licence, REST search/repositories sorted by stars descending, first %d each (a repository in more than one stays once):" % REPOS_PER_LICENSE,
    ] + ["#   %s" % (REPO_QUERY % key) for key in LICENSES] + [
        "# issues per repository, GraphQL: closed, labelled %s, the %d most recently updated of each label, with their closing pull requests (first 2, merged ones only)." % (
            " / ".join('"%s"' % label for label, _kind in LABELS), ISSUES_PER_LABEL),
        "# structural filters: a merged pull request closes it; it changes at most %d files and %d lines; it changes a test module (test_*.py or *_test.py) and a python source file;" % (MAX_PR_FILES, MAX_PR_LINES),
        "# one issue per pull request. NOT yet checked here, checked by `verify` in sha256(issue URL) order: the upstream tests fail before the merge and pass at it, and the suite runs.",
        "# pool: %d repositories, %d issues examined, %d candidates. Dropped: %s" % (
            len(repos), tally["issues"], len(cands), "; ".join("%s: %d" % (why, n) for why, n in sorted(tally.items()) if why != "issues") or "nothing"),
        "# columns: issue URL, pull request URL, merge commit sha, licence, kind, changed test paths",
    ]
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(header) + "\n" + "".join(format_candidate(c) + "\n" for c in cands))
    sys.stdout.write("fg_taskgen: %d candidates from %d repositories -> %s\n" % (len(cands), len(repos), out_path))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="fg_taskgen", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    h = sub.add_parser("harvest")
    h.add_argument("--out", required=True)
    h.add_argument("--max-repos", type=int, help="stop after this many repositories (a trial run, never the registered one)")
    o = sub.add_parser("order")
    o.add_argument("--candidates", required=True)
    args = parser.parse_args(argv)
    if args.command == "harvest":
        return harvest(args.out, args.max_repos)
    with open(args.candidates, "r", encoding="utf-8") as fh:
        for cand in ordered(parse_candidates(fh.read())):
            sys.stdout.write("%s\t%s\n" % (issue_rank(cand["issue"]), cand["issue"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
