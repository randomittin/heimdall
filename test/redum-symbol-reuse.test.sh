#!/usr/bin/env bash
# test/redum-symbol-reuse.test.sh — the CROSS-PROJECT SYMBOL REUSE ENFORCER on F3 Redum.
#
# The mechanical embodiment of ponytail rung-2 ("already exists? reuse it"): detect when NEW
# code re-declares a symbol (function / type / dataclass / const) that already exists somewhere
# ELSE in the project, and route the author to the canonical one instead of a parallel copy.
#
# ADVISE-DEFAULT, EXACT-DUP-ONLY-BLOCK (surfacing > blocking, per redum law):
#   * types / structural / const re-declarations       -> WARN + surface the canonical import
#   * EXACT function or type duplication (same name+shape in two modules) -> HARD-BLOCK exit-3
#
# Falsifiers (each RED before the symbol-reuse detector exists):
#   A  a new fn duplicating an existing project fn -> canonical surfaced (WARN) + exact BLOCK exit-3
#   B  a re-declared dataclass with the same fields -> canonical ADVISED (WARN, no block)
#   C  a genuinely new unique symbol -> NOT flagged (verdict ok)
#   D  an opt-out-marked local copy -> ALLOWED (never flagged/blocked)
#   E  a test-fixture / vendored duplicate -> IGNORED (not indexed, not checked)
#   F  an EXACT type duplication (same name + same fields, two modules) -> HARD-BLOCK exit-3
#
# Pure library calls (bin/lib/redum.py); no git, no network.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -f "$ROOT/bin/lib/redum.py" ] || { echo "FATAL: redum.py missing" >&2; exit 2; }

REDUM_LIB="$ROOT/bin/lib" python3 - <<'PYEOF'
import os, sys

sys.path.insert(0, os.environ["REDUM_LIB"])
import redum

PASS = {"n": 0}
FAIL = {"n": 0}
def ok(m):  PASS["n"] += 1; print("  \033[32mPASS\033[0m %s" % m)
def bad(m): FAIL["n"] += 1; print("  \033[31mFAIL\033[0m %s" % m)

# ── the canonical, pre-existing project surface (the repo the author builds on) ─
CANON = {
    "pkg/core.py":   "def compute_total(items, tax):\n    return sum(items) + tax\n",
    "pkg/models.py": "class User:\n    id = None\n    email = None\n",
    "pkg/limits.py": "MAX_RETRIES = 3\n",
}

# ════════════════════════════════════════════════════════════════════════════
# A — a new fn duplicating an existing project fn: canonical surfaced (WARN) + BLOCK exit-3
# ════════════════════════════════════════════════════════════════════════════
proposed = {"feat/new.py": "def compute_total(items, tax):\n    return sum(items) - tax\n"}
res = redum.detect_symbol_reuse(proposed, CANON)
if res["verdict"] == "block" and redum.symbol_reuse_exit_code(res) == 3:
    ok("A exact function duplicate -> verdict=block, exit-3")
else:
    bad("A exact fn dup NOT blocked: verdict=%r exit=%r" % (res["verdict"], redum.symbol_reuse_exit_code(res)))

blk = res["blocked"]
if blk and blk[0]["class"] == "exact-function" and blk[0]["canonical"]["name"] == "compute_total" \
   and blk[0]["canonical"]["module"] == "pkg/core.py":
    ok("A block names the canonical function pkg/core.py:compute_total")
else:
    bad("A block does not name the canonical: %r" % blk)

if blk and "compute_total" in blk[0]["import_hint"] and "pkg.core" in blk[0]["import_hint"]:
    ok("A canonical import path surfaced (%s)" % blk[0]["import_hint"])
else:
    bad("A import hint missing/wrong: %r" % (blk[0].get("import_hint") if blk else None))

# ════════════════════════════════════════════════════════════════════════════
# B — a re-declared dataclass with the SAME fields -> canonical ADVISED (WARN, no block)
# ════════════════════════════════════════════════════════════════════════════
proposed = {"feat/account.py": "class Account:\n    id = None\n    email = None\n"}
res = redum.detect_symbol_reuse(proposed, CANON)
if res["verdict"] == "advise" and redum.symbol_reuse_exit_code(res) == 0:
    ok("B same-fields type re-declaration -> verdict=advise, exit-0 (no block)")
else:
    bad("B same-fields type not advised: verdict=%r exit=%r" % (res["verdict"], redum.symbol_reuse_exit_code(res)))

adv = res["advised"]
if adv and adv[0]["class"] == "structural-type" and adv[0]["canonical"]["name"] == "User":
    ok("B advise surfaces the canonical type pkg/models.py:User (structural match)")
else:
    bad("B advise does not surface canonical User: %r" % adv)

# ════════════════════════════════════════════════════════════════════════════
# C — a genuinely new unique symbol -> NOT flagged
# ════════════════════════════════════════════════════════════════════════════
proposed = {"feat/brand.py": "def render_invoice_pdf(order, theme):\n    return (order, theme)\n"}
res = redum.detect_symbol_reuse(proposed, CANON)
if res["verdict"] == "ok" and not res["blocked"] and not res["advised"]:
    ok("C genuinely unique symbol -> verdict=ok, nothing flagged")
else:
    bad("C unique symbol wrongly flagged: %r" % res)

# ════════════════════════════════════════════════════════════════════════════
# D — an opt-out-marked local copy -> ALLOWED
# ════════════════════════════════════════════════════════════════════════════
proposed = {"feat/local.py":
            "# redum: allow-duplicate — deliberate local copy, justified\n"
            "def compute_total(items, tax):\n    return sum(items) + tax\n"}
res = redum.detect_symbol_reuse(proposed, CANON)
if res["verdict"] == "ok" and not res["blocked"] and not res["advised"]:
    ok("D opt-out-marked duplicate -> ALLOWED (verdict=ok, exit-0)")
else:
    bad("D opt-out copy wrongly flagged/blocked: %r" % res)

# ════════════════════════════════════════════════════════════════════════════
# E — a test-fixture / vendored duplicate -> IGNORED
# ════════════════════════════════════════════════════════════════════════════
proposed = {
    "tests/test_core.py":  "def compute_total(items, tax):\n    return sum(items) + tax\n",
    "vendor/dup.py":       "def compute_total(items, tax):\n    return sum(items) + tax\n",
}
res = redum.detect_symbol_reuse(proposed, CANON)
if res["verdict"] == "ok" and not res["blocked"] and not res["advised"]:
    ok("E test-fixture + vendored duplicates -> IGNORED (not checked)")
else:
    bad("E ignored-path duplicate wrongly flagged: %r" % res)

# and a canonical symbol living in a fixture dir must NOT be indexed as canonical.
canon_fixture = {"tests/fixtures/helpers.py": "def only_in_fixtures(x):\n    return x\n"}
res = redum.detect_symbol_reuse({"feat/f.py": "def only_in_fixtures(x):\n    return x\n"}, canon_fixture)
if res["verdict"] == "ok":
    ok("E a fixture-only canonical is not a reuse target (proposal stays ok)")
else:
    bad("E fixture symbol wrongly treated as canonical: %r" % res)

# ════════════════════════════════════════════════════════════════════════════
# F — an EXACT type duplication (same name + same fields, two modules) -> HARD-BLOCK exit-3
# ════════════════════════════════════════════════════════════════════════════
proposed = {"feat/user2.py": "class User:\n    id = None\n    email = None\n"}
res = redum.detect_symbol_reuse(proposed, CANON)
if res["verdict"] == "block" and redum.symbol_reuse_exit_code(res) == 3:
    ok("F exact type duplication (User same fields, different module) -> block exit-3")
else:
    bad("F exact type dup NOT blocked: verdict=%r exit=%r" % (res["verdict"], redum.symbol_reuse_exit_code(res)))

blk = res["blocked"]
if blk and blk[0]["class"] == "exact-type" and blk[0]["canonical"]["module"] == "pkg/models.py":
    ok("F block names the canonical type pkg/models.py:User")
else:
    bad("F block does not name canonical User type: %r" % blk)

# ── summary ────────────────────────────────────────────────────────────────────
print()
print("redum-symbol-reuse: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m" % (PASS["n"], FAIL["n"]))
sys.exit(0 if FAIL["n"] == 0 else 1)
PYEOF
RC=$?
echo
[ "$RC" -eq 0 ] && echo "redum-symbol-reuse: OK — cross-project symbol reuse enforced (advise-default, exact-dup blocks exit-3)" \
               || echo "redum-symbol-reuse: FAILED"
exit "$RC"
