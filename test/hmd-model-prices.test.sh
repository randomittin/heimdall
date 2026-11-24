#!/usr/bin/env bash
# test/hmd-model-prices.test.sh: bin/lib/hmd_model_prices.py, the reader of the model_prices rows of bin/lib/tier-table.json
# for the Python tools that price tokens (bin/heimdall-tokens, bin/lib/fg_agent.py).
#
# WHAT THIS PROVES
#   [C] CARDS    a row becomes a rate card: cache writes are the table's multiples of its input rate, cache read is the multiple
#                unless the row sets it, and None when the row says null (unconfirmed: never guessed); a long_context block is a
#                second card with its own prompt-length threshold.
#   [M] MODEL    a model id is placed by family and version, never by tier or by prefix: a context-window suffix and a dated-snapshot
#                suffix are dropped, an id the table lacks places nothing, and the newest row of a family wins numerically (2.10
#                over 2.9, which a string sort gets wrong).
#   [E] ERRORS   a table that cannot be trusted raises PricesError (a ValueError) that names what is wrong: nothing is priced from it.
#
# The cases run on a small synthetic table, so no price in the shipped table can make them pass or fail; the shipped table is
# only loaded once, to prove the default path resolves and every tier has a row.
#
# Hermetic: one python3 process, no network, no model call; the tables are written under a throwaway dir.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmd-model-prices-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

python3 - "$REPO" "$TMP" >"$TMP/out" 2>"$TMP/out.err" <<'PY'
import copy, json, os, sys
repo, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
import hmd_model_prices as prices

out = []
def t(desc, cond, detail=""):
    out.append("%s\t%s\t%s" % ("PASS" if cond else "FAIL", desc, "" if cond else detail))

def near(a, b):
    return a is not None and abs(a - b) < 1e-9

SYNTH = {
    "cache_price_multipliers": {"cache_read": 0.1, "cache_write_5m": 1.25, "cache_write_1h": 2.0},
    "model_prices": {"rows": [
        {"family": "alpha", "version": "2.10", "input": 10.0, "output": 50.0},
        {"family": "alpha", "version": "2.9", "input": 8.0, "output": 40.0, "cache_read": 0.4},
        {"family": "alpha", "version": "2", "input": 4.0, "output": 20.0, "cache_read": None},
        {"family": "beta", "version": "1", "input": 1.0, "output": 5.0,
         "long_context": {"above_prompt_tokens": 1000, "input": 2.0, "output": 10.0}},
    ]},
}

def write(name, table):
    path = os.path.join(tmp, name + ".json")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(table if isinstance(table, str) else json.dumps(table))
    return path

def variant(name, edit):
    table = copy.deepcopy(SYNTH)
    edit(table)
    return write(name, table)

def row(table, family, version):
    return next(r for r in table["model_prices"]["rows"] if r["family"] == family and r["version"] == version)

loaded = prices.load(write("synth", SYNTH))

# [C] cards
a10 = prices.card_for(loaded, "claude-alpha-2-10")
t("a row's cache writes are the table's multiples of its input rate (input $10: 5-minute write $12.50, 1-hour write $20)",
  a10 is not None and near(a10["input"], 10.0) and near(a10["output"], 50.0) and near(a10["cache_write_5m"], 12.5) and near(a10["cache_write_1h"], 20.0), a10)
t("a row that does not set cache_read reads at the table's multiple of input ($1 for input $10)", a10 is not None and near(a10["cache_read"], 1.0), a10)
a9 = prices.card_for(loaded, "claude-alpha-2-9")
t("a row that sets cache_read keeps its own ($0.40, not the multiple's $0.80)", a9 is not None and near(a9["cache_read"], 0.4), a9)
a2 = prices.card_for(loaded, "claude-alpha-2")
t("a row whose cache_read is null is unconfirmed: None, never a guessed multiple", a2 is not None and a2["cache_read"] is None, a2)
b1 = prices.card_for(loaded, "claude-beta-1")
long_card = (b1 or {}).get("long_context") or {}
t("a long_context block is a second card: its threshold, its own input and output, cache lines at its own input rate",
  b1 is not None and long_card.get("above_prompt_tokens") == 1000 and near(long_card.get("input"), 2.0) and near(long_card.get("output"), 10.0)
  and near(long_card.get("cache_read"), 0.2) and near(long_card.get("cache_write_5m"), 2.5) and near(long_card.get("cache_write_1h"), 4.0), b1)
t("a row without a long_context block has none", a10 is not None and a10["long_context"] is None, a10)
t("a card names its family and version", a10 is not None and a10["family"] == "alpha" and a10["version"] == "2.10", a10)

shipped = prices.load()
t("the shipped table loads from the default path and has a row for every tier",
  all(prices.tier_card(shipped, tier) is not None for tier in ("haiku", "sonnet", "opus", "fable")), sorted(shipped["newest"]))

# [M] model ids
t("a version is matched whole, not by prefix: claude-alpha-2-1 is neither 2.10 nor 2", prices.card_for(loaded, "claude-alpha-2-1") is None)
t("three versions of one family stay three rows (2, 2.9, 2.10)",
  [prices.card_for(loaded, m)["version"] for m in ("claude-alpha-2", "claude-alpha-2-9", "claude-alpha-2-10")] == ["2", "2.9", "2.10"])
t("a context-window suffix is dropped (<id>[1m])", prices.card_for(loaded, "claude-alpha-2-10[1m]") is a10)
t("a dated-snapshot suffix is dropped (<id>-YYYYMMDD)", prices.card_for(loaded, "claude-alpha-2-10-20260101") is a10)
t("both suffixes together are dropped", prices.card_for(loaded, "claude-alpha-2-10-20260101[1m]") is a10)
t("model_id gives the id the table names", prices.model_id("claude-alpha-2-10-20260101[1m]") == "claude-alpha-2-10")
t("a family the table lacks places nothing", prices.card_for(loaded, "claude-gamma-1") is None)
t("no model, an empty id and a non-claude id place nothing", all(prices.card_for(loaded, m) is None for m in (None, "", "gpt-4")))
t("the newest row of a family is the numerically newest (2.10 over 2.9 and 2)", prices.tier_card(loaded, "alpha")["version"] == "2.10", prices.tier_card(loaded, "alpha"))
t("a family with no row has no tier card", prices.tier_card(loaded, "gamma") is None)

# [E] a table that cannot be trusted
t("PricesError is a ValueError, the type heimdall-tokens catches", issubclass(prices.PricesError, ValueError))
def raises(name, path, needle):
    try:
        prices.load(path)
    except prices.PricesError as exc:
        t("%s: raises PricesError naming %s" % (name, needle), needle in str(exc), str(exc))
    except Exception as exc:
        t("%s: raises PricesError naming %s" % (name, needle), False, "raised %r instead" % exc)
    else:
        t("%s: raises PricesError naming %s" % (name, needle), False, "loaded without an error")

def drop_output(table):
    del row(table, "alpha", "2.10")["output"]
def negative(table):
    row(table, "alpha", "2.10")["input"] = -1.0
def boolean(table):
    row(table, "alpha", "2.10")["input"] = True
def bad_version(table):
    row(table, "alpha", "2.10")["version"] = "2.x"
def bad_family(table):
    row(table, "alpha", "2.10")["family"] = "Alpha"
def duplicate(table):
    table["model_prices"]["rows"].append(dict(row(table, "alpha", "2.10")))
def bad_threshold(table):
    row(table, "beta", "1")["long_context"]["above_prompt_tokens"] = 0
def float_threshold(table):
    row(table, "beta", "1")["long_context"]["above_prompt_tokens"] = 1000.5
def no_rows(table):
    table["model_prices"]["rows"] = []
def no_multipliers(table):
    del table["cache_price_multipliers"]
def bad_multiplier(table):
    table["cache_price_multipliers"]["cache_write_5m"] = "1.25"

raises("a missing file", os.path.join(tmp, "no-such-table.json"), "no-such-table.json")
raises("a file that is not JSON", write("garbage", "{not json"), "cannot read")
raises("a top level that is not an object", write("array", "[]"), "model_prices")
raises("an empty rows list", variant("norows", no_rows), "rows")
raises("a table without cache_price_multipliers", variant("nomult", no_multipliers), "cache_price_multipliers")
raises("a multiplier that is not a number", variant("badmult", bad_multiplier), "cache_write_5m")
raises("a row without an output rate", variant("nooutput", drop_output), '"output"')
raises("a negative input rate", variant("negative", negative), '"input"')
raises("a boolean input rate", variant("boolean", boolean), '"input"')
raises("a version that is not dotted digits", variant("badversion", bad_version), "version")
raises("a family that is not lowercase letters", variant("badfamily", bad_family), "family")
raises("two rows for one model", variant("duplicate", duplicate), "duplicates")
raises("a long_context threshold of zero", variant("zerothreshold", bad_threshold), "above_prompt_tokens")
raises("a long_context threshold that is not an integer", variant("floatthreshold", float_threshold), "above_prompt_tokens")

print("\n".join(out))
print("END")
PY

verdict() {
  local kind desc detail seen_end=0
  while IFS=$'\t' read -r kind desc detail; do
    case "$kind" in
      PASS) ok "$desc" ;;
      FAIL) bad "$desc  [$detail]" ;;
      END)  seen_end=1 ;;
      *)    bad "unexpected line from the python section: $kind $desc" ;;
    esac
  done <"$TMP/out"
  [ "$seen_end" -eq 1 ] || bad "the python section did not run to its end: $(tail -3 "$TMP/out.err" | tr '\n' ' ')"
}
verdict

echo
echo "hmd-model-prices: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
