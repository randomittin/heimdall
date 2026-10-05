#!/usr/bin/env python3
"""run.py -- does TypeSafe (Jev, Noul) beat hmd's current heuristics?  One measured experiment.

Arms
  heuristic  ALWAYS runs, fully local, zero egress:
               prompts   -> bin/parallel-gate (the real UserPromptSubmit hook, spawned as the hook is)
               questions -> bin/lib/companion_ui_attention._closed_polar_question (in-process)
  typesafe   ONLY if ALL hold, otherwise the arm is reported BLOCKED and nothing is sent anywhere:
               1. --typesafe is passed
               2. an operator-supplied key is in the environment (TYPESAFE_API_KEY)
               3. --accept-egress is passed (the stored text is scrubbed, but it still leaves the machine)

Usage
  python3 evals/typesafe/run.py                              # heuristic baseline + BLOCKED/ready status
  python3 evals/typesafe/run.py --json out.json              # also write machine-readable results
  TYPESAFE_API_KEY=... python3 evals/typesafe/run.py --typesafe --accept-egress
  python3 evals/typesafe/run.py --selftest                   # harness plumbing vs a LOCAL fake server (not a result)

Env: TYPESAFE_API_KEY (secret, never printed), TYPESAFE_BASE_URL (default https://api.typesafe.ai),
     TYPESAFE_MODEL (default jev-latest; pin e.g. jev-1.13.0 for reproducibility).
Dataset: evals/typesafe/dataset.jsonl {kind: prompt|question, id: sha256(raw)[:16], label: 0|1, text: scrubbed}.
"""
import argparse, json, math, os, random, subprocess, sys, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "bin", "lib"))
KEY_ENV = "TYPESAFE_API_KEY"
MARKER = "MULTI-PART TASK DETECTED"

QUESTIONS = {
    "prompt": {
        "type": "noul",
        "instructions": ("Does this message from a developer ask for two or more separate pieces of work "
                         "(distinct deliverables or changes) that could be done at the same time by different workers?"),
        "criteria": {
            "true": "Two or more distinct work items that do not depend on each other's output",
            "false": "A single task, a question, a status check, a reply to a prior question, or sequential steps of one task",
        },
    },
    "question": {
        "type": "noul",
        "instructions": ("Does this assistant message end by asking the user exactly one closed question "
                         "that a plain Yes or No fully answers?"),
        "criteria": {
            "true": "One yes/no question as the final ask",
            "false": "An either/or choice, a which/what/how question, a request for a value, or several questions",
        },
    },
}


def load():
    with open(os.path.join(HERE, "dataset.jsonl")) as fh:
        return [json.loads(l) for l in fh if l.strip()]


# ── metrics ───────────────────────────────────────────────────────────────────────────────────
def prf(y, p):
    tp = sum(1 for a, b in zip(y, p) if a and b)
    fp = sum(1 for a, b in zip(y, p) if not a and b)
    fn = sum(1 for a, b in zip(y, p) if a and not b)
    tn = len(y) - tp - fp - fn
    prec = tp / (tp + fp) if tp + fp else float("nan")
    rec = tp / (tp + fn) if tp + fn else float("nan")
    f1 = 2 * prec * rec / (prec + rec) if tp else 0.0
    return {"n": len(y), "pos": sum(y), "tp": tp, "fp": fp, "fn": fn, "tn": tn,
            "precision": prec, "recall": rec, "f1": f1}


def boot_f1(y, p, n=2000, seed=1):
    rng = random.Random(seed)
    idx = range(len(y))
    vals = []
    for _ in range(n):
        s = [rng.choice(idx) for _ in idx]
        vals.append(prf([y[i] for i in s], [p[i] for i in s])["f1"])
    vals.sort()
    return vals[int(.025 * n)], vals[int(.975 * n)]


def pct(xs, q):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = (len(xs) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def auc(y, s):
    pos = [v for a, v in zip(y, s) if a]
    neg = [v for a, v in zip(y, s) if not a]
    if not pos or not neg:
        return float("nan")
    return sum((p > n) + 0.5 * (p == n) for p in pos for n in neg) / (len(pos) * len(neg))


# ── heuristic arm ─────────────────────────────────────────────────────────────────────────────
def gate_detects(text):
    t0 = time.perf_counter()
    r = subprocess.run([os.path.join(ROOT, "bin", "parallel-gate")], input=json.dumps({"prompt": text}),
                       capture_output=True, text=True, timeout=30)
    return MARKER in r.stdout, (time.perf_counter() - t0) * 1000


def heuristic_arm(rows):
    import companion_ui_attention as cua
    out = {}
    for kind in ("prompt", "question"):
        sub = [r for r in rows if r["kind"] == kind]
        pred, lat = [], []
        for r in sub:
            if kind == "prompt":
                hit, ms = gate_detects(r["text"])
            else:
                t0 = time.perf_counter()
                hit = cua._closed_polar_question(r["text"])
                ms = (time.perf_counter() - t0) * 1000
            pred.append(int(hit))
            lat.append(ms)
        out[kind] = {"y": [r["label"] for r in sub], "pred": pred, "lat_ms": lat, "ids": [r["id"] for r in sub]}
    return out


# ── typesafe arm ──────────────────────────────────────────────────────────────────────────────
def typesafe_call(kind, text, key, base, model, timeout=30):
    body = json.dumps({"state": text, "model": model, "questions": {"q": QUESTIONS[kind]}}).encode()
    req = urllib.request.Request(base.rstrip("/") + "/v1/systemone", data=body, method="POST",
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    last = None
    for attempt in range(4):                       # docs: 429/529 -> exponential backoff
        t0 = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read())
            ms = (time.perf_counter() - t0) * 1000
            return float(data["answers"]["q"]["noul"]), ms, data.get("usage", {}).get("input_tokens", 0), data.get("model")
        except urllib.error.HTTPError as e:
            last = "HTTP %d" % e.code
            if e.code not in (429, 529):
                break
            time.sleep(2 ** attempt)
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as e:
            last = type(e).__name__
            time.sleep(2 ** attempt)
    raise RuntimeError("typesafe call failed: " + str(last))      # never includes the key


def typesafe_arm(rows, key, base, model):
    out = {}
    for kind in ("prompt", "question"):
        sub = [r for r in rows if r["kind"] == kind]
        scores, lat, toks, models = [], [], 0, set()
        for r in sub:
            s, ms, t, m = typesafe_call(kind, r["text"], key, base, model)
            scores.append(s); lat.append(ms); toks += t; models.add(m)
        out[kind] = {"y": [r["label"] for r in sub], "score": scores, "lat_ms": lat,
                     "input_tokens": toks, "models": sorted(x for x in models if x)}
    return out


# ── reporting ─────────────────────────────────────────────────────────────────────────────────
def fmt(m):
    return ("n=%d pos=%d  P=%.3f R=%.3f F1=%.3f  (tp=%d fp=%d fn=%d tn=%d)"
            % (m["n"], m["pos"], m["precision"], m["recall"], m["f1"], m["tp"], m["fp"], m["fn"], m["tn"]))


def report_heuristic(h):
    res = {}
    for kind, d in h.items():
        m = prf(d["y"], d["pred"])
        lo, hi = boot_f1(d["y"], d["pred"])
        always = prf(d["y"], [1] * len(d["y"]))
        res[kind] = {"metrics": m, "f1_ci95": [lo, hi], "always_yes_f1": always["f1"],
                     "latency_ms": {"p50": pct(d["lat_ms"], .5), "p95": pct(d["lat_ms"], .95)}}
        print("[heuristic/%s] %s" % (kind, fmt(m)))
        print("    F1 95%% bootstrap CI [%.3f, %.3f]; always-yes F1=%.3f; latency p50=%.3f ms p95=%.3f ms"
              % (lo, hi, always["f1"], res[kind]["latency_ms"]["p50"], res[kind]["latency_ms"]["p95"]))
    return res


def report_typesafe(t):
    res = {}
    for kind, d in t.items():
        best = max(((prf(d["y"], [int(s >= th) for s in d["score"]]), th) for th in (x / 20 for x in range(1, 20))),
                   key=lambda z: z[0]["f1"])
        m5 = prf(d["y"], [int(s >= .5) for s in d["score"]])
        lo, hi = boot_f1(d["y"], [int(s >= .5) for s in d["score"]])
        res[kind] = {"at_0.5": m5, "f1_ci95_at_0.5": [lo, hi], "auc": auc(d["y"], d["score"]),
                     "best_threshold_in_sample": best[1], "best_in_sample": best[0],
                     "latency_ms": {"p50": pct(d["lat_ms"], .5), "p95": pct(d["lat_ms"], .95)},
                     "input_tokens": d["input_tokens"], "models": d["models"]}
        print("[typesafe/%s @0.5] %s" % (kind, fmt(m5)))
        print("    F1 CI [%.3f, %.3f]; AUC=%.3f; in-sample-best th=%.2f F1=%.3f (optimistic); latency p50=%.1f ms p95=%.1f ms; "
              "input_tokens=%d model=%s" % (lo, hi, res[kind]["auc"], best[1], best[0]["f1"],
                                          res[kind]["latency_ms"]["p50"], res[kind]["latency_ms"]["p95"],
                                          d["input_tokens"], ",".join(d["models"])))
    return res


# ── selftest: plumbing only, against a LOCAL fake server; its numbers mean nothing ─────────────
def selftest():
    import http.server, threading

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            ok = self.headers.get("Authorization") == "Bearer selftest-key" and self.path == "/v1/systemone"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert body["model"] and "q" in body["questions"] and body["questions"]["q"]["type"] == "noul"
            self.send_response(200 if ok else 401)
            self.end_headers()
            if ok:
                self.wfile.write(json.dumps({"model": "fake", "answers": {"q": {"type": "noul", "noul": 0.9}},
                                             "usage": {"input_tokens": 7, "output_tokens": 1}}).encode())

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % srv.server_port
    s, ms, tok, model = typesafe_call("prompt", "hello", "selftest-key", base, "jev-latest")
    assert (s, tok, model) == (0.9, 7, "fake"), (s, tok, model)
    try:
        typesafe_call("prompt", "hello", "wrong", base, "jev-latest")
        raise SystemExit("selftest FAIL: bad key accepted")
    except RuntimeError as e:
        assert "wrong" not in str(e)
    assert abs(auc([1, 0, 1, 0], [.9, .1, .8, .2]) - 1.0) < 1e-9 and prf([1, 0], [1, 0])["f1"] == 1.0
    print("selftest OK (request shape, auth header, parse, error path, no key leak). No eval numbers produced.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--typesafe", action="store_true")
    ap.add_argument("--accept-egress", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    rows = load()
    print("dataset: %d prompts (%d multi-part), %d questions (%d closed-polar)" % (
        sum(r["kind"] == "prompt" for r in rows), sum(r["kind"] == "prompt" and r["label"] for r in rows),
        sum(r["kind"] == "question" for r in rows), sum(r["kind"] == "question" and r["label"] for r in rows)))
    result = {"heuristic": report_heuristic(heuristic_arm(rows))}
    key = os.environ.get(KEY_ENV, "")
    if not (a.typesafe and key and a.accept_egress):
        why = [w for w, bad in (("%s not set (operator must supply)" % KEY_ENV, not key),
                                ("--typesafe not passed", not a.typesafe),
                                ("--accept-egress not passed", not a.accept_egress)) if bad]
        print("[typesafe] BLOCKED: " + "; ".join(why) + ". Nothing was sent to typesafe.ai.")
        result["typesafe"] = {"status": "BLOCKED", "reasons": why}
    else:
        result["typesafe"] = {"status": "RAN", **report_typesafe(typesafe_arm(
            rows, key, os.environ.get("TYPESAFE_BASE_URL", "https://api.typesafe.ai"),
            os.environ.get("TYPESAFE_MODEL", "jev-latest")))}
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(result, fh, indent=1, default=str)


if __name__ == "__main__":
    main()
