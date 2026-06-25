# cp_state Migration Recipe — putting a store behind StateBackend (Wave 1)

This is the **frozen contract** for Wave 1. Every remaining store migrates onto
`bin/lib/cp_state.py`'s `StateBackend` exactly as `cp_jobstore.py` (the Wave-0
reference) did. Follow this verbatim — the whole point of freezing the interface
first is that all 5 stores bind to the SAME contract so a Wave-2 `FirestoreBackend`
makes every store durable at once.

## The frozen interface (do NOT change cp_state.py)

```python
StateBackend.append_line(rel, record, *, fsync=False) -> bool   # append-only NDJSON line
StateBackend.read_lines(rel) -> list[dict]                      # tolerant NDJSON scan, store order
StateBackend.put_record(rel, record) -> bool                   # atomic keyed JSON (tmp+os.replace, indent=2)
StateBackend.get_record(rel) -> dict | None                    # read one keyed record
StateBackend.list_names(rel_dir, *, suffix="") -> list[str]    # sorted names under a store dir
StateBackend.exists(rel) -> bool
StateBackend.path(rel) -> str                                  # absolute fs path (LocalBackend)
```

- Every `rel` is **relative to `${HEIMDALL_HOME}/control-plane/`**. Pass only your
  store's sub-path: `"audit/audit.ndjson"`, `"approvals/<id>.json"`, etc. The backend
  owns the home root + `makedirs`.
- Get your backend once per call path: `backend = cp_state.get_backend(home=home)`.
  Thread the store's existing `home=` arg straight through — do not re-derive
  `heimdall_home()` yourself anymore.
- `append_line` uses `json.dumps(sort_keys=True, separators=(",",":"))`. `put_record`
  uses `json.dump(sort_keys=True, indent=2)`. These reproduce current bytes — do not
  hand-roll serialization.

## Migration steps (per store)

1. `import cp_state` at the top (alongside the existing `issue_queue` import).
2. Add a small `_backend(home=None)` helper: `return cp_state.get_backend(home=home)`.
3. Replace each **direct file IO** with the matching backend call:
   - `open(p,"a")...write(json.dumps(...)+"\n")`  → `backend.append_line(rel, record, fsync=<keep current>)`
   - the NDJSON read/parse loop                    → `backend.read_lines(rel)`
   - `tmp + os.replace` keyed write                → `backend.put_record(rel, record)`
   - `json.load(open(p))` keyed read               → `backend.get_record(rel)`
   - `sorted(os.listdir(dir))` (+suffix filter)    → `backend.list_names(rel_dir, suffix=...)`
   - `os.path.exists(p)`                           → `backend.exists(rel)`
   - any `*_path()` accessor returning an abs path → `backend.path(rel)` (keep the
     accessor's public signature; just source the path from the backend)
4. **Preserve fsync discipline exactly**: only the jobstore passes `fsync=True`. If your
   store flushed-only today, call `append_line(..., fsync=False)` (the default). Do not
   add or drop an fsync.
5. **Preserve store order + tolerance**: do not sort read_lines output, do not raise on a
   bad line — `read_lines` already skips bad/absent. Match today's behavior.
6. Do NOT touch any other store, cp_server, cp_boot, or the Dockerfile. One store per
   agent, disjoint files (R1).

## Per-store map (your rel keys + which methods)

| Store (file) | rel namespace | methods used |
|---|---|---|
| **cp_jobstore.py** (DONE, reference) | `jobs/<job-id>.ndjson` | append_line(fsync=True), read_lines, list_names("jobs/", ".ndjson") |
| cp_audit.py | `audit/audit.ndjson` | append_line(flush-only), read_lines (search/export) |
| cp_approval.py | `approvals/<action-id>.json` | put_record, get_record, list_names("approvals/", ".json") |
| cp_notify.py | `notify/<inbox>.ndjson` (confirm exact path in-file) | append_line(flush-only), read_lines (poll inbox) |
| cp_scheduler.py | schedule log/dir (confirm exact path in-file) | append_line, read_lines, list_names (fold) |
| cp_observe.py / cp_ingest.py | `observe/<slug>/events.ndjson` | append_line, read_lines, list_names (stored_instances) |

Confirm your store's EXACT current on-disk path by reading the store before migrating —
the rel key MUST resolve to the same file the store writes today (byte-identity).

## Acceptance (every Wave-1 store)

- Your store's suite stays green **byte-identically** (the files written are unchanged):
  e.g. `bash test/cp-audit*.test.sh` — but the real proof is the whole suite:
  `for f in test/cp-*.test.sh; do bash "$f"; done` → all 10 suites green (222 total).
- `grep -n "open(" your_store.py` shows no remaining direct store-file IO (the backend
  owns it). The only `open()` left should be unrelated (e.g. reading a PKI key, not a store).
- `bin/secret-scan` clean.

## What Wave 2 does (context, not your job)

After all 6 stores are on `StateBackend`, Wave 2 adds `FirestoreBackend` (same 7 methods,
durable external persistence) + the **falsifiable durability gate**: write a job via
"instance A" backend → drop it → a fresh "instance B" backend reads the job state from the
external store → job still resolvable. LocalBackend with a per-instance home FAILS this
(state lost on simulated scale-to-zero); FirestoreBackend PASSES. That contrast is the
proof the durability gap is closed.
