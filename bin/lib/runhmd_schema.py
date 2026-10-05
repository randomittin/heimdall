#!/usr/bin/env python3
"""runhmd_schema -- validate runhmd documents against docs/schemas/runhmd.*.v1.json.

The schema FILES are the single source of the runhmd contracts: runhmd.verdict/1 (and the
runhmd.prove/1 envelope `hmd prove` emits) in runhmd.verdict.v1.json, runhmd.receipt/1 in
runhmd.receipt.v1.json. This module holds no copy of those rules: it loads the file and
enforces it. A document is checked against the file whose `x-documents` declares its
`schema` id. Two layers:

  1. structure  -- a small, stdlib-only subset of JSON Schema (2020-12): $ref (local, or a
                   sibling runhmd.*.json file in the schema's own directory so the receipt
                   schema shares the verdict vocabulary instead of copying it -- never a
                   URL, never fetched), type, const, enum, required, properties,
                   additionalProperties, items, minItems, maxItems, minLength, maxLength,
                   pattern, minimum, maximum. Any other validating keyword in the schema
                   file makes the whole schema UNUSABLE (exit 2): a rule this module
                   cannot enforce must never pass silently.
  2. invariants -- the cross-field rules JSON Schema cannot express (arithmetic, "the
                   verdict is derived"). They are listed in the schema's `x-invariants`
                   and implemented below under the same ids.

Usage:
  runhmd_schema.py validate [--schema PATH] [FILE|-]    FILE defaults to stdin
  -h, --help

Exit: 0 valid (prints `ok <schema id>` on stdout); 1 invalid (one error per line on
stderr); 2 usage / IO / unusable schema.

Python API (what `hmd attack`, `hmd prove` and `hmd receipt` import):
  load_schema(path=None) -> dict
  validate(doc, schema=None) -> list[str]        empty list == valid
"""
from __future__ import annotations

import datetime
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SCHEMA = os.path.normpath(os.path.join(HERE, "..", "..", "docs", "schemas", "runhmd.verdict.v1.json"))
SCHEMA_DIR = os.path.dirname(DEFAULT_SCHEMA)
_SIBLING_FILE = re.compile(r"runhmd\.[A-Za-z0-9_.-]+\.json")

# Keywords this module enforces. Anything else that is not an annotation is refused.
_VALIDATING = {
    "$ref", "type", "const", "enum", "required", "properties", "additionalProperties",
    "items", "minItems", "maxItems", "minLength", "maxLength", "pattern", "minimum", "maximum",
}
_ANNOTATIONS = {"$schema", "$id", "$defs", "$comment", "title", "description", "default", "examples"}


class SchemaError(Exception):
    """The schema file itself cannot be enforced (unsupported keyword, bad $ref)."""


def load_schema(path=None):
    path = path or DEFAULT_SCHEMA
    with open(path, "r", encoding="utf-8") as fh:
        schema = json.load(fh)
    if not isinstance(schema, dict):
        raise SchemaError("a schema file must hold a JSON object")
    _audit(schema, "#")
    # Where this file lives: a sibling $ref inside it is looked up next to it, so a copied
    # schema directory (a test fixture, a vendored copy) is self-contained.
    schema["x-source-dir"] = os.path.dirname(os.path.abspath(path))
    return schema


_LOADED = {}


def _load_sibling(path):
    """load_schema, memoised per (path, mtime, size): a receipt with many findings resolves the
    same sibling $ref once per finding, and re-reading the file each time would be pure waste."""
    stat = os.stat(path)
    key = (path, stat.st_mtime_ns, stat.st_size)
    if key not in _LOADED:
        _LOADED[key] = load_schema(path)
    return _LOADED[key]


def _declared_documents():
    """{document id: the schema declaring it} for every runhmd.*.json in the schema directory."""
    found = {}
    for name in sorted(n for n in os.listdir(SCHEMA_DIR) if _SIBLING_FILE.fullmatch(n)):
        schema = _load_sibling(os.path.join(SCHEMA_DIR, name))
        for doc_id in schema.get("x-documents", {}):
            found.setdefault(doc_id, schema)
    return found


def _audit(node, where):
    """Refuse a schema that uses a keyword this module cannot enforce (fail closed)."""
    if not isinstance(node, dict):
        return
    for key in node:
        if key in _VALIDATING or key in _ANNOTATIONS or key.startswith("x-"):
            continue
        raise SchemaError("unsupported schema keyword '%s' at %s: refusing to validate against rules this validator cannot enforce" % (key, where))
    for name, sub in (node.get("properties") or {}).items():
        _audit(sub, "%s/properties/%s" % (where, name))
    for name, sub in (node.get("$defs") or {}).items():
        _audit(sub, "%s/$defs/%s" % (where, name))
    if isinstance(node.get("items"), dict):
        _audit(node["items"], where + "/items")
    if isinstance(node.get("additionalProperties"), dict):
        _audit(node["additionalProperties"], where + "/additionalProperties")


def _resolve(ref, root):
    if not ref.startswith("#"):
        raise SchemaError("only local $ref values are supported (never fetched): %s" % ref)
    node = root
    for part in ref[1:].split("/"):
        if part == "":
            continue
        part = part.replace("~1", "/").replace("~0", "~")
        if not isinstance(node, dict) or part not in node:
            raise SchemaError("unresolvable $ref: %s" % ref)
        node = node[part]
    return node


def _is_type(value, name):
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    if name == "string":
        return isinstance(value, str)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "null":
        return value is None
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "integer":
        return (isinstance(value, int) and not isinstance(value, bool)) or (isinstance(value, float) and value.is_integer())
    raise SchemaError("unsupported type name '%s'" % name)


def _json_eq(a, b):
    """JSON equality: true != 1, 1 == 1.0."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_json_eq(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_json_eq(a[k], b[k]) for k in a)
    return type(a) is type(b) and a == b


def _check(value, schema, root, path, errors):
    if "$ref" in schema:
        _check(value, _resolve(schema["$ref"], root), root, path, errors)
    where = path or "/"
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, n) for n in names):
            errors.append("%s: %r is not of type %s" % (where, value, " or ".join(repr(n) for n in names)))
            return
    if "const" in schema and not _json_eq(value, schema["const"]):
        errors.append("%s: %r is not the required constant %r" % (where, value, schema["const"]))
    if "enum" in schema and not any(_json_eq(value, member) for member in schema["enum"]):
        errors.append("%s: %r is not one of %s" % (where, value, schema["enum"]))
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append("%s: string is shorter than %d" % (where, schema["minLength"]))
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append("%s: string is longer than %d" % (where, schema["maxLength"]))
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append("%s: %r does not match pattern %s" % (where, value, schema["pattern"]))
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append("%s: %r is below the minimum %r" % (where, value, schema["minimum"]))
        if "maximum" in schema and value > schema["maximum"]:
            errors.append("%s: %r is above the maximum %r" % (where, value, schema["maximum"]))
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append("%s: fewer than %d items" % (where, schema["minItems"]))
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append("%s: more than %d items" % (where, schema["maxItems"]))
        if "items" in schema:
            for index, item in enumerate(value):
                _check(item, schema["items"], root, "%s/%d" % (path, index), errors)
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append("%s: missing required property '%s'" % (where, key))
        props = schema.get("properties", {})
        for key, item in value.items():
            if key in props:
                _check(item, props[key], root, "%s/%s" % (path, key), errors)
            elif schema.get("additionalProperties") is False:
                errors.append("%s: unexpected property '%s'" % (where, key))
            elif isinstance(schema.get("additionalProperties"), dict):
                _check(item, schema["additionalProperties"], root, "%s/%s" % (path, key), errors)


def _gate_errors(gates):
    """G1: a gate is only `falsified` when its mutant score is a perfect 1.0."""
    return ["gate '%s' is marked falsified but falsify_score is %r, not 1.0" % (g["id"], g["falsify_score"])
            for g in gates if g["falsified"] and g["falsify_score"] != 1]


def _unproven_reasons(gates, regression):
    """Why a gate set cannot back a PROVEN verdict (empty list == it can)."""
    reasons = []
    for g in gates:
        if g["status"] != "pass":
            reasons.append("gate '%s' failed" % g["id"])
        elif not g["falsified"]:
            reasons.append("gate '%s' is not falsified (it passes, but was never shown to fail)" % g["id"])
    if regression and regression["failed"]:
        reasons.append("%d regression test(s) failed" % regression["failed"])
    return reasons


def _verdict_invariants(doc):
    errors = []
    attacks, findings = doc["attacks"], doc["findings"]
    gates, regression = doc.get("gates", []), doc.get("regression_tests")
    # V1
    if attacks["total"] != attacks["survived"] + attacks["killed"]:
        errors.append("attacks.total (%d) must equal attacks.survived + attacks.killed (%d)"
                      % (attacks["total"], attacks["survived"] + attacks["killed"]))
    # V2
    ids = [f["id"] for f in findings]
    for dup in sorted({i for i in ids if ids.count(i) > 1}):
        errors.append("duplicate finding id '%s'" % dup)
    # V4
    if doc["verdict"] == "DENIED" and not findings:
        errors.append("verdict DENIED requires at least one finding")
    # V3
    if doc["verdict"] == "PROVEN":
        if attacks["killed"]:
            errors.append("verdict PROVEN but attacks.killed is %d" % attacks["killed"])
        if findings:
            errors.append("verdict PROVEN but findings is non-empty")
        if attacks["total"] == 0 and not gates:
            errors.append("verdict PROVEN over zero attacks and zero gates proves nothing (false green)")
        errors.extend("verdict PROVEN but %s" % reason for reason in _unproven_reasons(gates, regression))
    errors.extend(_gate_errors(gates))
    return errors


def _prove_invariants(doc):
    errors = []
    gates = doc["gates"]
    # P1
    if doc["total"] != len(gates):
        errors.append("total (%d) must equal the number of gates (%d)" % (doc["total"], len(gates)))
    passed = sum(1 for g in gates if g["status"] == "pass")
    if doc["passed"] != passed:
        errors.append("passed (%d) must equal the number of gates with status pass (%d)" % (doc["passed"], passed))
    errors.extend(_gate_errors(gates))
    # P2
    reasons = _unproven_reasons(gates, doc["regression_tests"])
    if not gates:
        reasons.append("there are zero gates (a verdict over nothing is a false green)")
    if doc["verdict"] == "PROVEN":
        errors.extend("verdict PROVEN but %s" % reason for reason in reasons)
    elif not reasons:
        errors.append("verdict DENIED but every gate passed and is falsified and no regression test failed")
    return errors


_INVARIANTS = {"runhmd.verdict/1": _verdict_invariants, "runhmd.prove/1": _prove_invariants}


def validate(doc, schema=None):
    """Return the list of problems with `doc` (empty list == valid)."""
    schema = schema if schema is not None else load_schema()
    documents = schema.get("x-documents", {"runhmd.verdict/1": "#"})
    doc_id = doc.get("schema") if isinstance(doc, dict) else None
    if doc_id not in documents:
        return ["/: document must be an object whose 'schema' is one of %s (got %r)" % (sorted(documents), doc_id)]
    errors = []
    _check(doc, _resolve(documents[doc_id], schema), schema, "", errors)
    if errors:
        return errors
    return _INVARIANTS[doc_id](doc)


def _main(argv):
    schema_path, positional = None, []
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg in ("-h", "--help"):
            sys.stdout.write(__doc__)
            return 0
        if arg == "--schema":
            if not args:
                sys.stderr.write("runhmd_schema: --schema needs a path\n")
                return 2
            schema_path = args.pop(0)
        elif arg == "-" or not arg.startswith("-"):
            positional.append(arg)
        else:
            sys.stderr.write("runhmd_schema: unknown option '%s' (see --help)\n" % arg)
            return 2
    if not positional or positional[0] != "validate" or len(positional) > 2:
        sys.stderr.write("runhmd_schema: usage: runhmd_schema.py validate [--schema PATH] [FILE|-]\n")
        return 2
    target = positional[1] if len(positional) == 2 else "-"
    try:
        schema = load_schema(schema_path)
    except (OSError, ValueError, SchemaError) as exc:
        sys.stderr.write("runhmd_schema: unusable schema: %s\n" % exc)
        return 2
    try:
        if target == "-":
            raw = sys.stdin.read()
        else:
            with open(target, "r", encoding="utf-8") as fh:
                raw = fh.read()
    except OSError as exc:
        sys.stderr.write("runhmd_schema: cannot read %s: %s\n" % (target, exc))
        return 2
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        sys.stderr.write("/: not valid JSON: %s\n" % exc)
        return 1
    try:
        errors = validate(doc, schema)
    except SchemaError as exc:
        sys.stderr.write("runhmd_schema: unusable schema: %s\n" % exc)
        return 2
    if errors:
        sys.stderr.write("\n".join(errors) + "\n")
        return 1
    sys.stdout.write("ok %s\n" % doc["schema"])
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
