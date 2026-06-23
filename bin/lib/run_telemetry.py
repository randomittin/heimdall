#!/usr/bin/env python3
# run_telemetry.py — piece (c) of the Heimdall telemetry layer: the PER-RUN
# instrumentation helpers + the summary-card fill query. It is the run-time half
# of the layer — installs are piece (b), aggregation is piece (d), holdout is (e).
#
# DESIGN DOSSIER §4/§8 (authoritative). This module:
#
#   • EMITS the five per-run event kinds the orchestrator/launcher produces, each a
#     thin call onto the ONE substrate surface (bin/lib/telemetry.py, piece a — we
#     BIND it, never re-implement the store): a phase boundary, a gate verdict, the
#     run's token usage (copied VERBATIM from bin/heimdall-tokens), the task
#     outcome, and one event per atomic commit the run produced. ONE run_id
#     (telemetry.new_run_id()) correlates them all.
#
#   • READS them back to FILL THE SUMMARY CARD (the acceptance, §4): card_data()
#     queries events for a run_id, SUMS the token events' total_tokens and COUNTS
#     the commit events, so the renderer in bin/summary-card shows REAL numbers
#     instead of the degrade-to-"—" default. card_state() materializes those real
#     figures into a heimdall-state.json budget block — the data source the
#     existing renderer already reads (renderer logic untouched; only the data
#     source swaps from the unfilled default to this telemetry query).
#
#   • HONESTY (§6, critical): the card fill carries the MEASURED total_tokens and
#     the token event's cost_source provenance ONLY. It NEVER authors a fabricated
#     "vs raw-CC" savings number — that comparison is piece (e)'s measured-holdout
#     job. We write what we measured; we never assert a delta we did not measure.
#
#   • GRACEFUL (§8): every emit goes through telemetry.emit, which is fire-and-
#     forget and never raises; disabled (HEIMDALL_TELEMETRY=off / opt-out marker)
#     ⇒ every emit is a no-op and card_data returns the honest-empty shape, so a
#     disabled run + its card behave IDENTICALLY to a no-telemetry world (the card
#     degrades to "—" exactly as before — no regression). stdlib-only.
#
# This is a LIBRARY; the CLI core at the bottom is what bin/heimdall-demo (bash)
# shells out to (house style: a thin bin/* CLI over a bin/lib/*.py engine).

from __future__ import annotations

import json
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import telemetry  # piece (a), on main — the ONE event surface. BIND, never rebuild.

# The token meter we REUSE verbatim (§4: copy its JSON into the token event, never
# re-parse claude usage ourselves, never invent a cost). bin/ is the parent of lib/.
_BIN_DIR = os.path.dirname(_HERE)
_TOKENS_BIN = os.path.join(_BIN_DIR, "heimdall-tokens")


# ── per-run emitters (§4 fire-points) — each a thin call onto telemetry.emit ──


def emit_phase(run_id, phase, outcome, *, duration_ms=None, home=None):
    """A planning→waves→gates phase boundary. outcome is started|succeeded|failed
    (the coarse lifecycle marker). Returns telemetry.emit's bool (False when
    disabled / dropped); never raises."""
    return telemetry.emit(
        "phase", run_id=run_id, phase=phase, outcome=outcome,
        duration_ms=duration_ms, home=home,
    )


def emit_gate(run_id, gate, outcome, *, loc=None, phase=None, home=None):
    """A gate verdict: which gate fired + passed|failed|blocked, with the file:line
    it fired at (loc) for the deny→fix→pass arc. Reuses the SAME outcome the gate
    itself produced — no new verdict source (§2/§4)."""
    return telemetry.emit(
        "gate", run_id=run_id, gate=gate, outcome=outcome, loc=loc,
        phase=phase, home=home,
    )


def emit_token(run_id, tokens, *, home=None):
    """The run's token usage — ONE per run. `tokens` is the bin/heimdall-tokens
    record, copied VERBATIM into the event (§4). The substrate keeps only the known
    numeric/provenance keys (defence in depth); we never fabricate a cost here."""
    return telemetry.emit("token", run_id=run_id, tokens=tokens, home=home)


def emit_outcome(run_id, outcome, *, error=None, home=None):
    """The task outcome at run end: passed|failed, with an optional error SHAPE
    object (class/step/detail — never a payload). Returns the emit bool."""
    return telemetry.emit("outcome", run_id=run_id, outcome=outcome,
                          error=error, home=home)


def emit_commit(run_id, commit, *, home=None):
    """One event per atomic commit the run produced (R7: one commit/task). The
    COUNT of these fills the card's commits field. `commit` is a short SHA."""
    return telemetry.emit("commit", run_id=run_id, commit=commit, home=home)


# ── the token-meter reuse (§4: copy bin/heimdall-tokens JSON verbatim) ────────


def measure_tokens(*, cwd=None, session_path=None, emitted_path=None):
    """Run bin/heimdall-tokens and return its parsed record (the verbatim token
    object the token event carries). REUSE — we never re-parse claude usage here.

    Picks the mode from what the caller has: an emitted source record, an explicit
    session JSONL, or the newest session for a cwd. Fail-open like the meter: on
    any failure returns None (the caller simply skips the token event — the card
    then honestly shows "—" rather than a fabricated number). NEVER raises."""
    if not os.path.isfile(_TOKENS_BIN):
        return None
    if emitted_path:
        argv = ["emitted", emitted_path]
    elif session_path:
        argv = ["session", session_path]
    elif cwd:
        argv = ["session", "--cwd", cwd]
    else:
        return None
    try:
        proc = subprocess.run(
            [sys.executable, _TOKENS_BIN, *argv],
            capture_output=True, text=True, timeout=30,
        )
        if not proc.stdout.strip():
            return None
        rec = json.loads(proc.stdout)
        return rec if isinstance(rec, dict) else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


# ── the card-fill query (§4 — the acceptance: REAL tokens + commits) ──────────


def card_data(run_id, *, home=None):
    """Read this run's events and reduce them to the figures the summary card
    needs: the SUMMED token total, the COMMIT count, and the token event's
    cost_source provenance (honest — never a fabricated savings figure).

    Returns a dict:
      {"run_id", "total_tokens"|None, "commits", "cost_source"|None,
       "total_cost_usd"|None, "has_tokens": bool}
    `total_tokens` is None when the run produced no token event (the honest-empty
    shape ⇒ the card degrades to "—"). Read-only; tolerant of partial events;
    never raises into the caller (a read failure yields the empty shape)."""
    empty = {
        "run_id": run_id,
        "total_tokens": None,
        "commits": 0,
        "cost_source": None,
        "total_cost_usd": None,
        "has_tokens": False,
    }
    try:
        events = telemetry.read_events(home=home, run_id=run_id)
    except Exception:  # noqa: BLE001 — a read fault degrades to the empty shape (§8)
        return empty
    token_total = 0
    saw_token = False
    cost_source = None
    cost_usd = None
    commits = 0
    for e in events:
        et = e.get("event_type")
        if et == "token":
            tk = e.get("tokens") or {}
            tt = tk.get("total_tokens")
            if isinstance(tt, (int, float)):
                token_total += int(tt)
                saw_token = True
            # carry the provenance + measured cost through (last token event wins).
            if tk.get("cost_source") is not None:
                cost_source = tk.get("cost_source")
            if isinstance(tk.get("total_cost_usd"), (int, float)):
                cost_usd = tk.get("total_cost_usd")
        elif et == "commit":
            commits += 1
    if not saw_token:
        out = dict(empty)
        out["commits"] = commits
        return out
    return {
        "run_id": run_id,
        "total_tokens": token_total,
        "commits": commits,
        "cost_source": cost_source,
        "total_cost_usd": cost_usd,
        "has_tokens": True,
    }


def card_state(run_id, project, *, home=None, gates=None):
    """Materialize a heimdall-state.json under `project` from REAL telemetry so the
    existing bin/summary-card renderer fills the tokens field from measured data
    (its data source swaps from the unfilled default to this query — the renderer
    logic is untouched). Returns the written dict, or None when nothing real to
    write (disabled / no token event ⇒ NO budget written ⇒ the card stays "—",
    no regression, §8).

    `gates` is an optional {tests_passing, lint_clean, dirty} block the demo's
    deny→fix→pass arc already computes; it is preserved verbatim (the gate verdict
    is the gate's, not ours). HONESTY (§6): we write the MEASURED total_tokens and
    its cost_source provenance ONLY — never a fabricated "vs raw-CC" savings key."""
    data = card_data(run_id, home=home)
    state = {}
    if isinstance(gates, dict) and gates:
        state["quality_gates"] = gates
    if data["has_tokens"]:
        budget = {"total_tokens": data["total_tokens"]}
        # provenance travels with the number (honesty); cost only when measured.
        if data["cost_source"] is not None:
            budget["cost_source"] = data["cost_source"]
        if data["total_cost_usd"] is not None:
            budget["total_cost_usd"] = data["total_cost_usd"]
        state["budget"] = budget
    if not state:
        return None  # nothing real to write — the card degrades to "—" (§8)
    try:
        path = os.path.join(project, "heimdall-state.json")
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(state, fh, sort_keys=True, indent=2)
            fh.write("\n")
        os.replace(tmp, path)  # atomic publish (mirrors the issue_queue discipline)
        return state
    except OSError:
        return None  # write fault degrades — never fails the run (§8)


# ── CLI core (driven by bin/heimdall-demo / the orchestrator bash) ────────────


def _cli(argv):
    """CLI core. Subcommands mirror the emitter + reader surface so bash callers
    (bin/heimdall-demo) drive the per-run instrumentation without re-implementing
    it. Every emit subcommand prints {"emitted": bool} and exits 0 — telemetry
    NEVER gates the caller (§8). The read subcommands print JSON for the card.

      new-run-id
      phase   --run-id R --phase P --outcome O [--duration-ms N] [--home H]
      gate    --run-id R --gate G --outcome O [--loc F:L] [--phase P] [--home H]
      token   --run-id R (--tokens JSON|@file | --cwd DIR | --session F
                          | --emitted F) [--home H]
      outcome --run-id R --outcome O [--error-class C --error-step S
                          --error-detail D] [--home H]
      commit  --run-id R --commit SHA [--home H]
      card-data  --run-id R [--home H]          → JSON figures for the card
      card-state --run-id R --project DIR [--home H] [--gates JSON|@file]
                                               → writes heimdall-state.json
    """
    import argparse

    p = argparse.ArgumentParser(prog="run_telemetry", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--run-id", dest="run_id")
    p.add_argument("--phase")
    p.add_argument("--gate")
    p.add_argument("--outcome")
    p.add_argument("--loc")
    p.add_argument("--duration-ms", dest="duration_ms", type=int)
    p.add_argument("--commit")
    p.add_argument("--tokens")
    p.add_argument("--cwd")
    p.add_argument("--session")
    p.add_argument("--emitted")
    p.add_argument("--error-class", dest="error_class")
    p.add_argument("--error-step", dest="error_step")
    p.add_argument("--error-detail", dest="error_detail")
    p.add_argument("--project")
    p.add_argument("--gates")
    p.add_argument("--home")
    args = p.parse_args(argv)
    sub = args.subcommand

    if sub == "new-run-id":
        print(telemetry.new_run_id())
        return 0

    if sub == "phase":
        wrote = emit_phase(args.run_id, args.phase, args.outcome,
                           duration_ms=args.duration_ms, home=args.home)
        print(json.dumps({"emitted": bool(wrote)}))
        return 0

    if sub == "gate":
        wrote = emit_gate(args.run_id, args.gate, args.outcome,
                          loc=args.loc, phase=args.phase, home=args.home)
        print(json.dumps({"emitted": bool(wrote)}))
        return 0

    if sub == "token":
        tokens = None
        if args.tokens:
            tokens = _read_json_arg(args.tokens)
        elif args.emitted or args.session or args.cwd:
            tokens = measure_tokens(
                cwd=args.cwd, session_path=args.session,
                emitted_path=args.emitted,
            )
        wrote = emit_token(args.run_id, tokens, home=args.home) if tokens else False
        print(json.dumps({"emitted": bool(wrote)}))
        return 0

    if sub == "outcome":
        error = None
        if args.error_class or args.error_step or args.error_detail:
            error = {
                "class": args.error_class,
                "step": args.error_step,
                "detail": args.error_detail,
            }
        wrote = emit_outcome(args.run_id, args.outcome, error=error,
                             home=args.home)
        print(json.dumps({"emitted": bool(wrote)}))
        return 0

    if sub == "commit":
        wrote = emit_commit(args.run_id, args.commit, home=args.home)
        print(json.dumps({"emitted": bool(wrote)}))
        return 0

    if sub == "card-data":
        print(json.dumps(card_data(args.run_id, home=args.home), sort_keys=True))
        return 0

    if sub == "card-state":
        gates = _read_json_arg(args.gates) if args.gates else None
        state = card_state(args.run_id, args.project, home=args.home,
                           gates=gates if isinstance(gates, dict) else None)
        print(json.dumps({"written": state is not None}))
        return 0

    print(json.dumps({"error": "unknown subcommand: %s" % sub}))
    return 2


def _read_json_arg(value):
    """A JSON CLI arg is inline JSON or @path-to-file. On any parse failure returns
    None (the field is simply omitted — telemetry never fails the caller, §8)."""
    try:
        if value.startswith("@"):
            with open(value[1:], "r", encoding="utf-8") as fh:
                return json.load(fh)
        return json.loads(value)
    except (OSError, ValueError, TypeError):
        return None


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
