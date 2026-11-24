#!/usr/bin/env python3
"""hmd_model_prices: Claude list prices, read from the `model_prices` rows of bin/lib/tier-table.json.

That block is the one place a rate is written; its `purpose`, `source` and `rate_rules` fields say where each number comes from and how
the cache lines derive. This module expands the rows into rate cards and places a model id against them. It holds no rate, so a new
generation is priced by adding a row there. Its readers are bin/heimdall-tokens (the cost it derives when a record carries none) and
bin/lib/fg_agent.py (the Study A spend meter).

A card is a dict of US$ per million tokens: input, output, cache_read, cache_write_5m, cache_write_1h, plus family, version and
long_context. Cache writes are the table's multiples of the input price. cache_read is the table's multiple too unless the row sets it,
and is None when the row says null: an unconfirmed price is reported as unknown, never guessed. long_context is None, or a second card
(with above_prompt_tokens) for a request whose prompt is longer than that.

A model id is placed by family and version, never by tier or by prefix: one tier's generations list at different prices.
"""
import json
import os
import re

TABLE_PATH = os.path.join(os.path.dirname(os.path.realpath(__file__)), "tier-table.json")
_MULTIPLES = ("cache_read", "cache_write_5m", "cache_write_1h")
_WINDOW_SUFFIX_RE = re.compile(r"\[[^\]]*\]$")      # <id>[1m]
_DATE_SUFFIX_RE = re.compile(r"-\d{8}$")            # <id>-YYYYMMDD


class PricesError(ValueError):
    """The table cannot be read or a row is malformed. Fatal on purpose: nothing is priced from a table that cannot be trusted."""


def _rate(spec, key, where):
    value = spec.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not value >= 0:
        raise PricesError('%s: "%s" must be a non-negative number, got %r' % (where, key, value))
    return float(value)


def _card(spec, multiples, where):
    """One rate card from a row's input and output; the cache lines follow the input price."""
    price = _rate(spec, "input", where)
    if "cache_read" not in spec:
        read = round(price * multiples["cache_read"], 10)
    elif spec["cache_read"] is None:
        read = None
    else:
        read = _rate(spec, "cache_read", where)
    return {"input": price, "output": _rate(spec, "output", where), "cache_read": read,
            "cache_write_5m": round(price * multiples["cache_write_5m"], 10),
            "cache_write_1h": round(price * multiples["cache_write_1h"], 10)}


def load(path=TABLE_PATH):
    """{"by_id": {model id: card}, "newest": {family: card of its newest row}} from the model_prices rows of the table at `path`.

    The model id of a row is built from its family and version (`claude-<family>-<version with dots as dashes>`), so the table names
    no id. Raises PricesError when the file cannot be read or any row is malformed.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            table = json.load(fh)
    except (OSError, ValueError) as exc:
        raise PricesError("%s: cannot read the price table: %s" % (path, exc))
    block = table.get("model_prices") if isinstance(table, dict) else None
    raw = table.get("cache_price_multipliers") if isinstance(table, dict) else None
    rows = block.get("rows") if isinstance(block, dict) else None
    if not isinstance(raw, dict) or not isinstance(rows, list) or not rows:
        raise PricesError('%s: needs "cache_price_multipliers" and a non-empty "model_prices.rows"' % path)
    multiples = {key: _rate(raw, key, "cache_price_multipliers") for key in _MULTIPLES}
    by_id, newest = {}, {}
    for index, row in enumerate(rows):
        where = "model_prices.rows[%d]" % index
        family = row.get("family") if isinstance(row, dict) else None
        version = row.get("version") if isinstance(row, dict) else None
        if not (isinstance(family, str) and re.fullmatch(r"[a-z]+", family)
                and isinstance(version, str) and re.fullmatch(r"\d+(\.\d+)*", version)):
            raise PricesError('%s: needs a lowercase "family" and a "version" like 5.5' % where)
        where = "%s (%s %s)" % (where, family, version)
        model = "claude-%s-%s" % (family, version.replace(".", "-"))
        if model in by_id:
            raise PricesError("%s: duplicates an earlier row" % where)
        card = _card(row, multiples, where)
        card.update(family=family, version=version, long_context=None)
        spec = row.get("long_context")
        if spec is not None:
            limit = spec.get("above_prompt_tokens") if isinstance(spec, dict) else None
            if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
                raise PricesError('%s long_context: "above_prompt_tokens" must be a positive integer' % where)
            card["long_context"] = dict(_card(spec, multiples, where + " long_context"), above_prompt_tokens=limit)
        by_id[model] = card
        number = tuple(int(part) for part in version.split("."))
        if family not in newest or number > newest[family][0]:
            newest[family] = (number, card)
    return {"by_id": by_id, "newest": {family: card for family, (_, card) in newest.items()}}


def model_id(model):
    """A model id as the table names it: a context-window suffix (<id>[1m]) and a dated-snapshot suffix (<id>-YYYYMMDD) dropped."""
    return _DATE_SUFFIX_RE.sub("", _WINDOW_SUFFIX_RE.sub("", model or ""))


def card_for(prices, model):
    """The card of the row for exactly this model, or None."""
    return prices["by_id"].get(model_id(model))


def tier_card(prices, family):
    """The card of the newest row of a family (a bare tier alias resolves to the current generation), or None."""
    return prices["newest"].get(family)
