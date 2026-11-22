# Stack Pack — `fastapi`

Cold-start knowledge for a role agent working on a FastAPI project. Repo-specific
refinements live in `.planning/skills/` and layer on top of this pack.

---

## Section 1 — Stack ID & Detection Signals

- **Stack id:** `fastapi`
- **Detected from:** `requirements.txt` or `pyproject.toml` whose contents
  contain the string `fastapi` (dependency declaration, e.g. `fastapi>=0.111`
  or `fastapi = "^0.111"` in a `[tool.poetry.dependencies]` block).
- **Disambiguation:** a Python project whose manifests reference `django` or
  `flask` but also `fastapi` resolves as `fastapi` (more specific). A Python
  project with none of those three resolves as `python`.

---

## Section 2 — Directory Layout Conventions

```
app/
  __init__.py
  main.py             # FastAPI() instance, middleware, lifespan, router includes
  deps.py             # Depends() factories (DB session, current user, …)
  routers/
    __init__.py
    items.py          # APIRouter per domain; prefix + tags declared here
    users.py
  models/
    __init__.py
    item.py           # SQLAlchemy ORM models (table definitions)
    user.py
  schemas/
    __init__.py
    item.py           # Pydantic v2 request/response models (BaseModel subclasses)
    user.py
  services/
    __init__.py
    item_service.py   # Business logic; no direct HTTP types, no DB sessions leaked out
    user_service.py
  clients/
    __init__.py
    payments.py       # One adapter per EXTERNAL system (payments, maps, email, LLM); the seam a fake replaces
  db.py               # Engine + SessionLocal + Base; get_db() dependency lives here
alembic/
  env.py
  versions/           # Auto-generated migration scripts
alembic.ini
tests/
  use_cases/          # THE GATE: one scenario per user journey, entered through the HTTP route
    conftest.py       # real app + disposable sqlite; fakes wired in via app.dependency_overrides
    fakes/            # one fake per external system; implements the client's interface, records calls
      payments.py
    test_<journey>.py # test_book_a_cab, test_declined_card_books_nothing (the user's words)
  conftest.py         # shared fixtures: TestClient, override_get_db, test DB setup
  test_<module>.py    # optional: pins one specific bug; never a gate
requirements.txt      # or pyproject.toml (poetry/uv)
.env                  # DATABASE_URL and secrets — never committed
```

Rules for adding files:
- New domain → new `routers/<domain>.py` + `schemas/<domain>.py`; if DB-backed
  add `models/<domain>.py` and an Alembic migration.
- Business logic goes in `services/`, not inside route functions.
- `deps.py` owns all `Depends()` factories. Do not inline dependency logic in
  route signatures.
- Pydantic schemas and SQLAlchemy models are kept in separate modules (`schemas/`
  vs `models/`) — never merge them.
- A new user-facing capability → a scenario `test_<journey>` in `tests/use_cases/`,
  not a new per-router test file.
- A new external system (payments, maps, email, LLM) → one adapter in `clients/`
  (injected with `Depends()`) and one fake in `tests/use_cases/fakes/`.

---

## Section 3 — Lint / Format / Test / Build Commands

FastAPI projects are typically run with `uvicorn`; packaging is via `pip`,
`uv`, or `poetry`. Commands below assume `ruff` for lint/format, `pytest` for
tests, and `mypy` for type checking — the current (2026) idiomatic Python toolchain.

### Install

```bash
# plain pip
pip install -r requirements.txt

# uv (preferred — faster, reproducible)
uv sync

# poetry
poetry install
```

### Run

```bash
uvicorn app.main:app --reload
# custom host/port
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

### Test — the gate is the use-case suite

The gate is `lint` + the use-case suite: one scenario per user journey, entered
through the HTTP route a client calls, real code down to a real (disposable
sqlite) database, fakes only at the external boundaries (payments, maps, email,
OAuth, the LLM, the clock). See `skills/heimdall/references/use-case-tests.md`.

```bash
# use-case suite (the gate): pytest exits 5 when it collects nothing, so an empty suite FAILS
pytest tests/use_cases -q

# one journey, named in the user's words
pytest tests/use_cases -q -k test_book_a_cab
```

Never add `|| true` or `--suppress-no-test-exit-code` to a gate: a use-case run
that collects zero tests must fail.

During work, run only the tests of the files you touched, once, after all
changes are written. These pin a specific bug and are not a gate:

```bash
# single test file
pytest -q tests/test_items.py

# single test by name
pytest -q -k "test_create_item_returns_201"
```

Do not gate on the whole suite (`pytest -q`) or on coverage (`--cov`): neither
proves a journey works.

Scenarios use `httpx.AsyncClient` or `starlette.testclient.TestClient` (sync),
never a live server. The DB dependency is overridden with a disposable sqlite
database (still a real one); each external-system client is overridden with its
fake: `app.dependency_overrides[get_payments] = lambda: fake_payments`.

### Lint / Format

```bash
# check lint (exit non-zero on violations)
ruff check .

# apply lint fixes
ruff check --fix .

# format (ruff replaces black for new projects)
ruff format .

# check format without writing (CI mode)
ruff format --check .

# if the project uses black instead
black --check .
black .
```

### Type Check

```bash
mypy app
# strict mode if configured
mypy --strict app
```

### Gate declaration

`.heimdall/repo-checks.json`, committed (each `cmd` runs with `bash -c` from the
repo root). Append `&& mypy app` to `lint` when `mypy` is a dev dependency.
Nothing else gates the repo: no full-suite or coverage check.

```json
{"schema":1,"checks":[
  {"name":"lint","cmd":"ruff check . && ruff format --check ."},
  {"name":"use-cases","cmd":"pytest tests/use_cases -q"}
]}
```

### Migrations (Alembic)

```bash
# generate migration after changing a model
alembic revision --autogenerate -m "add users table"

# apply all pending migrations
alembic upgrade head

# roll back one
alembic downgrade -1
```

---

## Section 4 — Acceptance-Criteria Templates

Drop these into a plan unchanged; each is a command a reviewer can run and read
the exit code of. The gate is the first group: `lint` + `use-cases`.

### Gate: `lint` + `use-cases`

- `ruff check . && ruff format --check .` exits 0 — the `lint` check: no lint
  violations, code is formatted.
- `pytest tests/use_cases -q` exits 0 and ends with `N passed`, N >= 1 — the
  `use-cases` check (exit 5 means nothing was collected: a failure).
- For each journey the plan names, `pytest tests/use_cases -q -k test_<journey>`
  exits 0 — the scenario exists and passes (a missing one selects nothing, exit 5).
- Scenarios enter through HTTP, never through the repo's internals:
  `grep -rnE "from app\.(routers|services)|import app\.(routers|services)" tests/use_cases/test_*.py`
  returns no lines.
- Fakes sit only at external boundaries; the repo's own code is never patched:
  `grep -rnE "(monkeypatch\.setattr|patch)\(['\"]?app\.(routers|services|models|schemas)" tests/use_cases/`
  returns no lines.
- No scenario is skipped or expected to fail:
  `grep -rnE "mark\.(skip|xfail)|pytest\.(skip|xfail)|importorskip" tests/use_cases/`
  returns no lines.
- Each scenario asserts what the caller sees, not only that the call returned:
  `grep -q "status_code\|\.json()" tests/use_cases/test_<journey>.py` exits 0.

### Code shape and runtime

- Request and response types are Pydantic `BaseModel` subclasses, not plain
  `dict`: `grep -rn "-> dict" app/routers/` returns no lines.
- Every route function that returns a body has an explicit `response_model`
  declared on its decorator:
  `grep -n "@router\.\|@app\." app/routers/*.py | grep -v "response_model"` returns
  no route decorators missing it (after excluding intentional `Response` returns).
- `mypy app` exits 0 (when `mypy` is present in dev dependencies).
- `alembic upgrade head` exits 0 on a clean test DB — all migrations apply cleanly.
- `curl -s -o /dev/null -w '%{http_code}' localhost:8000/docs` returns `200`
  after `uvicorn app.main:app` starts — OpenAPI schema is reachable.

---

## Section 5 — Common Failure Patterns + Fixes

- **Symptom:** endpoint is slow or blocks the event loop under load.
  **Cause:** a `def` (sync) route function calls blocking I/O (DB query, file
  read, `requests.get`) directly on the async event loop thread.
  **Fix:** declare the route `async def` and use an async driver (e.g.
  `asyncpg`, `aiosqlite`, `httpx.AsyncClient`), or keep `def` (FastAPI runs sync
  routes in a thread-pool automatically via `run_in_threadpool`) — the error is
  using `async def` with a blocking library that starves the loop.

- **Symptom:** `AttributeError: 'MyModel' object has no attribute 'dict'` or
  validation behaves differently from docs.
  **Cause:** Pydantic v1 code running against Pydantic v2.
  **Fix:** replace `.dict()` → `.model_dump()`, `.json()` → `.model_dump_json()`,
  `orm_mode = True` → `model_config = ConfigDict(from_attributes=True)`,
  `@validator` → `@field_validator`, `schema_extra` → `json_schema_extra`.

- **Symptom:** `sqlalchemy.exc.MissingGreenlet` or detached-instance errors when
  reading relationships outside a request.
  **Cause:** DB session closed before lazy-loaded relationship is accessed, or
  session not properly scoped to the request lifecycle.
  **Fix:** use `Depends(get_db)` on every route that touches the DB; ensure
  `get_db` is a generator that closes the session in its `finally` block. For
  relationships needed in the response, either eagerly load them
  (`options(joinedload(...))`) or access them within the session scope.

- **Symptom:** N+1 queries — one query per row when fetching a list with a
  related field.
  **Cause:** accessing a lazy relationship inside a loop after the list query.
  **Fix:** use `joinedload` or `selectinload` in the list query:
  `db.scalars(select(Item).options(selectinload(Item.tags))).all()`.

- **Symptom:** `422 Unprocessable Entity` returned for requests that look correct.
  **Cause:** request body or query parameter does not satisfy the Pydantic schema
  (wrong type, missing required field, failed validator).
  **Fix:** check the `detail` array in the 422 response body — it lists every
  field and why it failed. Add a `TestClient` test reproducing the payload to
  lock in the contract.

- **Symptom:** CORS errors in the browser; preflight `OPTIONS` returns 400 or
  missing headers.
  **Cause:** `CORSMiddleware` not added to the app, or origins list is too
  restrictive.
  **Fix:** add to `main.py`:
  ```python
  from fastapi.middleware.cors import CORSMiddleware
  app.add_middleware(
      CORSMiddleware,
      allow_origins=["https://yourdomain.com"],  # never "*" in production
      allow_credentials=True,
      allow_methods=["*"],
      allow_headers=["*"],
  )
  ```

- **Symptom:** background task runs but DB writes are not visible / session is
  already closed.
  **Cause:** `BackgroundTasks` receives a DB session from the request scope; the
  session closes when the response is sent, before the background task runs.
  **Fix:** for lightweight fire-and-forget work, open a new session inside the
  background function. For durable, retriable work (anything that must not be
  lost on process restart) use a task queue (Celery + Redis/RabbitMQ, or
  `arq`) instead of `BackgroundTasks`.

- **Symptom:** `ImportError` or circular imports between `models/`, `schemas/`,
  and `routers/`.
  **Cause:** a schema imports from a router or a model imports from a service,
  creating a cycle.
  **Fix:** enforce a strict dependency direction: `routers` → `services` →
  `models`/`schemas`; `schemas` and `models` never import from `routers` or
  `services`. Use `TYPE_CHECKING` guards for type-only imports where needed.

- **Symptom:** `alembic upgrade head` fails with `Can't locate revision` or
  produces duplicate migration heads.
  **Cause:** two developers generated migrations from the same base revision
  (branching conflict).
  **Fix:** run `alembic merge heads -m "merge"` to create a merge migration,
  then `alembic upgrade head`.

---

## Layering Note

This pack is the generic cold-start scaffold for any FastAPI project. Once Heimdall
has worked in a specific repo it accumulates learned patterns (custom test flags,
non-standard directory names, project-specific failure modes) under
`.planning/skills/`. Those files layer on top of this pack and take precedence
where they disagree.
