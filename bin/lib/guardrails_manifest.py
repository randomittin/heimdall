#!/usr/bin/env python3
"""guardrails_manifest -- validate guardrails.manifest.json against docs/schemas/guardrails.manifest.v1.json.

    guardrails_manifest.py validate FILE [--hooks-metadata PATH]

guardrails.manifest.json puts every guardrail Heimdall enforces in one of two tiers:

  core         security and correctness gates. Fail-closed. Never switchable: no hmd command and no config
               file may turn one off.
  recommended  cost and discipline guards. On by default, listed, individually switchable by the operator.

ANYTHING NOT POSITIVELY CLASSIFIED IS CORE. So this validator never defaults a missing tier (the row is
rejected), treats a hook that hooks.metadata.json does not positively mark `locked: false` as locked, and
refuses every shape in which two readers could disagree about one guard's tier: a repeated id, a repeated
JSON key, a field it does not know.

The rules (the schema file lists the cross-field ones as `x-invariants`):

  structure  `schema` is the integer 1; every row has id, kind (guard|feature), tier (core|recommended),
             layer and why, and may have hook, fails (open|closed, informational only), operator_env, proof
             and provisional; nothing else, anywhere; no JSON object repeats a key.
  ids        unique.
  proof      a `guard` names the suite that proves it; a blank proof is no proof.
  hooks      only with --hooks-metadata (hooks/hooks.metadata.json). A row with layer "hook" IS that hook: its
             `hook` equals its id, the id is in the metadata, and a hook the metadata does not positively
             mark unlocked must be tier core. Every hook in the metadata has exactly one such row. A row with
             any other layer is a guard living inside some hook (ci-waste-guard inside bash-gate-chain): it
             names that hook in `hook`, and may be `recommended` although that hook is locked. Without the
             flag these checks cannot run, and the output says so.

Exit: 0 valid (prints `ok guardrails.manifest/1 (N guardrails)` on stdout); 1 invalid or unreadable (one
reason per line on stderr); 2 usage.

Python API (stdlib only):
  load(path) -> dict                              ManifestError unless the file is strict JSON
  load_hooks_metadata(path) -> {hook id: locked}  ManifestError unless it is a usable hooks.metadata.json
  validate(manifest, hooks=None) -> list[str]     empty list == valid
"""
import argparse
import json
import re
import sys

SCHEMA_VERSION = 1
TIERS = ("core", "recommended")
KINDS = ("guard", "feature")
FAILS = ("open", "closed")
HOOK_LAYER = "hook"
TOP_LEVEL = ("schema", "guardrails", "_comment")
REQUIRED = ("id", "kind", "tier", "layer", "why")
OPTIONAL = ("hook", "fails", "operator_env", "proof", "provisional")
ID = r"[a-z0-9]+(-[a-z0-9]+)*"
LAYER = r"[a-z][a-z0-9]*(-[a-z0-9]+)*"
OPERATOR_ENV = r"[A-Za-z_][A-Za-z0-9_]*(=\S*)?"


class ManifestError(Exception):
    """A file cannot be read as strict JSON: missing, unreadable, malformed, a repeated key, nested too deep."""


def _object(pairs):
    """object_pairs_hook: an object that repeats a key is ambiguous (readers differ on which value wins)."""
    found = {}
    for key, value in pairs:
        if key in found:
            raise ValueError("duplicate key %r in one JSON object" % key)
        found[key] = value
    return found


def _read_json(path, what):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=_object)
    except OSError as exc:
        raise ManifestError("cannot read %s %s: %s" % (what, path, exc.strerror or exc))
    except (ValueError, RecursionError) as exc:
        raise ManifestError("%s %s is not strict JSON: %s" % (what, path, exc))


def load(path):
    """The parsed manifest. Raises ManifestError unless the file is strict JSON."""
    return _read_json(path, "manifest")


def load_hooks_metadata(path):
    """{hook id: locked} from hooks.metadata.json. `locked` is True for everything except a literal JSON false:
    a hook not positively marked unlocked is treated as locked (anything not positively classified is core)."""
    doc = _read_json(path, "hooks metadata")
    hooks = doc.get("hooks") if isinstance(doc, dict) else None
    if not isinstance(hooks, list) or not hooks:
        raise ManifestError('hooks metadata %s has no non-empty "hooks" array' % path)
    locked = {}
    for index, hook in enumerate(hooks):
        hook_id = hook.get("id") if isinstance(hook, dict) else None
        if not isinstance(hook_id, str) or not hook_id:
            raise ManifestError("hooks metadata %s: hooks[%d] has no string id" % (path, index))
        if hook_id in locked:
            raise ManifestError("hooks metadata %s: duplicate hook id %r" % (path, hook_id))
        locked[hook_id] = hook.get("locked") is not False
    return locked


def _matches(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def _text(value):
    return isinstance(value, str) and value.strip() != ""


def _where(index, row):
    if isinstance(row.get("id"), str):
        return "guardrails[%d] (id %r)" % (index, row["id"])
    return "guardrails[%d]" % index


def _check_row(index, row):
    if not isinstance(row, dict):
        return ["guardrails[%d] must be a JSON object" % index]
    where = _where(index, row)
    errors = []
    for key in sorted(k for k in row if k not in REQUIRED + OPTIONAL):
        errors.append("%s: unexpected key %r" % (where, key))
    for key in REQUIRED:
        if key not in row:
            hint = " (a guardrail without a tier is unclassified, and unclassified is never defaulted)" if key == "tier" else ""
            errors.append("%s: missing required key %r%s" % (where, key, hint))
    if "id" in row and not _matches(ID, row["id"]):
        errors.append("%s: id must match %s" % (where, ID))
    for key, allowed in (("kind", KINDS), ("tier", TIERS), ("fails", FAILS)):
        if key in row and row[key] not in allowed:
            errors.append("%s: unknown %s %r (allowed: %s)" % (where, key, row[key], ", ".join(allowed)))
    if "layer" in row and not _matches(LAYER, row["layer"]):
        errors.append("%s: layer must match %s" % (where, LAYER))
    if "why" in row and not _text(row["why"]):
        errors.append("%s: why must be a non-blank string" % where)
    if row.get("hook") is not None and not _matches(ID, row["hook"]):
        errors.append("%s: hook must be a hook id or null" % where)
    if row.get("operator_env") is not None and not _matches(OPERATOR_ENV, row["operator_env"]):
        errors.append("%s: operator_env must be NAME or NAME=value, or null" % where)
    if "provisional" in row and not isinstance(row["provisional"], bool):
        errors.append("%s: provisional must be true or false" % where)
    proof = row.get("proof")
    if row.get("kind") == "guard" and not _text(proof):
        errors.append('%s: kind "guard" requires a proof (a non-blank string naming the suite that proves it)' % where)
    elif proof is not None and not _text(proof):
        errors.append("%s: proof must be a non-blank string or null" % where)
    return errors


def _check_hooks(rows, hooks):
    """The cross-checks against hooks.metadata.json; `hooks` is {hook id: locked}."""
    errors = []
    covered = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            continue  # _check_row has rejected it
        where = _where(index, row)
        if row.get("layer") == HOOK_LAYER:
            if row.get("hook") != row["id"]:
                errors.append('%s: a row with layer "hook" is the hook itself, so hook must equal id' % where)
            if row["id"] not in hooks:
                errors.append("%s: id is not a hook in hooks metadata" % where)
                continue
            covered.add(row["id"])
            if hooks[row["id"]] and row.get("tier") in TIERS and row["tier"] != "core":
                errors.append("%s: hook is locked in hooks metadata (or not marked unlocked there), so tier must be core, not %r" % (where, row["tier"]))
        else:
            hook = row.get("hook")
            if isinstance(hook, str) and hook not in hooks:
                errors.append("%s: hook %r is not in hooks metadata" % (where, hook))
    for hook_id in sorted(set(hooks) - covered):
        errors.append('hooks metadata hook %r has no row with layer "hook"' % hook_id)
    return errors


def validate(manifest, hooks=None):
    """The reasons `manifest` is invalid; an empty list means valid.

    `hooks` is load_hooks_metadata's {hook id: locked}. Without it the hook cross-checks are skipped."""
    if not isinstance(manifest, dict):
        return ["the manifest must be a JSON object"]
    errors = []
    for key in sorted(k for k in manifest if k not in TOP_LEVEL):
        errors.append("unexpected top-level key %r" % key)
    schema = manifest.get("schema")
    if type(schema) is not int or schema != SCHEMA_VERSION:
        errors.append("schema must be the integer %d (got %r)" % (SCHEMA_VERSION, schema))
    if "_comment" in manifest and not isinstance(manifest["_comment"], str):
        errors.append("_comment must be a string")
    rows = manifest.get("guardrails")
    if not isinstance(rows, list) or not rows:
        errors.append("guardrails must be a non-empty array")
        return errors
    seen = {}
    for index, row in enumerate(rows):
        errors.extend(_check_row(index, row))
        if isinstance(row, dict) and isinstance(row.get("id"), str):
            seen.setdefault(row["id"], []).append(index)
    for row_id, indexes in sorted(seen.items()):
        if len(indexes) > 1:
            errors.append("duplicate id %r (rows %s)" % (row_id, ", ".join(str(i) for i in indexes)))
    if hooks is not None:
        errors.extend(_check_hooks(rows, hooks))
    return errors


def _fail(reasons):
    for reason in reasons:
        sys.stderr.write("guardrails-manifest: %s\n" % reason)
    return 1


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="guardrails_manifest.py",
        description="Validate guardrails.manifest.json (format v1).",
        epilog="exit: 0 valid, 1 invalid or unreadable (one reason per line on stderr), 2 usage",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("validate", help="check FILE against the v1 rules")
    check.add_argument("file", help="the guardrails.manifest.json to check")
    check.add_argument(
        "--hooks-metadata",
        metavar="PATH",
        help="hooks/hooks.metadata.json: also check that locked hooks are core and that every hook has a row",
    )
    args = parser.parse_args(argv)
    try:
        manifest = load(args.file)
        hooks = load_hooks_metadata(args.hooks_metadata) if args.hooks_metadata is not None else None
    except ManifestError as exc:
        return _fail([str(exc)])
    errors = validate(manifest, hooks)
    if errors:
        return _fail(errors)
    print("ok guardrails.manifest/1 (%d guardrails)" % len(manifest["guardrails"]))
    if hooks is None:
        sys.stderr.write("guardrails-manifest: note: no --hooks-metadata, so locked hooks and hook coverage were not checked\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
