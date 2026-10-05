#!/usr/bin/env python3
"""fg_agent: supervised agent runs for Study A (PREREG.md section 8 and Amendment 1).

`supervise` starts an agent command in its own process group, hands every line it prints to a `Meter`,
and kills the whole group when the meter's spend reaches the per-run cap or the wall clock passes the
limit. The meter reads the JSON-lines stream a claude-style agent prints (`--output-format stream-json`):
it prices the token usage of every distinct assistant message at the published per-token price of the
model that message names. The agent's own `total_cost_usd` (the final `result` event) is the cost of
record when the run reports one; the estimate is what the kill acts on while the run is live.

Nothing here raises on what an agent prints: a line that is not a JSON object, or a usage block that is
not numbers, is ignored. An agent that never reports usage is `unmetered`: only the wall clock applies to
it and its cost is null, never zero.
"""
from __future__ import annotations

import collections
import contextlib
import json
import os
import re
import signal
import subprocess
import threading
import time

# USD per million tokens: input, 5-minute cache write, 1-hour cache write, cache read, output.
# Published prices (platform.claude.com/docs/en/about-claude/pricing), read 2026-10-05. The same table is
# frozen in PREREG.md Amendment 1; test/false-green-agent-cap.test.sh fails when the two differ.
PRICES = {
    "claude-fable-5-1": (10.0, 12.5, 20.0, 0.25, 50.0),
    "claude-fable-5": (10.0, 12.5, 20.0, 1.0, 50.0),
    "claude-opus-5-5": (4.0, 5.0, 8.0, 0.2, 20.0),
    "claude-opus-5": (5.0, 6.25, 10.0, 0.5, 25.0),
    "claude-opus-4-8": (5.0, 6.25, 10.0, 0.5, 25.0),
    "claude-opus-4-7": (5.0, 6.25, 10.0, 0.5, 25.0),
    "claude-opus-4-6": (5.0, 6.25, 10.0, 0.5, 25.0),
    "claude-opus-4-5": (5.0, 6.25, 10.0, 0.5, 25.0),
    "claude-sonnet-5-5": (2.0, 2.5, 4.0, 0.2, 10.0),
    "claude-sonnet-5": (2.0, 2.5, 4.0, 0.2, 10.0),
    "claude-sonnet-4-6": (3.0, 3.75, 6.0, 0.3, 15.0),
    "claude-sonnet-4-5": (3.0, 3.75, 6.0, 0.3, 15.0),
    "claude-haiku-4-5": (1.0, 1.25, 2.0, 0.1, 5.0),
}
# A model that is not listed is priced at the dearest listed rate in every column: an unknown model is
# killed early, never late.
FALLBACK = tuple(max(column) for column in zip(*PRICES.values()))
FAST_MULTIPLIER, US_GEO_MULTIPLIER, WEB_SEARCH_USD = 2.0, 1.1, 0.01
TAIL_LINES = 400
_FIELDS = ("in", "out", "read", "w5", "w1", "search")


def _model_key(model):
    key = re.sub(r"\[[^\]]*\]$", "", model or "")      # claude-opus-5-5[1m] -> claude-opus-5-5
    return re.sub(r"-\d{8}$", "", key)                  # claude-opus-4-5-20251101 -> claude-opus-4-5


def price_for(model):
    """((input, 5m write, 1h write, cache read, output) per million tokens, 'table' | 'fallback-highest')."""
    key = _model_key(model)
    return (PRICES[key], "table") if key in PRICES else (FALLBACK, "fallback-highest")


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
    p_in, p_w5, p_w1, p_read, p_out = price_for(model)[0]
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
