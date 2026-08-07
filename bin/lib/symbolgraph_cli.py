#!/usr/bin/env python3
"""symbolgraph_cli — the presentation half of bin/heimdall-graph.

The engine (symbolgraph.py) decides what is true; this module decides how few
bytes it takes to say it. That split matters because the whole justification
for this tool is token cost: a verbose answer is a failed answer.

Default output is TAB-separated columns under a single `#` header line — awk-,
grep- and eyeball-readable in one shot. `--json` gives the same rows as objects
for strict consumers. Every list is capped (see --limit) and a truncated list
always says so with `+N more`, so a caller can never mistake a capped answer
for a complete one.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import symbolgraph as sg  # noqa: E402 — path shim must precede the sibling import

EXIT_OK = 0
EXIT_NOT_INDEXED = 4


def _out(line=""):
    sys.stdout.write(line + "\n")


def _tab(*cols):
    _out("\t".join(str(c) for c in cols))


def _span(rec_file, start, end):
    return "%s:%d-%d" % (rec_file, start, end)


def _mark(edge_kind, ambiguous=False):
    """`~` flags a low-confidence edge (a shell literal match), `?` an ambiguous
    one (several definitions share the name). A reader must never mistake either
    for a proven call, so the marker rides on the row itself."""
    return ("~" if edge_kind == "quoted" else "") + ("?" if ambiguous else "")


def _emit_more(hidden):
    if hidden:
        _out("+%d more (use --limit 0 for all)" % hidden)


def _emit_limits():
    for line in sg.LIMITATIONS:
        _out("! " + line)


def _rel_to_repo(root, arg):
    """Accept a repo-relative, cwd-relative or absolute path; return repo-relative."""
    if not os.path.isabs(arg):
        direct = os.path.join(root, arg)
        if os.path.exists(direct):
            return os.path.normpath(arg)
    full = os.path.abspath(arg)
    try:
        rel = os.path.relpath(full, root)
    except ValueError:
        return os.path.normpath(arg)
    return os.path.normpath(rel)


def _not_indexed(what, name, index):
    langs = ", ".join(sorted(index["languages"])) or "none"
    sys.stderr.write(
        "heimdall-graph: %s '%s' not in index "
        "(indexed languages: %s; %d symbols over %d files)\n"
        % (what, name, langs, index["stats"]["symbols"], index["stats"]["files"])
    )
    for skip in index.get("skipped", []):
        sys.stderr.write("  not indexed: %s — %s\n" % (skip.get("lang", "?"), skip.get("reason", "")))
    return EXIT_NOT_INDEXED


# ── subcommands ───────────────────────────────────────────────────────────────

def cmd_index(index, freshness, as_json, _limit):
    meta = {
        "repo": index["repo"],
        "cache": sg.cache_path(index["repo"]),
        "stamp": index["stamp"],
        "generated_at": index["generated_at"],
        "freshness": freshness,
        "languages": index["languages"],
        "skipped": index["skipped"],
        "stats": index["stats"],
        "limitations": index["limitations"],
    }
    if as_json:
        _out(json.dumps(meta, indent=2))
        return EXIT_OK
    st = index["stats"]
    _out("# repo\tfiles\tsymbols\tedges\tfreshness")
    _tab(index["repo"], st["files"], st["symbols"], st["edges"], freshness)
    for lang, backend in sorted(index["languages"].items()):
        _tab("lang", lang, st["by_lang"].get(lang, 0), backend)
    for skip in index["skipped"]:
        _tab("skipped", skip.get("lang", "?"), skip.get("reason", ""))
    return EXIT_OK


def cmd_status(index, freshness, as_json, _limit):
    meta = {
        "repo": index["repo"],
        "cache": sg.cache_path(index["repo"]),
        "stamp": index["stamp"],
        "generated_at": index["generated_at"],
        "freshness": freshness,
        "languages": index["languages"],
        "skipped": index["skipped"],
        "stats": index["stats"],
    }
    if as_json:
        _out(json.dumps(meta, indent=2))
        return EXIT_OK
    _out("# key\tvalue")
    _tab("repo", meta["repo"])
    _tab("cache", meta["cache"])
    _tab("stamp", meta["stamp"])
    _tab("freshness", freshness)
    _tab("symbols", index["stats"]["symbols"])
    _tab("edges", index["stats"]["edges"])
    return EXIT_OK


def cmd_def(index, name, as_json, limit):
    rows = sg.q_def(index, name)
    if not rows:
        return _not_indexed("symbol", name, index)
    shown, hidden = sg.cap(rows, limit)
    if as_json:
        _out(json.dumps({"symbol": name, "definitions": shown, "hidden": hidden}, indent=2))
        return EXIT_OK
    _out("# file:span\tkind\tname\tlang")
    for s in shown:
        _tab(_span(s["f"], s["a"], s["b"]), s["k"], s["n"], s["l"])
    _emit_more(hidden)
    return EXIT_OK


def cmd_refs(index, name, as_json, limit):
    rows = sg.q_refs(index, name)
    if not rows:
        return _not_indexed("symbol", name, index)
    shown, hidden = sg.cap(rows, limit)
    if as_json:
        _out(json.dumps({"symbol": name, "refs": shown, "hidden": hidden}, indent=2))
        return EXIT_OK
    _out("# file:line\tedge\tin")
    for r in shown:
        _tab("%s%s:%d" % (_mark(r["kind"]), r["file"], r["line"]), r["kind"], r["scope"])
    _emit_more(hidden)
    return EXIT_OK


def cmd_callers(index, name, as_json, limit):
    if not sg.q_def(index, name) and not sg.q_refs(index, name):
        return _not_indexed("symbol", name, index)
    rows = sg.q_callers(index, name)
    shown, hidden = sg.cap(rows, limit)
    if as_json:
        _out(json.dumps({"symbol": name, "callers": shown, "hidden": hidden,
                         "limitations": index["limitations"]}, indent=2))
        return EXIT_OK
    _out("# call-site\tcaller\tcaller-def")
    for r in shown:
        _tab("%s%s:%d" % (_mark(r["edge"], r["ambiguous"]), r["file"], r["line"]),
             r["caller"], _span(r["caller_file"], r["caller_span"][0], r["caller_span"][1]))
    _emit_more(hidden)
    if not rows:
        _out("# 0 known callers — see `impact` for what a static index cannot see")
    return EXIT_OK


def cmd_callees(index, name, as_json, limit):
    if not sg.q_def(index, name):
        return _not_indexed("symbol", name, index)
    rows = sg.q_callees(index, name)
    shown, hidden = sg.cap(rows, limit)
    if as_json:
        _out(json.dumps({"symbol": name, "callees": shown, "hidden": hidden}, indent=2))
        return EXIT_OK
    _out("# call-site\tcallee\tstatus")
    for r in shown:
        _tab("%s%s:%d" % (_mark(r["edge"], r["ambiguous"]), r["file"], r["line"]),
             r["callee"], "resolved" if r["resolved"] else "external")
    _emit_more(hidden)
    return EXIT_OK


def cmd_impact(index, name, as_json, limit):
    if not sg.q_def(index, name) and not sg.q_refs(index, name):
        return _not_indexed("symbol", name, index)
    rows = sg.q_impact(index, name)
    unique = len({r["name"] for r in rows})
    max_depth = max([r["depth"] for r in rows], default=0)
    shown, hidden = sg.cap(rows, limit)
    if as_json:
        _out(json.dumps({
            "symbol": name,
            "known_callers": shown,
            "hidden": hidden,
            "unique_symbols": unique,
            "max_depth": max_depth,
            "exhaustive": False,
            "limitations": index["limitations"],
        }, indent=2))
        return EXIT_OK
    _out("# impact %s — %d known caller site(s), %d unique symbol(s), max depth %d"
         % (name, len(rows), unique, max_depth))
    _out("# depth\tcaller\tcaller-def\tvia")
    for r in shown:
        _tab(r["depth"], "%s%s" % (_mark(r["edge"], r["ambiguous"]), r["name"]),
             _span(r["file"], r["span"][0], r["span"][1]), r["via"])
    _emit_more(hidden)
    _emit_limits()
    return EXIT_OK


def cmd_outline(index, path_arg, as_json, limit):
    rel = _rel_to_repo(index["repo"], path_arg)
    rows = sg.q_outline(index, rel)
    if not rows:
        if not sg.known_file(index, rel):
            return _not_indexed("file", rel, index)
        return EXIT_OK
    shown, hidden = sg.cap(rows, limit)
    if as_json:
        _out(json.dumps({"file": rel, "symbols": shown, "hidden": hidden}, indent=2))
        return EXIT_OK
    _out("# span\tkind\tname\t(read only the span you need)")
    for s in shown:
        _tab("%d-%d" % (s["a"], s["b"]), s["k"], s["n"])
    _emit_more(hidden)
    return EXIT_OK


SYMBOL_COMMANDS = {
    "def": cmd_def,
    "refs": cmd_refs,
    "callers": cmd_callers,
    "callees": cmd_callees,
    "impact": cmd_impact,
    "outline": cmd_outline,
}
REPO_COMMANDS = {
    "index": cmd_index,
    "status": cmd_status,
}


def main(argv):
    """argv: <cmd> <repo> <limit> <json:0|1> [<arg>]  — normalised by the wrapper."""
    cmd, repo, limit_s, json_s = argv[0], argv[1], argv[2], argv[3]
    arg = argv[4] if len(argv) > 4 else ""
    limit = int(limit_s)
    as_json = json_s == "1"

    force = cmd == "index"
    index, freshness = sg.load_index(repo, force=force)

    if cmd in REPO_COMMANDS:
        return REPO_COMMANDS[cmd](index, freshness, as_json, limit)
    return SYMBOL_COMMANDS[cmd](index, arg, as_json, limit)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
