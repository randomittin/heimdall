#!/usr/bin/env python3
"""fg_agent: supervised agent runs for Study A (PREREG.md section 8 and Amendment 1).

`supervise` starts an agent command in its own process group, hands every line it prints to a `Meter`,
and kills the whole group when the meter's spend reaches the per-run cap or the wall clock passes the
limit. The meter reads the JSON-lines stream a claude-style agent prints (`--output-format stream-json`):
it prices the token usage of every distinct assistant message at the per-token price of the model
that message names, read from the model_prices rows of bin/lib/tier-table.json. The agent's own
`total_cost_usd` (the final `result` event) is the cost of record when the run reports one; the
estimate is what the kill acts on while the run is live.

Nothing here raises on what an agent prints: a line that is not a JSON object, or a usage block that is
not numbers, is ignored. An agent that never reports usage is `unmetered`: only the wall clock applies to
it and its cost is null, never zero.
"""
from __future__ import annotations

import collections
import contextlib
import json
import os
import signal
import subprocess
import threading
import time

import hmd_model_prices

# USD per million tokens: input, 5-minute cache write, 1-hour cache write, cache read, output. None of it is
# written here: the rates are the model_prices rows of bin/lib/tier-table.json, the repo's one price table
# (bin/lib/hmd_model_prices.py), so a new generation is priced by adding a row there. A missing or malformed
# table stops this module at import, before anything is spent. PREREG.md Amendment 1 froze the table as it
# stood on 2026-10-05; test/false-green-agent-cap.test.sh fails when a row it froze moves, except the one
# correction it names. A model whose row has an unconfirmed price (a null cache read) is not in the table: it
# is priced like an unknown model, never guessed.
_TABLE = hmd_model_prices.load()


def _rates(card):
    return (card["input"], card["cache_write_5m"], card["cache_write_1h"], card["cache_read"], card["output"])


def _confirmed(card):
    """Every price of the card, and of its long-prompt card, is known."""
    return card["cache_read"] is not None and (card["long_context"] is None or card["long_context"]["cache_read"] is not None)


PRICES = {model: _rates(card) for model, card in _TABLE["by_id"].items() if _confirmed(card)}
if not PRICES:
    raise hmd_model_prices.PricesError("%s: no row has every price confirmed, so nothing can be metered" % hmd_model_prices.TABLE_PATH)
# A model that bills a second card for a long prompt (Haiku 5.5 above 100,000 prompt tokens): that length and
# that card's rates.
LONG_PROMPT = {model: (card["long_context"]["above_prompt_tokens"], _rates(card["long_context"]))
               for model, card in _TABLE["by_id"].items() if model in PRICES and card["long_context"] is not None}
# A model that is not listed is priced at the dearest listed rate in every column: an unknown model is
# killed early, never late.
FALLBACK = tuple(max(column) for column in zip(*PRICES.values()))
FAST_MULTIPLIER, US_GEO_MULTIPLIER, WEB_SEARCH_USD = 2.0, 1.1, 0.01
TAIL_LINES = 400
_FIELDS = ("in", "out", "read", "w5", "w1", "search")


def price_for(model, prompt_tokens=0):
    """((input, 5m write, 1h write, cache read, output) per million tokens, 'table' | 'fallback-highest').

    A message whose prompt (input, cache reads and cache writes) is longer than its model's long-prompt
    length is priced at that model's long-prompt card.
    """
    key = hmd_model_prices.model_id(model)
    if key not in PRICES:
        return FALLBACK, "fallback-highest"
    longer_than, long_rates = LONG_PROMPT.get(key, (None, None))
    return (long_rates if longer_than is not None and prompt_tokens > longer_than else PRICES[key]), "table"


def _num(source, key):
    value = source.get(key) if isinstance(source, dict) else None
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0 else 0


def _record(usage):
    cache = usage.get("cache_creation")
    w5, w1 = _num(cache, "ephemeral_5m_input_tokens"), _num(cache, "ephemeral_1h_input_tokens")
    w1 += max(0, _num(usage, "cache_creation_input_tokens") - w5 - w1)    # writes the usage does not split by TTL: the 1-hour rate
    return {"in": _num(usage, "input_tokens"), "out": _num(usage, "output_tokens"), "read": _num(usage, "cache_read_input_tokens"),
            "w5": w5, "w1": w1, "search": _num(usage.get("server_tool_use"), "web_search_requests"),
            "fast": usage.get("speed") == "fast", "us": usage.get("inference_geo") == "us"}


def _usage_record(usage):
    """One message's usage as counts; iterations that add up to more than the top-level numbers win."""
    top, steps = _record(usage), usage.get("iterations")
    steps = [_record(step) for step in steps if isinstance(step, dict)] if isinstance(steps, list) else []
    if steps:
        top.update({field: max(top[field], sum(step[field] for step in steps)) for field in _FIELDS})
    return top


def _merge(a, b):
    """The same message seen twice: the larger of every count, so a repeat is never added up."""
    return {key: (a[key] or b[key]) if isinstance(a[key], bool) else max(a[key], b[key]) for key in a}


def _cost(record, model):
    prompt = record["in"] + record["read"] + record["w5"] + record["w1"]      # what picks a model's card
    p_in, p_w5, p_w1, p_read, p_out = price_for(model, prompt)[0]
    usd = (record["in"] * p_in + record["w5"] * p_w5 + record["w1"] * p_w1 + record["read"] * p_read + record["out"] * p_out) / 1e6
    if record["fast"]:
        usd *= FAST_MULTIPLIER
    if record["us"]:
        usd *= US_GEO_MULTIPLIER
    return usd + record["search"] * WEB_SEARCH_USD


class Meter:
    """Spend so far, from the lines an agent prints. Safe to feed from a reader thread while another reads."""

    def __init__(self):
        self._lock = threading.Lock()
        self._messages = {}        # message id -> (model, merged usage record)
        self._anonymous = 0
        self._last_text = None
        self.result = None         # the final {"type": "result"} event, if the agent printed one
        self.reported_usd = None   # that event's total_cost_usd
        self.stopped_at_budget = False
        self.model = None          # the first model any message named

    def feed(self, line):
        try:
            event = json.loads(line)
        except ValueError:
            return
        if not isinstance(event, dict):
            return
        with self._lock:
            if event.get("type") == "assistant":
                self._assistant(event.get("message"))
            elif event.get("type") == "result":
                self._result(event)

    def _assistant(self, message):
        if not isinstance(message, dict):
            return
        model = message.get("model") if isinstance(message.get("model"), str) else None
        self.model = self.model or model
        content = message.get("content")
        text = "\n".join(block["text"] for block in content if isinstance(block, dict) and isinstance(block.get("text"), str)) if isinstance(content, list) else ""
        self._last_text = text or self._last_text
        usage = message.get("usage")
        if not isinstance(usage, dict):
            return
        ident = message.get("id")
        if not isinstance(ident, str):
            self._anonymous += 1               # no id: counted on its own, never merged into another message
            ident = "anonymous-%d" % self._anonymous
        record = _usage_record(usage)
        held = self._messages.get(ident)
        self._messages[ident] = (held[0] or model, _merge(held[1], record)) if held else (model, record)

    def _result(self, event):
        self.result = event
        cost = event.get("total_cost_usd")
        if isinstance(cost, (int, float)) and not isinstance(cost, bool) and cost >= 0:
            self.reported_usd = float(cost)
        if event.get("subtype") == "error_max_budget_usd":
            self.stopped_at_budget = True

    @property
    def estimate_usd(self):
        with self._lock:
            return sum(_cost(record, model) for model, record in self._messages.values())

    @property
    def spend_usd(self):
        """What the kill acts on: the dearer of the estimate and the agent's own total."""
        return max(self.estimate_usd, self.reported_usd or 0.0)

    @property
    def metered(self):
        return bool(self._messages) or self.reported_usd is not None

    @property
    def cost_usd(self):
        """The cost of record: the agent's own total, else the estimate, else None (never 0 for an unknown)."""
        if self.reported_usd is not None:
            return self.reported_usd
        return round(self.estimate_usd, 6) if self._messages else None

    @property
    def cost_source(self):
        return "agent-reported" if self.reported_usd is not None else ("estimated-from-usage" if self._messages else "unmetered")

    @property
    def price_basis(self):
        with self._lock:
            bases = {price_for(model)[1] for model, _record in self._messages.values()}
        return None if not bases else ("fallback-highest" if "fallback-highest" in bases else "table")

    @property
    def tokens(self):
        with self._lock:
            records = [record for _model, record in self._messages.values()]
        if not records:
            return {"in": None, "out": None}
        total = lambda field: int(sum(record[field] for record in records))
        return {"in": total("in") + total("read") + total("w5") + total("w1"), "out": total("out"),
                "cache_read": total("read"), "cache_write": total("w5") + total("w1")}

    @property
    def final_text(self):
        """The agent's final answer: its result event's text, else its last message's text, else None."""
        if self.result is not None and isinstance(self.result.get("result"), str):
            return self.result["result"]
        return self._last_text


Outcome = collections.namedtuple("Outcome", "rc stdout stderr killed elapsed_s fault")


def _kill_group(proc):
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(proc.pid, signal.SIGKILL)


def _kill_reason(meter, faults, cap_usd, seconds_left):
    if faults:
        return "fault"
    if meter.spend_usd >= cap_usd:
        return "cap"
    return "timeout" if seconds_left <= 0 else None


def supervise(cmd, cwd, meter, cap_usd, timeout_s, env=None, poll_s=0.1):
    """Run `cmd` in its own process group and return an Outcome.

    `killed` is None, "cap" (the meter's spend reached `cap_usd`), "timeout" (`timeout_s` of wall clock) or
    "fault" (the meter raised: a run whose spend cannot be read is not left running). The whole group is
    killed in each case, and again once the agent exits, so nothing it started outlives its run. If this
    function is itself interrupted or fails, the group is killed before the error propagates.
    """
    started = time.monotonic()
    try:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, encoding="utf-8", errors="replace", start_new_session=True)
    except OSError as exc:
        return Outcome(127, "", str(exc), None, 0.0, None)
    out_tail, err_tail, faults = collections.deque(maxlen=TAIL_LINES), collections.deque(maxlen=TAIL_LINES), []

    def pump(stream, tail, feed):
        for line in stream:
            tail.append(line)
            if feed:
                try:
                    feed(line)
                except Exception as exc:       # keep draining the pipe; the supervisor kills the run
                    faults.append(repr(exc))

    readers = [threading.Thread(target=pump, args=(proc.stdout, out_tail, meter.feed), daemon=True),
               threading.Thread(target=pump, args=(proc.stderr, err_tail, None), daemon=True)]
    for reader in readers:
        reader.start()
    killed = None
    try:
        while killed is None:
            try:
                proc.wait(timeout=poll_s)
                break
            except subprocess.TimeoutExpired:
                killed = _kill_reason(meter, faults, cap_usd, timeout_s - (time.monotonic() - started))
        if killed:
            _kill_group(proc)
            proc.wait()
    except BaseException:
        _kill_group(proc)
        proc.wait()
        raise
    _kill_group(proc)
    for reader in readers:
        reader.join(timeout=5)
    return Outcome(proc.returncode, "".join(out_tail), "".join(err_tail), killed, time.monotonic() - started, faults[0] if faults else None)
