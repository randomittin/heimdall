#!/usr/bin/env python3
# comprehension.py — the real engine behind `bin/heimdall-comprehend` (SI-1).
#
# A per-repo persisted "comprehension capsule": a cache of the agent's
# COMPREHENSION of a project — architecture, key modules, conventions, entry
# points, and build/test commands — that doubles as the resumable ORIENTATION
# cache. Today every run re-derives this understanding from scratch (tokens);
# this makes it orient-once, reuse-many: first run DERIVES (a real structural
# scan) and writes the capsule; a second run on the unchanged repo LOADS the
# cached capsule instead of re-deriving.
#
# HONEST, DETERMINISTIC derivation — NOT an LLM call:
#   - languages present (by source-file extension census)
#   - top-level modules (the repo's top-level source directories)
#   - key modules (the largest source dirs by file count — where the code lives)
#   - manifest / build files detected at the root (package.json, pyproject.toml,
#     Cargo.toml, go.mod, Makefile, …) → build + test commands inferred from them
#   - entry points (conventional bin/, main.*, index.*, __main__.py, cmd/ …)
#   - conventions (lockfiles, CI config, lint config, test dir presence)
#   - architecture: a one-line structural summary built from the above
#
# STALENESS / INVALIDATION (the orient-once contract):
#   The capsule stores a structural FINGERPRINT — a stable hash over:
#     - the sorted set of top-level entries (dirs + files at the repo root),
#     - the sorted set of detected manifest files AND a content hash of each
#       (so a dependency/script change in package.json invalidates the capsule),
#     - the sorted set of languages present.
#   load() recomputes the fingerprint from the live repo and compares. Equal →
#   FRESH (reuse, do not re-derive). Different (a new top-level module, a changed
#   manifest, a new language) → STALE (signal re-derive). Missing or corrupt
#   capsule → also "re-derive", never a crash (graceful degrade).
#
# RELATIONSHIP TO THE EXISTING CHECKPOINT (reused, not duplicated):
#   This module does NOT introduce a parallel checkpoint store. The existing
#   `.planning/CHECKPOINT.md` (the /hmd:save forward-progress save-state) and
#   `bin/heimdall-capsule` (per-task <=10-line compaction) are unchanged. The
#   comprehension capsule is the ORIENTATION cache — the "what IS this project"
#   layer that the checkpoint's "where did we LEAVE OFF" layer sits on top of.
#   One file (`.heimdall/context.json`), one role: cached comprehension. F1's
#   Wave-2 wires load() into the launch/orient phase; this module is standalone.
#
# Pure stdlib (json, hashlib, os, re) — deterministic output for auditability.
# No baked paths: the capsule path is resolved by the caller (the CLI), which
# honours ${HEIMDALL_HOME:-<repo>/.heimdall}.

import hashlib
import json
import os
import re

SCHEMA_VERSION = "1.0.0"

# ── language census ───────────────────────────────────────────────────────────
# extension → language label. Deterministic; an unknown extension is ignored
# (it simply does not contribute a language), never guessed.
LANG_BY_EXT = {
    ".py": "python",
    ".js": "javascript", ".jsx": "javascript", ".mjs": "javascript", ".cjs": "javascript",
    ".ts": "typescript", ".tsx": "typescript",
    ".sh": "shell", ".bash": "shell",
    ".go": "go",
    ".rs": "rust",
    ".rb": "ruby",
    ".java": "java",
    ".c": "c", ".h": "c",
    ".cc": "cpp", ".cpp": "cpp", ".hpp": "cpp", ".cxx": "cpp",
    ".php": "php",
    ".swift": "swift",
    ".kt": "kotlin",
}

# Directories that are never project source — skipped in every census so the
# fingerprint and key-module ranking reflect the project, not its dependencies
# or runtime artifacts.
SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build",
    "target", ".next", ".idea", ".vscode", "vendor", ".worktrees",
    ".heimdall", ".designmatch", ".pytest_cache", ".mypy_cache", "coverage",
}

# ── manifest detection → build/test command inference ─────────────────────────
# Each entry: manifest filename → (language label, [build cmds], [test cmds]).
# Commands are the conventional defaults for that manifest. When a manifest
# carries explicit scripts (npm "scripts", a Makefile target), those are
# preferred over the generic default (see _commands_from_manifest).
MANIFESTS = {
    "package.json":   ("javascript", ["npm install"], ["npm test"]),
    "pyproject.toml": ("python",     ["pip install -e ."], ["pytest"]),
    "setup.py":       ("python",     ["pip install -e ."], ["pytest"]),
    "setup.cfg":      ("python",     ["pip install -e ."], ["pytest"]),
    "requirements.txt": ("python",   ["pip install -r requirements.txt"], ["pytest"]),
    "Cargo.toml":     ("rust",       ["cargo build"], ["cargo test"]),
    "go.mod":         ("go",         ["go build ./..."], ["go test ./..."]),
    "Gemfile":        ("ruby",       ["bundle install"], ["bundle exec rake test"]),
    "Makefile":       ("make",       ["make"], ["make test"]),
    "makefile":       ("make",       ["make"], ["make test"]),
    "pom.xml":        ("java",       ["mvn compile"], ["mvn test"]),
    "build.gradle":   ("java",       ["gradle build"], ["gradle test"]),
    "composer.json":  ("php",        ["composer install"], ["composer test"]),
}

# Convention markers detected at the repo root (presence → a noted convention).
CONVENTION_MARKERS = {
    "package-lock.json": "npm lockfile (reproducible installs)",
    "yarn.lock": "yarn lockfile",
    "pnpm-lock.yaml": "pnpm lockfile",
    "poetry.lock": "poetry lockfile",
    "Cargo.lock": "cargo lockfile",
    "go.sum": "go module checksums",
    ".editorconfig": ".editorconfig present",
    ".eslintrc": "eslint configured",
    ".eslintrc.json": "eslint configured",
    ".eslintrc.js": "eslint configured",
    ".prettierrc": "prettier configured",
    "ruff.toml": "ruff configured",
    ".ruff.toml": "ruff configured",
    "tox.ini": "tox configured",
    ".gitignore": ".gitignore present",
}

# Conventional entry-point filenames probed at the repo root and in top dirs.
ENTRY_BASENAMES = ("main.py", "__main__.py", "index.js", "index.ts", "main.go",
                   "main.rs", "main.js", "main.ts", "app.py", "cli.py")


def _iter_source_files(repo):
    """Yield (relpath, ext) for every source file under repo, skipping SKIP_DIRS.

    Deterministic: directory and file lists are sorted at each level so two runs
    over the same tree visit files in the same order.
    """
    for root, dirs, files in os.walk(repo):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for f in sorted(files):
            ext = os.path.splitext(f)[1].lower()
            rel = os.path.relpath(os.path.join(root, f), repo)
            yield rel, ext


def _languages(repo):
    """The sorted set of languages present, by source-file extension census."""
    langs = set()
    for _rel, ext in _iter_source_files(repo):
        lang = LANG_BY_EXT.get(ext)
        if lang:
            langs.add(lang)
    return sorted(langs)


def _top_level_entries(repo):
    """Sorted top-level entries (dirs + files) at the repo root, minus skipped.

    This is a primary fingerprint input: a NEW top-level module changes it, which
    is exactly the "significant structure change" the spec calls out as staleness.
    """
    out = []
    for name in sorted(os.listdir(repo)):
        if name in SKIP_DIRS:
            continue
        out.append(name + ("/" if os.path.isdir(os.path.join(repo, name)) else ""))
    return out


def _top_level_source_dirs(repo):
    """Top-level directories that contain at least one source file (the modules)."""
    mods = {}
    for rel, ext in _iter_source_files(repo):
        if ext not in LANG_BY_EXT:
            continue
        parts = rel.split(os.sep)
        top = parts[0] if len(parts) > 1 else "<root>"
        mods[top] = mods.get(top, 0) + 1
    return mods


def _detected_manifests(repo):
    """Sorted list of manifest filenames present at the repo root."""
    return sorted(m for m in MANIFESTS if os.path.isfile(os.path.join(repo, m)))


def _file_hash(path):
    """Stable content hash of a file (sha256 hex). Missing/unreadable → ''."""
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return ""


def _npm_scripts(repo):
    """Parse package.json "scripts" → dict. Tolerant of malformed JSON ({} )."""
    p = os.path.join(repo, "package.json")
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
        scripts = data.get("scripts", {})
        return scripts if isinstance(scripts, dict) else {}
    except (OSError, ValueError):
        return {}


def _makefile_targets(repo):
    """Target names declared in a Makefile (best-effort regex)."""
    for name in ("Makefile", "makefile"):
        p = os.path.join(repo, name)
        if os.path.isfile(p):
            try:
                with open(p, "r", encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                return set()
            return set(re.findall(r"(?m)^([A-Za-z0-9_.-]+):", text))
    return set()


def _commands_from_manifest(repo, manifest):
    """(build_cmds, test_cmds) for one manifest, preferring explicit scripts.

    package.json: an explicit "build"/"test" script → `npm run build` / `npm test`.
    Makefile: a `build`/`test` target → `make build` / `make test`.
    Otherwise the conventional default for that manifest.
    """
    _lang, build_default, test_default = MANIFESTS[manifest]
    if manifest == "package.json":
        scripts = _npm_scripts(repo)
        build = ["npm run build"] if "build" in scripts else list(build_default)
        test = ["npm test"] if "test" in scripts else list(test_default)
        return build, test
    if manifest in ("Makefile", "makefile"):
        targets = _makefile_targets(repo)
        build = ["make build"] if "build" in targets else (["make"] if targets else list(build_default))
        test = ["make test"] if "test" in targets else list(test_default)
        return build, test
    return list(build_default), list(test_default)


def _build_test_commands(repo, manifests):
    """Merge build + test commands across all detected manifests (dedup, ordered)."""
    build, test = [], []
    for m in manifests:
        b, t = _commands_from_manifest(repo, m)
        for c in b:
            if c not in build:
                build.append(c)
        for c in t:
            if c not in test:
                test.append(c)
    return build, test


def _entry_points(repo, source_dirs):
    """Conventional entry points: a bin/ dir, root main.*/index.*, top-dir mains."""
    eps = []
    if os.path.isdir(os.path.join(repo, "bin")):
        eps.append("bin/")
    if os.path.isdir(os.path.join(repo, "cmd")):
        eps.append("cmd/")
    # root-level conventional entry files
    for base in ENTRY_BASENAMES:
        if os.path.isfile(os.path.join(repo, base)):
            eps.append(base)
    # one conventional entry file inside each top-level source dir
    for d in sorted(source_dirs):
        if d == "<root>":
            continue
        for base in ENTRY_BASENAMES:
            cand = os.path.join(repo, d, base)
            if os.path.isfile(cand):
                eps.append(os.path.join(d, base))
                break
    # stable order, de-duplicated
    seen, out = set(), []
    for e in eps:
        if e not in seen:
            seen.add(e)
            out.append(e)
    return out


def _conventions(repo, manifests):
    """Detected conventions: lockfiles, lint/format config, test dir, CI."""
    out = []
    for marker, label in sorted(CONVENTION_MARKERS.items()):
        if os.path.exists(os.path.join(repo, marker)):
            out.append(label)
    for tdir in ("test", "tests", "spec", "__tests__"):
        if os.path.isdir(os.path.join(repo, tdir)):
            out.append("tests in %s/" % tdir)
            break
    if os.path.isdir(os.path.join(repo, ".github", "workflows")):
        out.append("GitHub Actions CI")
    # de-dup, stable
    seen, dedup = set(), []
    for c in out:
        if c not in seen:
            seen.add(c)
            dedup.append(c)
    return dedup


def _architecture(languages, source_dirs, manifests):
    """A one-line structural summary derived from the scan (never canned)."""
    lang_str = ", ".join(languages) if languages else "no recognized source"
    mods = [d for d in sorted(source_dirs) if d != "<root>"]
    mod_str = ("top-level modules: " + ", ".join(mods)) if mods else "single-level layout"
    man_str = ("manifests: " + ", ".join(manifests)) if manifests else "no build manifest"
    return "%s project — %s — %s" % (lang_str, mod_str, man_str)


def fingerprint(repo):
    """The structural fingerprint used for staleness detection.

    A stable sha256 over: top-level entries, each detected manifest's name AND a
    content hash of it, and the language set. Any structurally significant change
    (new top-level module, changed manifest, new language) flips this hash.
    Returns the hex digest string.
    """
    manifests = _detected_manifests(repo)
    parts = []
    parts.append("TOP\n" + "\n".join(_top_level_entries(repo)))
    parts.append("LANG\n" + "\n".join(_languages(repo)))
    man_lines = []
    for m in manifests:
        man_lines.append("%s=%s" % (m, _file_hash(os.path.join(repo, m))))
    parts.append("MANIFEST\n" + "\n".join(man_lines))
    blob = "\n--\n".join(parts).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def derive(repo, generated_at, derivations=0):
    """DERIVE the comprehension capsule from a real structural scan of `repo`.

    `generated_at` is an ISO timestamp supplied by the caller (deterministic
    output: this module never reads the clock). `derivations` is the running
    count of how many times derivation has occurred for this repo — incremented
    here and stored, so the load-not-rederive proof can assert it does NOT change
    on a cached load. Returns the capsule dict.
    """
    repo = os.path.abspath(repo)
    languages = _languages(repo)
    source_dirs = _top_level_source_dirs(repo)
    manifests = _detected_manifests(repo)
    build_cmds, test_cmds = _build_test_commands(repo, manifests)

    # key modules = the source dirs with the most files (where the code lives),
    # largest first; ties broken by name for determinism.
    ranked = sorted(source_dirs.items(), key=lambda kv: (-kv[1], kv[0]))
    key_modules = [{"path": d if d != "<root>" else ".", "files": n} for d, n in ranked]

    return {
        "schema_version": SCHEMA_VERSION,
        "repo": repo,
        "generated_at": generated_at,
        "fingerprint": fingerprint(repo),
        "languages": languages,
        "architecture": _architecture(languages, source_dirs, manifests),
        "key_modules": key_modules,
        "entry_points": _entry_points(repo, source_dirs),
        "conventions": _conventions(repo, manifests),
        "manifests": manifests,
        "build_commands": build_cmds,
        "test_commands": test_cmds,
        "derivation": {
            # how this capsule was produced + the running derivation counter.
            # `count` is the proof signal: a cached load returns the SAME count;
            # a re-derive increments it. `cost_units` is a deterministic,
            # honest proxy for derivation cost (files scanned) — the module-level
            # stand-in for the launch-path token delta F1 will measure.
            "method": "structural-scan",
            "count": derivations + 1,
            "cost_units": sum(1 for _ in _iter_source_files(repo)),
        },
    }


REQUIRED_FIELDS = (
    "schema_version", "repo", "generated_at", "fingerprint", "languages",
    "architecture", "key_modules", "entry_points", "conventions",
    "manifests", "build_commands", "test_commands", "derivation",
)


def is_wellformed(capsule):
    """True iff `capsule` is a dict carrying every required field + a derivation
    sub-record with a `count`. Used by load() to treat a structurally-broken
    capsule the same as a corrupt one (→ re-derive, never trust)."""
    if not isinstance(capsule, dict):
        return False
    for field in REQUIRED_FIELDS:
        if field not in capsule:
            return False
    deriv = capsule.get("derivation")
    if not isinstance(deriv, dict) or "count" not in deriv:
        return False
    return True


def load_status(repo, capsule_path):
    """Read the capsule at `capsule_path` and classify it against the live repo.

    Returns (status, capsule):
      - ("fresh",   capsule) — well-formed AND its fingerprint matches the repo.
                               REUSE it; do NOT re-derive.
      - ("stale",   capsule) — well-formed but the fingerprint differs (structure
                               changed). Signal re-derive. (capsule is the old one.)
      - ("missing", None)    — no capsule file. Signal re-derive.
      - ("corrupt", None)    — file present but unreadable / not JSON / not
                               well-formed. Signal re-derive — NEVER crash.

    This is pure + deterministic and never raises on a bad capsule: graceful
    degrade is the contract.
    """
    if not os.path.isfile(capsule_path):
        return "missing", None
    try:
        with open(capsule_path, "r", encoding="utf-8", errors="replace") as fh:
            capsule = json.load(fh)
    except (OSError, ValueError):
        return "corrupt", None
    if not is_wellformed(capsule):
        return "corrupt", None
    repo = os.path.abspath(repo)
    if capsule.get("fingerprint") != fingerprint(repo):
        return "stale", capsule
    return "fresh", capsule
