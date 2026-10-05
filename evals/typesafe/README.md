# evals/typesafe

One measured experiment (2026-10-05): does TypeSafe's Jev classifier beat hmd's heuristics at
(a) multi-part prompt detection and (b) closed yes/no question detection? Write-up: `docs/analysis/2026-10-05-typesafe-eval.md`.

- `run.py` the harness. `python3 evals/typesafe/run.py` = heuristic baseline + TypeSafe BLOCKED/ready status. `--selftest` checks plumbing against a local fake server.
- `dataset.jsonl` 187 prompts + 100 assistant questions: sha256(raw)[:16] id, label, scrubbed text. Raw text is not stored.
- `labels` rubric lives in the analysis doc. `excluded.json` = prompts dropped from the sample and why.
- `build_dataset.py` / `scrub.py` regenerate candidates from local transcripts (labels are hand-applied by id; they cannot be regenerated mechanically).
- `results-heuristic.json` last baseline run.

TypeSafe arm needs `TYPESAFE_API_KEY` (operator-supplied) + `--typesafe --accept-egress`. Without all three nothing is sent.
