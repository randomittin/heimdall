#!/usr/bin/env bash
# Hidden acceptance for 01: cwd = the agent's workdir.
set -u
PYTHONPATH="$PWD" python3 - <<'PY'
from pager import paginate

r = paginate([], 1, 5)
assert r == {"items": [], "page": 1, "per_page": 5, "total": 0, "pages": 1, "has_next": False, "has_prev": False}, r
r = paginate(list(range(9)), 3, 3)
assert r["items"] == [6, 7, 8] and r["pages"] == 3 and not r["has_next"] and r["has_prev"], r
r = paginate(list(range(10)), 4, 3)
assert r["items"] == [9] and r["pages"] == 4 and not r["has_next"], r
assert paginate(list(range(10)), 0, 3)["page"] == 1
assert paginate(list(range(10)), -7, 3)["items"] == [0, 1, 2]
r = paginate(list(range(10)), 99, 3)
assert r["page"] == 4 and r["items"] == [9], r
r = paginate(list(range(10)), 2, 3)
assert r["has_next"] and r["has_prev"], r
r = paginate(list(range(10)), 1, 3)
assert r["has_next"] and not r["has_prev"], r
r = paginate(list(range(3)), 1, 10)
assert r["items"] == [0, 1, 2] and r["pages"] == 1 and not r["has_next"], r
for bad in (0, -3):
    raised = False
    try:
        paginate([1, 2], 1, bad)
    except ValueError:
        raised = True
    assert raised, f"per_page={bad} must raise ValueError"
PY
