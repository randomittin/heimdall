#!/usr/bin/env bash
# test/skills-lock.test.sh -- bin/lib/skills_lock.py, the skills lockfile library (3.x M1 plan, task T0.4).
#
# A lock records what hmd installed or suggested and WHY: .planning/skills.lock per project (git-committed) and
# $HEIMDALL_HOME/skills.lock per machine. Two facts shape every case below. The project file is COMMITTED, so it must
# never hold prompt text (INV-S10); and a cloned repo SUPPLIES it, so the library reads it as untrusted input. The
# library is called from fail-open launchers: it speaks through its exit code and never through a traceback.
#
# THE CONTRACT UNDER TEST
#   A  write + read roundtrip: every field, a fixed key order, one row per line, the file's bytes == `read`'s output
#   B  append-only per (id, scope) with state transitions: rows survive, installed never goes back, a no-op writes nothing
#   C  evidence: cut to 64, control and format characters stripped, and the API has no prompt flag at all (INV-S10)
#   D  the machine scope, the project dir, the run id, the cleaned descriptive fields, an unwritable directory
#   E  concurrency: 20 parallel writers keep every row; the advisory lock blocks, times out, and lets go
#   F  corrupt and hostile files: exit 1 with a reason and no traceback; `record` never overwrites one
#   G  docs/schemas/skills.lock.v1.json agrees with the code (enums, caps, patterns) and a small schema walker (no
#      jsonschema dependency) rejects what `verify` rejects
#   H  the suite can go RED: eight one-line breaks of the library are each caught by the check that guards them
#
# HERMETIC. HOME and HEIMDALL_HOME are throwaway directories; nothing is installed, no network, no real lock is touched.
# EXIT: 0 = every assertion passes; 1 = any FAIL.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/lib/skills_lock.py"
SCHEMA="$REPO/docs/schemas/skills.lock.v1.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
t()   { if [ "$?" -eq 0 ]; then ok "$1"; else bad "$1" "${2:-}"; fi; }   # the verdict of the command list just before it

echo "skills-lock"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required"; exit 1; }
if [ ! -f "$LIB" ]; then
  bad "0. bin/lib/skills_lock.py is missing"
  echo; echo "skills-lock: $PASS passed, $FAIL failed"
  exit 1
fi

# ── sandbox ──────────────────────────────────────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d /tmp/test-skills-lock-XXXXXX)" || exit 1
HOLDER_PID=""
release() {  # let go of the lock a `hold` took: kill its holder
  if [ -n "$HOLDER_PID" ]; then kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""; fi
  return 0
}
trap 'release; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# The REAL interpreter first on PATH: a version-manager shim costs ~0.4 s a call and this suite starts python ~200 times.
REALPY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
if [ -z "$REALPY" ] || [ ! -x "$REALPY" ]; then echo "FATAL: no usable python3"; exit 1; fi
mkdir -p "$TMP/pybin" "$TMP/py" "$TMP/rc" "$TMP/bad" "$TMP/mut"
ln -s "$REALPY" "$TMP/pybin/python3"
PATH="$TMP/pybin:$PATH"; export PATH

export HOME="$TMP/home" HEIMDALL_HOME="$TMP/home/.heimdall"
mkdir -p "$HOME"
unset HMD_RUN_ID HMD_SKILLS_LOCK_WAIT_S WORK_DIR

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────────────
RC=0; OUT=""; ERR=""
lock() {  # lock ARGS... -> RC, OUT, ERR (and the status); the library under test is $LIB
  OUT="$(python3 -I "$LIB" "$@" 2>"$TMP/stderr" </dev/null)"; RC=$?
  ERR="$(cat "$TMP/stderr")"
  return "$RC"
}
contains() { grep -qF -- "$2" <<<"$1"; }
newproj()  { mktemp -d "$TMP/proj.XXXXXX"; }
# jf FILE EXPR -> EXPR evaluated with d = the JSON in FILE. EXPR is always a literal written in THIS file (never data read
# from the sandbox), which is why eval is safe here: it is the shortest way to ask a lock one question per assertion.
jf()       { python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$1" "$2"; }
sha()      { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
modeof()   { python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
AT=2026-11-12T10:00:00Z
rec()      { local p="$1"; shift; lock record --scope project --project-dir "$p" "$@"; }   # rec PROJECT ARGS...

MANIFEST="$TMP/skills.manifest.json"
printf '{"schema": 1, "entries": []}\n' >"$MANIFEST"
FULL=(--kind plugin --ref frontend-design@claude-plugins-official --version 5.0.7 --source anthropics/claude-plugins-official
      --pin none --consent prompt --entry frontend-design --rule prompt_ere --evidence react --via prompt-preinstall
      --run run-1 --manifest "$MANIFEST" --at "$AT")

hold() {  # hold DIR SECONDS: a background process takes DIR's advisory lock and keeps it; returns once it holds it
  local fifo="$TMP/ready.$$.$RANDOM"
  mkfifo "$fifo"
  python3 -I -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
fcntl.flock(fd, fcntl.LOCK_EX)
sys.stdout.write("locked\n")
sys.stdout.flush()
time.sleep(float(sys.argv[2]))' "$1" "$2" >"$fifo" &
  HOLDER_PID=$!
  read -r _ <"$fifo"
  rm -f "$fifo"
}

# ── python helpers (files, not heredocs inside $(): bash 3.2 mis-parses those) ───────────────────────────────────
cat >"$TMP/py/roundtrip.py" <<'PY'
import json, sys
path, digest = sys.argv[1:3]
raw = open(path, "rb").read()
doc = json.loads(raw)
row = {"id": "frontend-design", "kind": "plugin", "ref": "frontend-design@claude-plugins-official", "state": "installed",
       "version": "5.0.7", "source": "anthropics/claude-plugins-official", "pin": "none", "content_hash": None,
       "consent": "prompt", "at": "2026-11-12T10:00:00Z",
       "why": {"entry": "frontend-design", "rule": "prompt_ere", "evidence": "react", "via": "prompt-preinstall", "run": "run-1"}}
bad = []
if doc != {"schema": 1, "manifest_sha256": digest, "entries": [row]}:
    bad.append("the values differ: %r" % (doc,))
if list(doc) != ["schema", "manifest_sha256", "entries"]:
    bad.append("top-level key order is %r" % (list(doc),))
if list(doc["entries"][0]) != list(row):
    bad.append("row key order is %r" % (list(doc["entries"][0]),))
if list(doc["entries"][0]["why"]) != list(row["why"]):
    bad.append("why key order is %r" % (list(doc["entries"][0]["why"]),))
if raw.count(b"\n") != 6 + len(doc["entries"]):
    bad.append("layout: %d lines for %d row(s), want one line per row plus 6" % (raw.count(b"\n"), len(doc["entries"])))
try:
    raw.decode("ascii")
except UnicodeDecodeError:
    bad.append("the file is not ASCII")
if not raw.endswith(b"\n"):
    bad.append("no final newline")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY

cat >"$TMP/py/unit.py" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("skills_lock", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
bad = []


def want(label, got, expected):
    if got != expected:
        bad.append("%s: got %r, want %r" % (label, got, expected))


# evidence: control, format, separator and surrogate characters go; ordinary non-ASCII stays; 64 code points at most
want("tab, newline, ESC, BEL", lib.clean_evidence("a\tb\nc\x1bd\x07e"), "abcde")
want("bidi override", lib.clean_evidence("a‮b"), "ab")
want("line and paragraph separators", lib.clean_evidence("a b c"), "abc")
want("zero width joiner", lib.clean_evidence("a‍b"), "ab")
want("lone surrogate (argv bytes that are not UTF-8)", lib.clean_evidence("a\udc80b"), "ab")
want("a non-ASCII path stays", lib.clean_evidence("src/日本語.tsx"), "src/日本語.tsx")
want("trimmed", lib.clean_evidence("  react  "), "react")
want("cut at 64", lib.clean_evidence("x" * 100), "x" * 64)
want("cut, then trimmed", lib.clean_evidence("x" * 63 + " yyy"), "x" * 63)
want("only controls", lib.clean_evidence("\x00\x01\n"), "")
# the other free-text fields: printable ASCII, anything else becomes '?', cut to the cap
want("ascii_text", lib.ascii_text("5.0\x01.7é ", 64), "5.0?.7?")
want("ascii_text cut", lib.ascii_text("a" * 300, 200), "a" * 200)
# the transition table, written out here from the documented rules (not derived from the code)
allowed = {"suggested": set(lib.STATES), "declined": set(lib.STATES), "failed": set(lib.STATES),
           "installed": {"installed"}, "adopted": {"adopted", "installed"}}
want("the five states", sorted(lib.STATES), sorted(allowed))
for old in lib.STATES:
    for new in lib.STATES:
        want("transition %s -> %s" % (old, new), lib.transition_ok(old, new), new in allowed[old])
# the lock wait: only a finite number of seconds from 0 to 60 is honoured, anything else is the default
for value, expected in (("", 10.0), ("abc", 10.0), ("nan", 10.0), ("inf", 10.0), ("-1", 10.0), ("61", 10.0),
                        ("0.3", 0.3), ("0", 0.0), ("60", 60.0)):
    os.environ["HMD_SKILLS_LOCK_WAIT_S"] = value
    want("lock_wait(%r)" % value, lib.lock_wait(), expected)
del os.environ["HMD_SKILLS_LOCK_WAIT_S"]
want("lock_wait unset", lib.lock_wait(), 10.0)
# the canonical text is ASCII even for a non-ASCII evidence, and parses back to the same document
row = {"id": "a", "kind": "plugin", "ref": "a", "state": "suggested", "version": "unknown", "source": "unknown", "pin": "none",
       "content_hash": None, "consent": "n/a", "at": "2026-11-12T10:00:00Z",
       "why": {"entry": "a", "rule": "unspecified", "evidence": "src/日本語.tsx", "via": "unspecified", "run": "manual"}}
doc = {"schema": 1, "manifest_sha256": None, "entries": [row]}
text = lib.dump(doc)
want("dump is ASCII", text.isascii(), True)
want("dump parses back", json.loads(text), doc)
want("a non-ASCII evidence is a valid row", lib.problems(doc), [])
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY

cat >"$TMP/py/mkbad.py" <<'PY'
import json, os, sys
base, out = sys.argv[1], sys.argv[2]
raw = open(base, "rb").read()
index = []


def put(name, data, keyword, structural):
    with open(os.path.join(out, name + ".lock"), "wb") as handle:
        handle.write(data)
    index.append("%s\t%s\t%s" % (name, keyword, "y" if structural else "n"))


def edit(mutate):
    doc = json.loads(raw)
    mutate(doc)
    return (json.dumps(doc) + "\n").encode()


def row(doc):
    return doc["entries"][0]


put("garbage", b"not json at all\n", "not valid JSON", False)
put("empty", b"", "not valid JSON", False)
put("truncated", raw[: len(raw) // 2], "not valid JSON", False)
put("non-utf8", b"\xff\xfe{}", "not valid JSON", False)
put("nan", raw.replace(b'"schema": 1', b'"schema": NaN', 1), "not valid JSON", False)
put("duplicate-json-key", raw.replace(b'"state": "installed"', b'"state": "installed", "state": "suggested"', 1),
    "duplicate key", False)
put("too-big", b" " * (2 << 20), "larger than", False)
put("deep-nesting", b"[" * 100000 + b"]" * 100000, "not valid JSON", False)
put("array-top", b"[]\n", "not an object", True)
put("schema-2", edit(lambda d: d.update(schema=2)), "schema", True)
put("schema-true", edit(lambda d: d.update(schema=True)), "schema", True)
put("top-extra-key", edit(lambda d: d.update(extra=1)), "unexpected key", True)
put("no-entries", edit(lambda d: d.pop("entries")), "missing key", True)
put("bad-manifest-sha", edit(lambda d: d.update(manifest_sha256="abc")), "manifest_sha256", True)
put("bad-id", edit(lambda d: row(d).update(id="has space")), "entries[0].id", True)
put("bad-state", edit(lambda d: row(d).update(state="bogus")), "entries[0].state", True)
put("bad-hash", edit(lambda d: row(d).update(content_hash="xyz")), "entries[0].content_hash", True)
put("non-ascii-version", edit(lambda d: row(d).update(version="5.0é")), "entries[0].version", True)
put("row-extra-key", edit(lambda d: row(d).update(extra=1)), "unexpected key", True)
put("why-missing-rule", edit(lambda d: row(d)["why"].pop("rule")), "missing key", True)
put("evidence-65", edit(lambda d: row(d)["why"].update(evidence="a" * 65)), "entries[0].why.evidence", True)
put("evidence-control-char", edit(lambda d: row(d)["why"].update(evidence="a\u0007b")), "entries[0].why.evidence", False)
put("at-30-february", edit(lambda d: row(d).update(at="2026-02-30T10:00:00Z")), "entries[0].at", False)
put("duplicate-id", edit(lambda d: d["entries"].append(dict(row(d)))), "duplicate id", False)
with open(os.path.join(out, "index.tsv"), "w") as handle:
    handle.write("\n".join(index) + "\n")
PY

cat >"$TMP/py/walk.py" <<'PY'
# A small JSON Schema walker: exit 0 when DOC satisfies SCHEMA, 1 when it does not, 2 when the schema uses a keyword it
# cannot enforce (a rule this walker cannot check must never pass silently). Only the keywords skills.lock.v1.json uses.
import json, re, sys
ANNOTATIONS = {"$schema", "$id", "$defs", "$comment", "title", "description", "default", "examples"}
ENFORCED = {"$ref", "type", "const", "enum", "required", "properties", "additionalProperties", "items",
            "minLength", "maxLength", "pattern"}
root = json.load(open(sys.argv[1]))
doc = json.load(open(sys.argv[2]))
errors = []


def is_type(value, name):
    return {"null": value is None, "string": isinstance(value, str), "object": isinstance(value, dict),
            "array": isinstance(value, list), "integer": type(value) is int, "boolean": isinstance(value, bool)}[name]


def check(value, schema, path):
    for key in schema:
        if key not in ENFORCED and key not in ANNOTATIONS and not key.startswith("x-"):
            print("unsupported keyword %s at %s" % (key, path))
            sys.exit(2)
    if "$ref" in schema:
        node = root
        for part in schema["$ref"][2:].split("/"):
            node = node[part]
        return check(value, node, path)
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(is_type(value, name) for name in names):
            return errors.append("%s: wrong type" % path)
    if "const" in schema and not (type(value) is type(schema["const"]) and value == schema["const"]):
        errors.append("%s: not the constant" % path)
    if "enum" in schema and value not in schema["enum"]:
        errors.append("%s: not in the enum" % path)
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append("%s: too short" % path)
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append("%s: too long" % path)
        if "pattern" in schema and not re.search(re.sub(r"\$$", r"\\Z", schema["pattern"]), value):
            errors.append("%s: does not match the pattern" % path)
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append("%s: missing %s" % (path, key))
        for key, item in value.items():
            if key in schema.get("properties", {}):
                check(item, schema["properties"][key], "%s.%s" % (path, key))
            elif schema.get("additionalProperties") is False:
                errors.append("%s: unexpected %s" % (path, key))
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            check(item, schema["items"], "%s[%d]" % (path, index))


check(doc, root, "$")
print("\n".join(errors))
sys.exit(1 if errors else 0)
PY

cat >"$TMP/py/drift.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("skills_lock", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
schema = json.load(open(sys.argv[2]))
defs = schema["$defs"]
entry, why = defs["entry"], defs["why"]
bad = []


def want(label, in_schema, in_code):
    if in_schema != in_code:
        bad.append("%s: the schema says %r, the code says %r" % (label, in_schema, in_code))


def resolved(node):
    return defs[node["$ref"].rsplit("/", 1)[1]] if "$ref" in node else node


want("schema const", schema["properties"]["schema"]["const"], lib.SCHEMA)
want("top-level required", schema["required"], list(lib.TOP_FIELDS))
want("entry required", entry["required"], list(lib.ROW_FIELDS))
want("why required", why["required"], list(lib.WHY_FIELDS))
want("state enum", entry["properties"]["state"]["enum"], list(lib.STATES))
want("kind enum", entry["properties"]["kind"]["enum"], list(lib.KINDS))
want("consent enum", entry["properties"]["consent"]["enum"], list(lib.CONSENTS))
want("id pattern", defs["id"]["pattern"], "^" + lib.ID_RE.pattern + "$")
want("manifest_sha256 pattern", schema["properties"]["manifest_sha256"]["pattern"], "^" + lib.SHA256_RE.pattern + "$")
want("content_hash pattern", entry["properties"]["content_hash"]["pattern"], "^" + lib.HASH_RE.pattern + "$")
want("at pattern", entry["properties"]["at"]["pattern"], "^" + lib.AT_RE.pattern + "$")
want("evidence cap", why["properties"]["evidence"]["maxLength"], lib.EVIDENCE_MAX)
want("why.entry is an id", resolved(why["properties"]["entry"]), defs["id"])
for key, cap in lib.CAPS.items():
    node = resolved((why if key in lib.WHY_FIELDS else entry)["properties"][key])
    want("%s cap" % key, node["maxLength"], cap)
    want("%s pattern" % key, node["pattern"], "^" + lib.TEXT_RE.pattern + "$")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY

# ── the checks the mutants (section H) are run against: each returns 0 when the property holds ─────────────────────
chk_cap() {  # a 500-character evidence is stored as its first 64 characters
  local p long; p="$(newproj)"
  long="$(python3 -I -c 'print("a" * 500)')"
  rec "$p" --id a --kind plugin --state suggested --at "$AT" --evidence "$long" || return 1
  [ "$(jf "$p/.planning/skills.lock" 'd["entries"][0]["why"]["evidence"] == "a" * 64')" = True ]
}
chk_ctrl() {  # control characters never reach the file
  local p; p="$(newproj)"
  rec "$p" --id a --kind plugin --state suggested --at "$AT" --evidence $'react\n\033[31mred\a' || return 1
  [ "$(jf "$p/.planning/skills.lock" 'd["entries"][0]["why"]["evidence"]')" = 'react[31mred' ]
}
chk_transition() {  # installed does not go back to suggested: exit 3, the file is not touched
  local p f; p="$(newproj)"; f="$p/.planning/skills.lock"
  rec "$p" --id a --kind plugin --state installed --at "$AT" || return 1
  cp "$f" "$p/before"
  rec "$p" --id a --state suggested --at "$AT"
  [ "$RC" -eq 3 ] && cmp -s "$f" "$p/before"
}
chk_noop() {  # a record that changes nothing writes nothing: no at / run churn in a committed file
  local p f; p="$(newproj)"; f="$p/.planning/skills.lock"
  rec "$p" --id a --kind plugin --state suggested --rule prompt_ere --evidence react --run r1 --at 2026-11-12T10:00:00Z || return 1
  cp "$f" "$p/before"
  rec "$p" --id a --state suggested --rule prompt_ere --evidence react --run r2 --at 2026-11-13T11:00:00Z || return 1
  cmp -s "$f" "$p/before"
}
chk_sorted() {  # rows are sorted by id whatever the order they arrived in
  local p id; p="$(newproj)"
  for id in zeta alpha mid; do rec "$p" --id "$id" --kind plugin --state suggested --at "$AT" || return 1; done
  [ "$(jf "$p/.planning/skills.lock" '",".join(r["id"] for r in d["entries"])')" = alpha,mid,zeta ]
}
chk_corrupt() {  # a lock that parses but is invalid is refused (exit 1) and never overwritten
  local p f; p="$(newproj)"; f="$p/.planning/skills.lock"
  rec "$p" --id a --kind plugin --state installed --at "$AT" || return 1
  python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
d["entries"][0]["state"] = "bogus"
open(sys.argv[1], "w").write(json.dumps(d))' "$f"
  cp "$f" "$p/before"
  rec "$p" --id b --kind plugin --state suggested --at "$AT"
  [ "$RC" -eq 1 ] && cmp -s "$f" "$p/before" && ! contains "$ERR" Traceback
}
chk_symlink() {  # a lock that is a symbolic link is refused, and the link and its target are left alone
  local p q; p="$(newproj)"; q="$(newproj)"
  rec "$q" --id a --kind plugin --state installed --at "$AT" || return 1
  mkdir -p "$p/.planning"; ln -s "$q/.planning/skills.lock" "$p/.planning/skills.lock"
  cp "$q/.planning/skills.lock" "$q/before"
  lock read --scope project --project-dir "$p"
  [ "$RC" -eq 1 ] && contains "$ERR" "symbolic link" || return 1
  rec "$p" --id b --kind plugin --state suggested --at "$AT"
  [ "$RC" -eq 1 ] && [ -L "$p/.planning/skills.lock" ] && cmp -s "$q/.planning/skills.lock" "$q/before"
}
chk_lock() {  # while another process holds the directory's lock, record gives up (exit 1) and writes nothing; after it lets go, record works
  local p f rc=1; p="$(newproj)"; f="$p/.planning/skills.lock"; mkdir -p "$p/.planning"
  hold "$p/.planning" 30
  export HMD_SKILLS_LOCK_WAIT_S=0.3
  rec "$p" --id a --kind plugin --state suggested --at "$AT"
  unset HMD_SKILLS_LOCK_WAIT_S
  if [ "$RC" -eq 1 ] && [ ! -e "$f" ] && contains "$ERR" locked; then
    release
    if rec "$p" --id a --kind plugin --state suggested --at "$AT" && [ -f "$f" ]; then rc=0; fi
  else
    release
  fi
  return "$rc"
}
chk_lock_waits() {  # a writer that starts while the lock is held waits for it (up to the wait) and then writes
  local p rc=1; p="$(newproj)"; mkdir -p "$p/.planning"
  hold "$p/.planning" 0.6
  export HMD_SKILLS_LOCK_WAIT_S=10
  rec "$p" --id a --kind plugin --state suggested --at "$AT"
  unset HMD_SKILLS_LOCK_WAIT_S
  if [ "$RC" -eq 0 ] && [ -f "$p/.planning/skills.lock" ]; then rc=0; fi
  release
  return "$rc"
}

# ── 0. the library and the schema exist and parse ────────────────────────────────────────────────────────────────
python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$LIB" 2>/dev/null
t "0a. bin/lib/skills_lock.py parses"
[ "$(head -n 1 "$LIB")" = '#!/usr/bin/env python3' ]
t "0b. it starts with the python3 shebang the other bin/lib modules use"
python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$SCHEMA" 2>/dev/null
t "0c. docs/schemas/skills.lock.v1.json is valid JSON"

# ── A. write + read roundtrip ────────────────────────────────────────────────────────────────────────────────────
echo "A. write + read roundtrip"
P="$(newproj)"; F="$P/.planning/skills.lock"
lock record --scope project --project-dir "$P" --id frontend-design --state installed "${FULL[@]}"
[ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ] && [ -f "$F" ]
t "A1. record exits 0, says nothing, writes <project>/.planning/skills.lock" "rc=$RC out=$OUT err=$ERR"
D="$(python3 -I "$TMP/py/roundtrip.py" "$F" "$(sha "$MANIFEST")" 2>&1)"
t "A2. every field round-trips; fixed key order; one row per line; ASCII; final newline" "$D"
lock read --scope project --project-dir "$P"
[ "$RC" -eq 0 ] && [ "$OUT" = "$(cat "$F")" ]
t "A3. read prints exactly the bytes of the file" "rc=$RC"
lock read --scope project --project-dir "$P" --id frontend-design
[ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["state"])')" = installed ] \
  && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ]
t "A4. read --id prints that one row, on one line" "rc=$RC out=$OUT"
lock read --scope project --project-dir "$P" --id no-such-id
[ "$RC" -eq 4 ] && [ -z "$OUT" ] && [ -n "$ERR" ]
t "A5. read --id of an id with no row exits 4 and says so" "rc=$RC err=$ERR"
lock verify --scope project --project-dir "$P"
[ "$RC" -eq 0 ] && contains "$OUT" "ok " && contains "$OUT" "1 entries"
t "A6. verify of that lock exits 0" "rc=$RC out=$OUT err=$ERR"
PE="$(newproj)"
lock verify --scope project --project-dir "$PE"
[ "$RC" -eq 0 ] && contains "$OUT" absent && [ ! -e "$PE/.planning" ]
t "A7. verify of a project with no lock yet exits 0 (absent), and creates nothing" "rc=$RC out=$OUT"
lock read --scope project --project-dir "$PE"
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 5 ] && contains "$OUT" '"entries": []' && [ ! -e "$PE/.planning" ]
t "A8. read of a project with no lock prints the empty document, and creates nothing" "rc=$RC out=$OUT"
printf '%s\n' "$OUT" >"$TMP/empty.lock"
[ "$(modeof "$F")" = 644 ]
t "A9. a project lock is written 0644 (it is committed)" "mode=$(modeof "$F")"
PLUGIN="$TMP/plugin"; mkdir -p "$PLUGIN/bin/lib"
cp "$LIB" "$PLUGIN/bin/lib/skills_lock.py"
printf '{"schema": 1, "marker": "default-location"}\n' >"$PLUGIN/skills.manifest.json"
P2="$(newproj)"
python3 -I "$PLUGIN/bin/lib/skills_lock.py" record --scope project --project-dir "$P2" --id a --kind plugin --state suggested --at "$AT"
[ "$(jf "$P2/.planning/skills.lock" 'd["manifest_sha256"]')" = "$(sha "$PLUGIN/skills.manifest.json")" ]
t "A10. without --manifest the recorded hash is that of <lib>/../../skills.manifest.json"
P3="$(newproj)"
rec "$P3" --id a --kind plugin --state suggested --at "$AT" --manifest "$TMP/no-such-manifest.json"
[ "$RC" -eq 0 ] && [ "$(jf "$P3/.planning/skills.lock" 'd["manifest_sha256"]')" = None ]
t "A11. a manifest that cannot be read is recorded as null; the write still succeeds" "rc=$RC err=$ERR"

# ── B. append-only per (id, scope), with state transitions ───────────────────────────────────────────────────────
echo "B. append-only per (id, scope), with state transitions"
PB="$(newproj)"; FB="$PB/.planning/skills.lock"
rec "$PB" --id frontend-design --state suggested --kind plugin --ref frontend-design@claude-plugins-official --rule prompt_ere \
  --evidence react --via prompt-preinstall --entry frontend-design --run run-1 --at 2026-11-12T10:00:00Z
rec "$PB" --id frontend-design --state installed --version 5.0.7 --consent prompt --via hmd-skills-install --run run-2 \
  --at 2026-11-12T11:00:00Z
[ "$RC" -eq 0 ] && [ "$(jf "$FB" '[str(len(d["entries"])) + "|" + "|".join([r["state"], r["version"], r["consent"], r["why"]["via"], r["why"]["rule"], r["why"]["evidence"], r["at"], r["why"]["run"], r["kind"], r["ref"]]) for r in d["entries"]][0]')" \
  = "1|installed|5.0.7|prompt|hmd-skills-install|prompt_ere|react|2026-11-12T11:00:00Z|run-2|plugin|frontend-design@claude-plugins-official" ]
t "B1. suggested -> installed is one row: the fields given replace, the ones omitted stay, at and run move" "rc=$RC err=$ERR"
rec "$PB" --id zz-second --kind github-skill --state suggested --at "$AT"
rec "$PB" --id aa-first --kind marketplace --state suggested --at "$AT"
rec "$PB" --id frontend-design --state installed --version 5.0.8 --at 2026-11-13T09:00:00Z
[ "$(jf "$FB" '",".join(r["id"] for r in d["entries"])')" = aa-first,frontend-design,zz-second ] \
  && [ "$(jf "$FB" 'sorted(r["state"] for r in d["entries"])')" = "['installed', 'suggested', 'suggested']" ] \
  && [ "$(jf "$FB" 'd["entries"][1]["version"]')" = 5.0.8 ]
t "B2. rows are appended, never dropped; another id's record leaves the others alone; a re-install refreshes the version"
rec "$PB" --id dd --kind plugin --state declined --at "$AT"
rec "$PB" --id dd --state suggested --at "$AT"
[ "$RC" -eq 0 ] && [ "$(jf "$FB" '[r["state"] for r in d["entries"] if r["id"] == "dd"][0]')" = suggested ]
t "B3. declined -> suggested (hmd skills suggest --reset) is allowed" "rc=$RC err=$ERR"
rec "$PB" --id ad --kind plugin --state adopted --consent auto-legacy --at "$AT"
rec "$PB" --id ad --state installed --consent explicit --at "$AT"
[ "$RC" -eq 0 ] && [ "$(jf "$FB" '[r["state"] for r in d["entries"] if r["id"] == "ad"][0]')" = installed ]
t "B4. adopted -> installed is allowed" "rc=$RC err=$ERR"
rec "$PB" --id ad --state adopted --at "$AT"
[ "$RC" -eq 3 ] && contains "$ERR" "installed" && [ "$(jf "$FB" '[r["state"] for r in d["entries"] if r["id"] == "ad"][0]')" = installed ]
t "B5. installed -> adopted is refused: exit 3, the reason on stderr, the row unchanged" "rc=$RC err=$ERR"
chk_transition
t "B6. installed -> suggested is refused: exit 3 and the file is not touched"
rec "$PB" --id brand-new --state suggested --at "$AT"
[ "$RC" -eq 2 ] && contains "$ERR" "--kind" && [ "$(jf "$FB" 'sum(1 for r in d["entries"] if r["id"] == "brand-new")')" = 0 ]
t "B7. a new id needs --kind (exit 2); nothing is written" "rc=$RC err=$ERR"
chk_sorted
t "B8. rows are sorted by id whatever order they arrived in"
chk_noop
t "B9. a record that changes nothing writes nothing (the bytes are identical)"
D="$(python3 -I "$TMP/py/unit.py" "$LIB" 2>&1)"
t "B10. the transition table (all 25 pairs), the cleaners, the lock-wait parser and the ASCII dump" "$D"
lock verify --scope project --project-dir "$PB"
[ "$RC" -eq 0 ] && contains "$OUT" "5 entries"
t "B11. the lock all of this wrote verifies" "rc=$RC out=$OUT err=$ERR"

# ── C. evidence is a matched token or a path: cut, cleaned, and there is no prompt flag ─────────────────────────────
echo "C. evidence (INV-S10)"
chk_cap
t "C1. a 500-character evidence is stored as exactly 64 characters"
chk_ctrl
t "C2. newline, ESC and BEL are stripped from the evidence"
PC="$(newproj)"; FC="$PC/.planning/skills.lock"
PROMPT="Please build me a big React dashboard with login, then deploy it to Kubernetes and write the SQL migrations for the orders table, SECRETMARKER and after that email the team a summary of everything you did today"
rec "$PC" --id a --kind plugin --state suggested --at "$AT" --evidence "$PROMPT"
[ "$RC" -eq 0 ] && [ "$(jf "$FC" 'len(d["entries"][0]["why"]["evidence"])')" = 64 ] \
  && [ "$(jf "$FC" 'd["entries"][0]["why"]["evidence"] == "'"${PROMPT:0:64}"'".rstrip()')" = True ] && ! grep -q SECRETMARKER "$FC"
t "C3. a prompt-shaped evidence is cut to its first 64 characters; the rest of the text is nowhere in the file" "rc=$RC"
rec "$PC" --id b --kind plugin --state suggested --at "$AT" --prompt "$PROMPT"
[ "$RC" -eq 2 ] && [ "$(jf "$FC" 'len(d["entries"])')" = 1 ]
t "C4. record has no --prompt flag: it is refused (exit 2) and nothing is written" "rc=$RC err=$ERR"
lock record --help
[ "$RC" -eq 0 ] && contains "$OUT" "--evidence" && ! contains "$OUT" "--prompt"
t "C5. record --help offers --evidence and no prompt option" "rc=$RC"
rec "$PC" --id c --kind plugin --state suggested --at "$AT" --evidence $'\n\t '
[ "$RC" -eq 0 ] && [ "$(jf "$FC" '[r["why"]["evidence"] for r in d["entries"] if r["id"] == "c"][0]')" = None ]
t "C6. an evidence of nothing but control characters and spaces is stored as null" "rc=$RC err=$ERR"
rec "$PC" --id a --state suggested --at "$AT" --evidence ""
[ "$RC" -eq 0 ] && [ "$(jf "$FC" '[r["why"]["evidence"] for r in d["entries"] if r["id"] == "a"][0]')" = None ]
t "C7. an empty --evidence clears the evidence (null)" "rc=$RC err=$ERR"

# ── D. machine scope, project dir, run id, cleaned fields ───────────────────────────────────────────────────────────
echo "D. scopes and fields"
FM="$HEIMDALL_HOME/skills.lock"
lock record --scope machine --id superpowers --kind plugin --state installed --ref superpowers@claude-plugins-official \
  --source anthropics/claude-plugins-official --consent auto-legacy --rule first-run --via first-run --run run-1 --at "$AT"
[ "$RC" -eq 0 ] && [ -f "$FM" ] && [ "$(modeof "$FM")" = 600 ] && [ "$(jf "$FM" 'd["entries"][0]["id"]')" = superpowers ]
t "D1. the machine scope writes \$HEIMDALL_HOME/skills.lock, created with the directory, mode 0600" "rc=$RC err=$ERR"
lock read --scope machine
[ "$RC" -eq 0 ] && contains "$OUT" superpowers && ! contains "$OUT" frontend-design
t "D2. the machine lock and the project locks are separate files" "rc=$RC"
H2="$TMP/h2"; mkdir -p "$H2"
( unset HEIMDALL_HOME; export HOME="$H2"; lock record --scope machine --id a --kind plugin --state suggested --at "$AT" )
[ -f "$H2/.heimdall/skills.lock" ]
t "D3. with HEIMDALL_HOME unset the machine lock is ~/.heimdall/skills.lock"
P4="$(newproj)"
( cd "$P4" && lock record --scope project --id a --kind plugin --state suggested --at "$AT" )
[ -f "$P4/.planning/skills.lock" ]
t "D4. --project-dir defaults to the working directory"
rec "$TMP/no-such-dir" --id a --kind plugin --state suggested --at "$AT"
[ "$RC" -eq 1 ] && contains "$ERR" "does not exist" && [ ! -e "$TMP/no-such-dir" ]
t "D5. a project directory that does not exist is an error (exit 1) and is not created" "rc=$RC err=$ERR"
P5="$(newproj)"
HMD_RUN_ID=run-42-7 rec "$P5" --id a --kind plugin --state suggested --at "$AT"
rec "$P5" --id b --kind plugin --state suggested --at "$AT"
[ "$(jf "$P5/.planning/skills.lock" '",".join(r["why"]["run"] for r in d["entries"])')" = run-42-7,manual ]
t "D6. why.run defaults to \$HMD_RUN_ID, else manual (the install receipt's own default)"
rec "$P5" --id c --kind plugin --state suggested
[ "$RC" -eq 0 ] && [ "$(jf "$P5/.planning/skills.lock" '[r["at"] for r in d["entries"] if r["id"] == "c"][0]')" != "" ] \
  && [[ "$(jf "$P5/.planning/skills.lock" '[r["at"] for r in d["entries"] if r["id"] == "c"][0]')" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
t "D7. without --at the time is now, in UTC, as YYYY-MM-DDTHH:MM:SSZ" "rc=$RC err=$ERR"
rec "$P5" --id d --kind plugin --state installed --at "$AT" --version $'5.0\001.7' --source "$(python3 -I -c 'print("s" * 300)')"
[ "$(jf "$P5/.planning/skills.lock" '[r["version"] for r in d["entries"] if r["id"] == "d"][0]')" = '5.0?.7' ] \
  && [ "$(jf "$P5/.planning/skills.lock" 'len([r["source"] for r in d["entries"] if r["id"] == "d"][0])')" = 200 ]
t "D8. the descriptive fields are cleaned like the install receipt's: non-printable -> ?, cut to the cap"
rec "$P5" --id "has space" --kind plugin --state suggested --at "$AT"
r1=$RC
rec "$P5" --id 'say"hi' --kind plugin --state suggested --at "$AT"
r2=$RC
rec "$P5" --id e --kind plugin --state installed --at "$AT" --content-hash zzz
r3=$RC
rec "$P5" --id e --kind plugin --state installed --at "$AT" --consent maybe
r4=$RC
rec "$P5" --id e --kind plugin --state installed --at "$AT" --at 2026-02-30T10:00:00Z
r5=$RC
[ "$r1" -eq 2 ] && [ "$r2" -eq 2 ] && [ "$r3" -eq 2 ] && [ "$r4" -eq 2 ] && [ "$r5" -eq 2 ]
t "D9. a bad id, content hash, consent or timestamp is a usage error (exit 2)" "rc=$r1 $r2 $r3 $r4 $r5"
rec "$P5" --id h --kind plugin --state installed --at "$AT" --content-hash 0123456789AB
rec "$P5" --id i --kind plugin --state installed --at "$AT" --content-hash unknown
[ "$(jf "$P5/.planning/skills.lock" '[r["content_hash"] for r in d["entries"] if r["id"] in ("h", "i")]')" = "['0123456789ab', None]" ]
t "D10. a git sha is stored lowercase; 'unknown' means no hash (null)"
P6="$(newproj)"; mkdir -p "$P6/.planning"; chmod 555 "$P6/.planning"
if [ "$(id -u)" -eq 0 ]; then
  ok "D11. (skipped as root: a read-only directory does not stop root)"
else
  rec "$P6" --id a --kind plugin --state suggested --at "$AT"
  [ "$RC" -eq 1 ] && [ -n "$ERR" ] && ! contains "$ERR" Traceback && [ ! -e "$P6/.planning/skills.lock" ]
  t "D11. an unwritable directory is exit 1 with one reason line, no traceback, and no stray temp file" "rc=$RC err=$ERR"
fi
chmod 755 "$P6/.planning"

# ── E. concurrency ───────────────────────────────────────────────────────────────────────────────────────────────
echo "E. concurrency"
PP="$(newproj)"
for i in $(seq -w 1 20); do
  ( python3 -I "$LIB" record --scope project --project-dir "$PP" --id "par-$i" --kind plugin --state suggested --at "$AT" \
      >"$TMP/rc/$i.out" 2>"$TMP/rc/$i.err" </dev/null; echo "$?" >"$TMP/rc/$i.rc" ) &
done
wait
[ "$(grep -lx 0 "$TMP"/rc/*.rc | wc -l | tr -d ' ')" = 20 ] && [ "$(cat "$TMP"/rc/*.out "$TMP"/rc/*.err | wc -c | tr -d ' ')" = 0 ]
t "E1. 20 parallel record calls all exit 0 and print nothing"
[ "$(jf "$PP/.planning/skills.lock" 'sorted(r["id"] for r in d["entries"]) == ["par-%02d" % i for i in range(1, 21)]')" = True ]
t "E2. ... and every one of the 20 rows is there (no lost update)"
lock verify --scope project --project-dir "$PP"
[ "$RC" -eq 0 ] && [ "$(ls -A "$PP/.planning")" = skills.lock ]
t "E3. ... the lock is valid JSON and no temp file is left behind" "rc=$RC err=$ERR files=$(ls -A "$PP/.planning")"
PM="$(newproj)"; rm -f "$TMP"/rc/*
for i in $(seq -w 1 10); do
  ( python3 -I "$LIB" record --scope project --project-dir "$PM" --id mix --kind plugin --state suggested --at "$AT" \
      >/dev/null 2>&1 </dev/null; echo "$?" >"$TMP/rc/s$i.rc" ) &
  ( python3 -I "$LIB" record --scope project --project-dir "$PM" --id mix --kind plugin --state installed --version "1.$i" --at "$AT" \
      >/dev/null 2>&1 </dev/null; echo "$?" >"$TMP/rc/i$i.rc" ) &
done
wait
[ "$(grep -lx 0 "$TMP"/rc/i*.rc | wc -l | tr -d ' ')" = 10 ] && [ "$(cat "$TMP"/rc/s*.rc | grep -cvx '[03]')" = 0 ] \
  && [ "$(jf "$PM/.planning/skills.lock" '"%d %s" % (len(d["entries"]), d["entries"][0]["state"])')" = "1 installed" ]
t "E4. 10 suggested and 10 installed for ONE id in parallel: every installed exits 0, a late suggested is refused (3), the row ends installed"
chk_lock
t "E5. while another process holds the directory's lock, record gives up (exit 1, names the lock) and writes nothing; after release it works"
chk_lock_waits
t "E6. a writer that starts while the lock is held waits for it and then writes"

# ── F. corrupt and hostile files ─────────────────────────────────────────────────────────────────────────────────
echo "F. corrupt and hostile files"
BAD="$TMP/bad"
D="$(python3 -I "$TMP/py/mkbad.py" "$F" "$BAD" 2>&1)"
t "F0. the corrupt variants are generated from a valid lock" "$D"
PF="$(newproj)"; mkdir -p "$PF/.planning"; FF="$PF/.planning/skills.lock"
while IFS=$'\t' read -r name keyword _; do
  cp "$BAD/$name.lock" "$FF"
  lock verify --scope project --project-dir "$PF"
  [ "$RC" -eq 1 ] && contains "$ERR" "$keyword" && ! contains "$ERR" Traceback
  t "F1. verify rejects $name: exit 1 naming '$keyword'" "rc=$RC err=$ERR"
done <"$BAD/index.tsv"
for name in garbage bad-state too-big deep-nesting non-utf8; do
  cp "$BAD/$name.lock" "$FF"
  before="$(sha "$FF")"
  lock read --scope project --project-dir "$PF"; r1=$RC; e1="$ERR"
  rec "$PF" --id zz --kind plugin --state suggested --at "$AT"; r2=$RC; e2="$ERR"
  [ "$r1" -eq 1 ] && [ "$r2" -eq 1 ] && [ -n "$e1" ] && [ -n "$e2" ] && ! contains "$e1$e2" Traceback && [ "$(sha "$FF")" = "$before" ]
  t "F2. read and record on $name exit 1 with a reason, no traceback, and the file is untouched" "rc=$r1/$r2 err=$e1 / $e2"
done
chk_corrupt
t "F3. record on a lock that parses but is invalid is refused (exit 1) and never overwrites it"
chk_symlink
t "F4. a lock that is a symbolic link is refused for read and record; the link and its target are untouched"

# ── G. the schema file and the code agree ───────────────────────────────────────────────────────────────────────────
echo "G. docs/schemas/skills.lock.v1.json"
D="$(python3 -I "$TMP/py/drift.py" "$LIB" "$SCHEMA" 2>&1)"
t "G1. the schema's required fields, enums, patterns and caps are the code's" "$D"
for doc in "$F" "$FB" "$FC" "$PP/.planning/skills.lock" "$FM" "$TMP/empty.lock"; do
  D="$(python3 -I "$TMP/py/walk.py" "$SCHEMA" "$doc" 2>&1)"
  t "G2. the schema accepts a lock the library wrote ($(basename "$(dirname "$doc")")/$(basename "$doc"))" "$D"
done
while IFS=$'\t' read -r name _ structural; do
  [ "$structural" = y ] || continue
  python3 -I "$TMP/py/walk.py" "$SCHEMA" "$BAD/$name.lock" >/dev/null 2>&1
  [ "$?" -eq 1 ]
  t "G3. the schema rejects $name, as verify does"
done <"$BAD/index.tsv"

# ── H. the suite can go RED: one-line breaks of the library, each caught ─────────────────────────────────────────────
echo "H. falsifiability"
MUT_TOTAL=0
MUT_CAUGHT=0
mutant() {  # mutant NAME CHECK OLD NEW: a copy of the library with OLD (found exactly once) replaced by NEW must fail CHECK
  local name="$1" check="$2"
  MUT_TOTAL=$((MUT_TOTAL + 1))
  mkdir -p "$TMP/mut/$name"
  if ! python3 -I - "$LIB" "$TMP/mut/$name/skills_lock.py" "$3" "$4" 2>"$TMP/mutate.err" <<'PY'
import sys
source, target, old, new = sys.argv[1:5]
text = open(source).read()
if text.count(old) != 1:
    sys.exit("the anchor is found %d times, want exactly once: %r" % (text.count(old), old))
open(target, "w").write(text.replace(old, new))
PY
  then
    bad "H. mutant $name could not be built" "$(cat "$TMP/mutate.err")"
  elif ( LIB="$TMP/mut/$name/skills_lock.py"; "$check" ) >/dev/null 2>&1; then
    bad "H. mutant $name SURVIVED: $check still passes"
  else
    MUT_CAUGHT=$((MUT_CAUGHT + 1)); ok "H. mutant $name is caught by $check"
  fi
}
mutant evidence-cap   chk_cap        'EVIDENCE_MAX = 64' 'EVIDENCE_MAX = 500'
mutant keep-controls  chk_ctrl       '[0] != "C"' '[0] != "Q"'
mutant any-transition chk_transition 'if old == new or old not in PRESENT:' 'if True:'
mutant no-lock        chk_lock       'fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)' 'pass'
mutant overwrite-bad  chk_corrupt    $'    if reasons:\n        raise LockError(' $'    if False:\n        raise LockError('
mutant unsorted       chk_sorted     'sorted(doc["entries"], key=lambda row: row["id"])' 'list(doc["entries"])'
mutant always-write   chk_noop       '    if stable(current) == before:' '    if False:'
mutant follow-links   chk_symlink    'NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)' 'NOFOLLOW = 0'
echo "  falsifiability score $MUT_CAUGHT/$MUT_TOTAL"
[ "$MUT_CAUGHT" -eq "$MUT_TOTAL" ] && [ "$MUT_TOTAL" -ge 8 ]
t "H. every mutant of the library is caught (score $MUT_CAUGHT/$MUT_TOTAL, at least 8)"

echo
echo "skills-lock: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
