# symbol-reuse — Invariant Ledger

**Domain:** `symbol-reuse` · **gate_type:** `differential` · **Status:** authored alongside the detector

This ledger pins the falsifiable invariants of redum's CROSS-PROJECT SYMBOL REUSE enforcer —
the mechanical embodiment of the ponytail lazy-ladder's **rung 2** ("already exists? reuse it").
It is the SINGLE source of truth the independent differential reference (`reference.py`) is
authored from — the reference imports NOTHING from `bin/lib/*`; every rule below is hand-
reproduced there, so it shares no code path with the implementation under test
(`bin/lib/redum.detect_symbol_reuse`). Re-read this before touching the detector, the reference,
or the gate.

---

## 0. What the enforcer IS

When new code re-declares a symbol (function, class/type, dataclass/TypedDict/struct, or module-
level constant) that already exists SOMEWHERE ELSE in the project, the author should reuse the
canonical definition, not grow a parallel copy. The enforcer builds a **project-wide symbol
index** (Python via the real `ast`; shell functions heuristically; other languages by name+kind
via the shared dedup core) keyed by **name + signature/shape + defining module**, then classifies
each PROPOSED new symbol against it and routes the author to the canonical one.

It is deliberately **advise-default, exact-dup-only-block** (surfacing > blocking, per redum law):
a WARN that names the canonical import is the common case; a hard block is reserved for the
unambiguous re-declaration.

---

## 1. The SHARED ignore set (not canonical surface)

Reproduced from `reuse_analyzer.is_test_path` plus redum's vendored/generated regexes. Symbols in
these paths are neither indexed as canonical nor checked as proposals:

- **test / spec / fixture** dirs & file stems — `tests/`, `__tests__/`, `spec/`, `fixtures/`,
  `testdata/`, `conformance/`, `e2e/`; `test_*`, `*_test`, `*.test.*`, `*.spec.*`, `*.fixture.*`,
  `conftest`, `test-*`.
- **vendored** trees — `node_modules/`, `vendor/`, `third_party/`, `external/`, `site-packages/`,
  `dist/`, `build/`, `.venv/`, …
- **generated** files — `*.generated.*`, `*_generated.*`, `*_pb2.py`, `*.pb.go`, `*.g.dart`,
  `*.min.js`, `*.bundle.js`.

## 2. Symbol families & shape

A function never dedups against a type. Families:

- **function** — `function`, `shell-function`, `method`. Shape = the ordered parameter list,
  `"(p0,p1,…)"`. A language yielding no signature (a bare name+kind unit) has shape `"()"` and can
  NEVER exact-block (conservative).
- **type** — `type`, `class`, `interface`, `enum`, `component`. Shape = the sorted field/attribute
  set, `"{a,b,…}"`.
- **const** — a module-level constant/object. Matched by NAME only (value is metadata).

**Name normalization** (shared with dedup): strip `_`/`-`, lowercase — so `make_option_mandatory`
and `makeOptionMandatory` are one symbol.

**Opt-out marker** — a deliberate, justified local copy: a comment or decorator matching
`redum: allow-duplicate` / `redum-allow-duplicate` / `redum: allow-local-copy` in/just-above the
symbol.

---

## 3. The load-bearing INVARIANTS (each a RED-without-fix falsifier)

Precedence (first match wins): **SR-A > SR-B > (SR-C | SR-D) > (SR-E | SR-F | SR-G) > SR-H.**
A symbol never matches itself: a canonical in the SAME module as the proposal is not a duplicate.

### SR-A — ignored-path-not-surface
A symbol declared in a test / fixture / vendored / generated path (§1) is DROPPED — it is neither
a canonical reuse target nor a checked proposal (in no bucket).
*Falsifier:* a duplicate in `tests/` or `vendor/` that appears in any bucket → RED.

### SR-B — opt-out-is-allowed
A proposed symbol carrying the opt-out marker (§2) is ALLOWED unconditionally → the `ok` bucket,
even when it duplicates a canonical.
*Falsifier (mutant `ignore-optout-broken`):* an opt-out-marked exact copy that is hard-blocked
diverges from the reference (which allows it) → RED.

### SR-C — exact-function-blocks
A proposed function-family symbol with the SAME normalized name AND identical signature as a
project function in a DIFFERENT module → **BLOCK** (verdict `block`, exit-3). Both sides must
carry a real signature (a name-only cross-language unit never blocks).
*Falsifier (mutant `cross-file-dup-missed`):* a cross-file exact function dup served as `ok`
diverges from the reference (which blocks it) → RED.

### SR-D — exact-type-blocks
A proposed type with the SAME normalized name AND identical field shape as a project type in a
DIFFERENT module → **BLOCK** (verdict `block`, exit-3).
*Falsifier (mutant `miss-exact-dup`):* an exact type re-declaration served as `ok` diverges from
the reference (which blocks it) → RED.

### SR-E — structural-type-advises
A proposed type whose field shape equals a project type's shape but under a DIFFERENT name
(structural equivalence) → **ADVISE** (WARN, surface the canonical import; never block — a
different-named same-shape type may be a legitimate parallel domain concept).

### SR-F — same-name/near-function-advises
A proposed function sharing a name with a project function but with a DIFFERENT signature (drift),
or a near-duplicate name → **ADVISE**.

### SR-G — const-redef-advises
A proposed module-level constant sharing a name with a project constant in a DIFFERENT module →
**ADVISE**.

### SR-H — unique-is-ok
A proposed symbol with no canonical match → **OK** (the `ok` bucket). The enforcer must NOT flag a
symbol that genuinely does not exist elsewhere.
*Falsifier (mutant `false-flag-unique`):* a unique symbol wrongly flagged diverges from the
reference (which passes it) → RED.

---

## 4. The differential partition (the whole-aggregate proof)

The gate normalizes both the impl detector and the independent reference to ONE comparable
partition and asserts equality over every seeded stream:

    {
      "blocked": sorted [ [proposed_tag, class, canonical_tag], … ],   # SR-C / SR-D
      "advised": sorted [ [proposed_tag, class, canonical_tag], … ],   # SR-E / SR-F / SR-G
      "ok":      sorted [ proposed_tag, … ],                            # SR-B / SR-H
    }

where `tag = "name@module"`. A per-symbol property check passes a whole-aggregate bug (a missed
cross-file dup, a false-flagged unique, an ignored opt-out); the whole-partition differential
catches that class — which is why `gate_type` is `differential`, not `property`.

The reference reproduces §1–§3 independently; `differential.py` (neutral wiring) synthesizes real
source from each abstract symbol record and feeds it to the REAL detector, so the impl arm
exercises `redum.detect_symbol_reuse`, not a mock. Same seed ⇒ byte-identical stream; the impl and
reference folds MUST agree on every seed.

---

## 5. Relationship to the rest of redum (reuse, don't rebuild)

- **Name normalization** → `dedup.normalize` (the impl); hand-reproduced in the reference.
- **Ignore set** → `reuse_analyzer.is_test_path` (the impl) + redum's vendor/generated regexes;
  hand-reproduced in the reference.
- **Cross-language symbol surface** → `dedup.index_repo_units` for non-Python/non-shell files
  (name+kind only → advise-only, never exact-block).

This is the code∪code half of rung-2; redum's team lens is the code∪work half (a teammate building
the same surface). Neither re-measures reuse — SI-2 owns the reuse percentage.
