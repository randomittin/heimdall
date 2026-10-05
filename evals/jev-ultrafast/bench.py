#!/usr/bin/env python3
"""bench.py -- hmd web path vs jev-ultrafast, same task list (tasks.json).

Arms
  hmd  : bin/heimdall-web fetch|crawl|meta (measured; no API key needed).
  jev  : browser-use/jev-ultrafast. Runs ONLY if every precondition holds
         (JEV_DIR clone + uv + TYPESAFE_API_KEY + TEXT_MODEL_API_KEY +
         Chrome CDP reachable). Otherwise the arm is recorded BLOCKED with the
         exact missing precondition -- no number is ever invented. Env var
         NAMES are checked; VALUES are never read into output.
         jev has no text-extraction API (its output is the final page URL),
         so it is only scored on interaction tasks, verified server-side by
         the local fixture; every other category is recorded NOT_APPLICABLE.

Local fixture server (127.0.0.1, ephemeral port) supplies the deterministic
JS-rendered / crawl / form tasks, so those rows do not depend on the internet.
"""
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
HMD_WEB = ROOT / "bin" / "heimdall-web"
STATE = {"form_submitted": False, "reveal_clicked": False}

PAGES = {
    "/index": "<html><head><title>Index</title></head><body><h1>Index</h1><a href='/a'>Section A</a> <a href='/b'>Section B</a></body></html>",
    "/a": "<html><head><title>A</title></head><body><h1>A</h1><p>Nothing here.</p><a href='/a/deep'>Deep page</a></body></html>",
    "/b": "<html><head><title>B</title></head><body><h1>B</h1><p>Also nothing.</p></body></html>",
    "/a/deep": "<html><head><title>Deep</title></head><body><h1>Deep</h1><p>FACT: heron-7731</p></body></html>",
    "/js": "<html><head><title>JS</title></head><body><div id='o'>loading</div><script>setTimeout(function(){document.getElementById('o').textContent='JS-FACT: ' + ['kestrel','4402'].join('-');},50);</script></body></html>",
    "/form": "<html><head><title>Form</title></head><body><form method='post' action='/submit'><label>Name <input name='who' type='text'></label><button type='submit'>Send</button></form></body></html>",
    "/reveal": "<html><head><title>Reveal</title></head><body><button id='b' onclick=\"fetch('/reveal-api',{method:'POST'}).then(function(){document.getElementById('o').textContent='code: owl-9012';})\">Reveal secret</button><div id='o'></div></body></html>",
    "/robots.txt": "User-agent: *\nAllow: /\n",
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body, code=200):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in PAGES:
            self._send(PAGES[path])
        else:
            self._send("not found", 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        if self.path == "/submit":
            who = urllib.parse.parse_qs(body).get("who", [""])[0].strip()
            STATE["form_submitted"] = bool(who)
            self._send("<html><body>Thanks, %s</body></html>" % who)
        elif self.path == "/reveal-api":
            STATE["reveal_clicked"] = True
            self._send("ok")
        else:
            self._send("not found", 404)


def start_fixture():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]


def approx_tokens(text):
    return (len(text) + 3) // 4


def run_hmd(task, base):
    url = task.get("url") or base + task["path"]
    cat = task["cat"]
    if cat == "interaction":
        return {"status": "UNSUPPORTED", "reason": "hmd web is read-only (no click/type/submit)", "ok": False, "secs": 0.0, "tokens": 0}
    if cat == "crawl":
        c = task["crawl"]
        cmd = [str(HMD_WEB), "crawl", url, "--max-depth", str(c["max_depth"]), "--max-pages", str(c["max_pages"]),
               "--allow-private"]  # crawl rejects --no-cache despite --help listing it (observed 2026-10-05)
        outdir = Path(os.environ.get("TMPDIR", "/tmp")) / ("jev-bench-crawl-%d" % os.getpid())
        shutil.rmtree(outdir, ignore_errors=True)
        cmd += ["-o", str(outdir)]
    elif cat == "meta":
        cmd = [str(HMD_WEB), "meta", url, "--no-cache", "--allow-private"]
        outdir = None
    else:
        cmd = [str(HMD_WEB), "fetch", url, "--no-cache", "--allow-private"]
        outdir = None
    t0 = time.perf_counter()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired:
        return {"status": "TIMEOUT", "ok": False, "secs": 90.0, "tokens": 0}
    secs = time.perf_counter() - t0
    if outdir is not None:
        out = ""
        for f in sorted(outdir.glob("*.md")):
            out += f.read_text(errors="replace")
        shutil.rmtree(outdir, ignore_errors=True)
    ok = rc == 0 and re.search(task["expect"], out) is not None
    return {"status": "PASS" if ok else "FAIL", "ok": ok, "rc": rc, "secs": round(secs, 3),
            "tokens": approx_tokens(out), "bytes": len(out.encode())}


def jev_preconditions():
    missing = []
    jev_dir = os.environ.get("JEV_DIR", "")
    if not jev_dir or not (Path(jev_dir) / "examples" / "run.py").is_file():
        missing.append("JEV_DIR (clone of browser-use/jev-ultrafast)")
    if not shutil.which("uv"):
        missing.append("uv")
    for name in ("TYPESAFE_API_KEY", "TEXT_MODEL_API_KEY"):
        if not os.environ.get(name):
            missing.append(name)
    if not any(Path(p).exists() for p in ("/Applications/Google Chrome.app", "/usr/bin/google-chrome", "/usr/bin/chromium")):
        missing.append("Chrome")
    return missing


def run_jev(task, base):
    t0 = time.perf_counter()
    STATE["form_submitted"] = STATE["reveal_clicked"] = False
    cmd = ["uv", "run", "python", "examples/run.py", "--url", base + task["path"], "--goal", task["goal"]]
    env = dict(os.environ, BH_TELEMETRY="0", BROWSER_HARNESS_TELEMETRY="0", ANONYMIZED_TELEMETRY="0")
    try:
        p = subprocess.run(cmd, cwd=os.environ["JEV_DIR"], capture_output=True, text=True, timeout=120, env=env)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        return {"status": "TIMEOUT", "ok": False, "secs": 120.0}
    secs = time.perf_counter() - t0
    ok = rc == 0 and STATE[task["verify"]]
    return {"status": "PASS" if ok else "FAIL", "ok": ok, "rc": rc, "secs": round(secs, 3)}


def main():
    spec = json.loads((HERE / "tasks.json").read_text())
    reps = int(os.environ.get("REPS", spec["reps"]))
    srv, base = start_fixture()
    missing = jev_preconditions()
    jev_state = "BLOCKED" if missing else "READY"
    rows = []
    for task in spec["tasks"]:
        hmd = [run_hmd(task, base) for _ in range(reps)]
        row = {"id": task["id"], "cat": task["cat"], "hmd": hmd}
        if task["cat"] == "interaction":
            if missing:
                row["jev"] = {"status": "BLOCKED", "missing": missing}
            else:
                row["jev"] = [run_jev(task, base) for _ in range(reps)]
        else:
            row["jev"] = {"status": "NOT_APPLICABLE", "reason": "jev returns final URL, not extracted page text"}
        rows.append(row)
    srv.shutdown()

    def agg(runs):
        n = len(runs)
        okc = sum(1 for r in runs if r["ok"])
        return {"pass": okc, "n": n, "median_secs": round(statistics.median(r["secs"] for r in runs), 3),
                "median_tokens": int(statistics.median(r.get("tokens", 0) for r in runs))}

    summary = {"hmd": {}, "jev": {"state": jev_state, "missing": missing}}
    for cat in sorted({r["cat"] for r in rows}):
        runs = [x for r in rows if r["cat"] == cat for x in r["hmd"]]
        summary["hmd"][cat] = agg(runs)
    allruns = [x for r in rows for x in r["hmd"]]
    summary["hmd"]["ALL"] = agg(allruns)
    out = {"date": time.strftime("%Y-%m-%d"), "reps": reps, "summary": summary, "rows": rows}
    (HERE / "results.json").write_text(json.dumps(out, indent=2) + "\n")

    print("| category | hmd pass | median secs | median ctx tokens (chars/4) | jev |")
    print("|---|---|---|---|---|")
    for cat, a in summary["hmd"].items():
        jev = ("BLOCKED: missing " + ", ".join(missing)) if (cat == "interaction" and missing) else (
            "n/a (no text-extraction output)" if cat not in ("interaction", "ALL") else "")
        print("| %s | %d/%d | %s | %s | %s |" % (cat, a["pass"], a["n"], a["median_secs"], a["median_tokens"], jev))
    print("\nper-task hmd:")
    for r in rows:
        k = sum(1 for x in r["hmd"] if x["ok"])
        print("  %-26s %-12s %d/%d  %s" % (r["id"], r["cat"], k, len(r["hmd"]), r["hmd"][0].get("status")))
    print("\njev arm: %s%s" % (jev_state, (" (missing: %s)" % ", ".join(missing)) if missing else ""))


if __name__ == "__main__":
    sys.exit(main())
