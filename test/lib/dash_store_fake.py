"""dash_store_fake.py -- a file-backed implementation of the INTERFACE bin/lib/companion_dashboards.py documents for
bin/lib/dashboard_producers.py (claim_generation / register_proposal / fail_generation, confirmed_producers / publish_panel /
set_tile_status / phone_present, get_tile / list_tiles / pending_confirmations / confirm_tile / decline_tile / audit_event).
Test support only: test/dashboard-producers.test.sh points $HMD_DASH_STORE_MODULE at this file so the producer half is exercised
on its own branch, CLI subprocesses included. Tile files use the DD2 layout. FORCE_LIVE_ON_REGISTER simulates a store that lets a
changed-nothing proposal go live even for an import (the bug dashboard_producers must not trust the store to be free of).
"""
import hashlib
import json
import os
import time
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.realpath(__file__))
LIB = os.path.join(os.path.dirname(os.path.dirname(HERE)), "bin", "lib")
_spec = spec_from_file_location("companion_ui_panels", os.path.join(LIB, "companion_ui_panels.py"))
PANELS = module_from_spec(_spec)
_spec.loader.exec_module(PANELS)

BASE = os.path.join(".heimdall", "ui", "dashboards")
AUDIT = os.path.join(".heimdall", "ui", "controls-audit.jsonl")
PENDING_TTL_S = 24 * 3600
FORCE_LIVE_ON_REGISTER = False


def fingerprint_of(producer):
    parts = [producer["kind"], producer["connector"], producer["statement"], json.dumps(producer["columns"], ensure_ascii=False, separators=(",", ":"))]
    return hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()


def confirm_code(tile_id, fingerprint):
    digest = hashlib.sha256(b"hmd-dash-confirm-v1\0" + tile_id.encode("utf-8") + b"\0" + fingerprint.encode("utf-8")).digest()
    return "%06d" % (int.from_bytes(digest[:4], "big") % 1000000)


def new_tile(tile_id, dashboard_id="d-00000001", intent="orders per day", origin="phone", author=None, shape=None):
    return {"tile_id": tile_id, "dashboard_id": dashboard_id, "screen_id": "s-00000001", "intent": intent, "shape": shape, "refresh_s": 300,
            "origin": origin, "author": author, "rev": 1, "proposal": None, "fingerprint": None, "confirmed_fp": None, "phase": "generating",
            "detail": None, "last_ok_at": None, "history": [], "panel": None, "pending_at": None, "refresh_requested_at": None}


def put_tile(root, tile):
    directory = os.path.join(root, BASE, tile["dashboard_id"])
    os.makedirs(directory, mode=0o700, exist_ok=True)
    path = os.path.join(directory, tile["tile_id"] + ".json")
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(tile, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def list_tiles(root):
    out = []
    base = os.path.join(root, BASE)
    for d in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        for name in sorted(os.listdir(os.path.join(base, d))):
            if name.startswith("t-") and name.endswith(".json"):
                with open(os.path.join(base, d, name), encoding="utf-8") as f:
                    out.append(json.load(f))
    return out


def get_tile(root, tile_id):
    return next((t for t in list_tiles(root) if t["tile_id"] == tile_id), None)


def _meta_path(root):
    return os.path.join(root, BASE, "meta.json")


def _meta(root):
    try:
        with open(_meta_path(root), encoding="utf-8") as f:
            return json.load(f)
    except OSError:
        return {"queue": [], "last_request_at": None}


def _save_meta(root, meta):
    os.makedirs(os.path.dirname(_meta_path(root)), mode=0o700, exist_ok=True)
    with open(_meta_path(root), "w", encoding="utf-8") as f:
        json.dump(meta, f)


def enqueue(root, job):
    meta = _meta(root)
    meta["queue"].append(job)
    _save_meta(root, meta)


def set_last_request(root, when):
    meta = _meta(root)
    meta["last_request_at"] = when
    _save_meta(root, meta)


def claim_generation(root, now=None):
    meta = _meta(root)
    if not meta["queue"]:
        return None
    job = meta["queue"].pop(0)
    _save_meta(root, meta)
    return job


def register_proposal(root, tile_id, rid, proposal, now=None):
    now = time.time() if now is None else now
    tile = get_tile(root, tile_id)
    if tile is None:
        return False, "unknown-tile"
    fp = fingerprint_of(proposal["producer"])
    tile.update(proposal=proposal, fingerprint=fp, shape=proposal["shape"], detail=None)
    if tile["confirmed_fp"] == fp or FORCE_LIVE_ON_REGISTER:
        tile.update(phase="live", pending_at=None)
    else:
        tile.update(phase="needs-confirm", pending_at=now)
    put_tile(root, tile)
    return True, None


def fail_generation(root, tile_id, rid, detail, now=None):
    tile = get_tile(root, tile_id)
    if tile is not None:
        tile.update(phase="error", detail=detail)
        put_tile(root, tile)


def _runnable(t):
    return (t["fingerprint"] is not None and t["fingerprint"] == t["confirmed_fp"] and isinstance(t.get("proposal"), dict)
            and (t["phase"] in ("live", "generating") or (t["phase"] == "error" and t["detail"] in ("producer-failed", "rejected-panel"))))


def confirmed_producers(root):
    return [{"tile_id": t["tile_id"], "dashboard_id": t["dashboard_id"], "refresh_s": t["refresh_s"], "shape": t.get("shape"),
             "producer": json.loads(json.dumps(t["proposal"]["producer"])), "fingerprint": t["fingerprint"], "phase": t["phase"],
             "detail": t["detail"], "last_ok_at": t.get("last_ok_at"), "refresh_requested_at": t.get("refresh_requested_at")}
            for t in list_tiles(root) if _runnable(t)]


def pending_confirmations(root, now=None):
    now = time.time() if now is None else now
    return [{"tile_id": t["tile_id"], "dashboard_id": t["dashboard_id"], "origin": t["origin"], "author": t.get("author"), "intent": t["intent"],
             "shape": t.get("shape"), "producer": t["proposal"]["producer"], "fingerprint": t["fingerprint"],
             "age_s": int(now - t["pending_at"]), "expires_at": int(t["pending_at"] + PENDING_TTL_S)}
            for t in list_tiles(root) if t["phase"] == "needs-confirm" and isinstance(t.get("proposal"), dict)]


def confirm_tile(root, tile_id, fingerprint, now=None):
    now = time.time() if now is None else now
    tile = get_tile(root, tile_id)
    if tile is None:
        return False, "unknown-tile"
    if tile["phase"] != "needs-confirm":
        return False, "not-pending"
    if fingerprint != tile["fingerprint"]:
        return False, "fingerprint-changed"
    tile.update(confirmed_fp=fingerprint, phase="live", detail=None, pending_at=None, refresh_requested_at=now)
    put_tile(root, tile)
    audit_event(root, "confirm", tile_id, True, None)
    return True, None


def decline_tile(root, tile_id, now=None):
    tile = get_tile(root, tile_id)
    if tile is None or tile["phase"] != "needs-confirm":
        return False
    tile.update(phase="error", detail="declined", pending_at=None)
    put_tile(root, tile)
    audit_event(root, "decline", tile_id, False, "declined")
    return True


def phone_present(root, idle_s=43200, now=None):
    now = time.time() if now is None else now
    if idle_s <= 0:
        return True
    last = _meta(root)["last_request_at"]
    return last is not None and now - last <= idle_s


def set_tile_status(root, tile_id, phase, detail=None, now=None):
    allowed = {"live": (None,), "error": ("producer-failed", "timeout"), "paused": ("idle", "backoff")}
    tile = get_tile(root, tile_id)
    if detail not in allowed.get(phase, ()) or tile is None or not (_runnable(tile) or tile["phase"] == "paused"):
        return False
    tile.update(phase=phase, detail=detail)
    put_tile(root, tile)
    return True


def publish_panel(root, tile_id, candidate, now=None, panel_bytes=32768):
    now = time.time() if now is None else now
    tile = get_tile(root, tile_id)
    if tile is None or tile["fingerprint"] is None or tile["fingerprint"] != tile["confirmed_fp"]:
        return False, "unconfirmed"
    try:
        panel = PANELS.validate_panel(dict(candidate, id=tile_id, refresh_s=tile["refresh_s"], updated_at=now))
        if len(json.dumps(panel, separators=(",", ":")).encode("utf-8")) > panel_bytes:
            raise PANELS.PanelError("size")
    except PANELS.PanelError:
        tile.update(phase="error", detail="rejected-panel")
        put_tile(root, tile)
        return False, "rejected-panel"
    tile.update(panel=panel, last_ok_at=int(now), phase="live", detail=None)
    put_tile(root, tile)
    return True, None


def audit_event(root, op, tile_id, ok, detail):
    path = os.path.join(root, AUDIT)
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps({"action": "dashboard-request", "op": op, "tile_id": tile_id, "ok": bool(ok), "detail": detail}) + "\n")
