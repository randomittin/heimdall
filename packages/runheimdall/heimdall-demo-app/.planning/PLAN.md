# Plan seed — heimdall demo (Todo full-stack)

This is a ready-to-execute plan for the task in `.heimdall-demo-task.md`.
heimdall will refine and parallelize it; it exists so the demo starts with momentum.

## Waves
### Wave 1 — backend core (parallel-safe)
- [ ] `app.py`: FastAPI app, Pydantic `Todo`/`TodoIn` models, in-memory store,
      the five routes per the API contract, static `index.html` at `GET /`.
- [ ] `requirements.txt`: fastapi, uvicorn, pytest, httpx.

### Wave 2 — frontend + tests (parallel-safe, depend on Wave 1 contract)
- [ ] `index.html`: vanilla-JS SPA (list / add / toggle / delete via fetch).
- [ ] `test_app.py`: pytest + TestClient covering every acceptance criterion.

### Wave 3 — docs + verify (sequential)
- [ ] `README.md`: install / run / test instructions.
- [ ] Run `pytest -q` -> green. Boot `uvicorn app:app` -> `GET /` serves HTML.

## Definition of done
All six acceptance criteria in `.heimdall-demo-task.md` pass with quoted evidence.
