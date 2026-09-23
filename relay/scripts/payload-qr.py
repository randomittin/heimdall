#!/usr/bin/env python3
"""Render a relay pairing payload (one JSON line on stdin or argv[1]) as a QR PNG.

Optional operator tool for manual acceptance: pipe fake-hmd.mjs's stdout line
(or hmd's printed payload) in, then scan the opened image with the companion
app's Pair screen. Needs `pip install qrcode[pil]`; not a project dependency.
Never logs the payload (it contains a single-use pairing code).
"""
import json, sys, pathlib, subprocess
import qrcode

raw = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.readline()
payload = json.loads(raw)
for k in ("v", "relay", "session_id", "pairing_code", "exp", "hmd_pubkey"):
    if k not in payload:
        sys.exit(f"payload missing {k}")
out = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "/tmp/hmd-relay-pair.png")
img = qrcode.make(json.dumps(payload, separators=(",", ":")), box_size=10, border=2)
img.save(out)
print(f"QR written to {out} (expires at {payload['exp']})", file=sys.stderr)
if sys.platform == "darwin" and "--no-open" not in sys.argv:
    subprocess.run(["open", str(out)], check=False)
