#!/usr/bin/env python3
"""build_dataset.py -- extract real prompts / assistant questions from Claude Code transcripts.

Writes candidates (SCRUBBED, truncated) to --out as JSONL: {"id": sha256(raw)[:16], "text": scrubbed}.
Raw text never leaves memory. Labels live in labels.json (id -> label) and are applied by run.py.
Usage: python3 build_dataset.py --out candidates.jsonl [--n-prompts 200] [--n-questions 100] [--seed 7]
"""
import argparse, glob, hashlib, json, os, random, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scrub import scrub

SLUGS = ("-Users-rj-Downloads-heimdall", "-Users-rj-Downloads-hmdapp")
NOISE_PREFIX = ("<", "[Image", "Caveat:", "Review this change", "A session-scoped", "[Request interrupted",
                "This session is being continued", "Base directory for this skill", "/")


def transcripts():
    root = os.path.expanduser("~/.claude/projects")
    for s in SLUGS:
        yield from sorted(glob.glob(os.path.join(root, s, "*.jsonl")))


def entries(path):
    with open(path, errors="ignore") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") in ("user", "assistant") and not d.get("isSidechain"):
                yield d


def text_of(d):
    c = d.get("message", {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        if any(b.get("type") == "tool_result" for b in c if isinstance(b, dict)):
            return None
        return "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return None


def collect():
    prompts, questions = {}, {}
    for path in transcripts():
        seq = list(entries(path))
        for i, d in enumerate(seq):
            t = text_of(d)
            if not t or not t.strip():
                continue
            if d["type"] == "user":
                if d.get("isMeta") or t.lstrip().startswith(NOISE_PREFIX):
                    continue
                prompts[hashlib.sha256(t.encode()).hexdigest()[:16]] = t
            else:
                nxt = seq[i + 1] if i + 1 < len(seq) else None
                final = nxt is None or nxt["type"] == "user"      # no tool_use / more assistant output after it
                if final and re.search(r"\?[\"')\]}*_~`»”’]*\s*$", t.strip()):
                    questions[hashlib.sha256(t.encode()).hexdigest()[:16]] = t
    return prompts, questions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--n-prompts", type=int, default=200)
    ap.add_argument("--n-questions", type=int, default=100)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    prompts, questions = collect()
    rng = random.Random(a.seed)
    print(f"pool: prompts={len(prompts)} questions={len(questions)}", file=sys.stderr)
    with open(a.out, "w") as out:
        for kind, pool, n in (("prompt", prompts, a.n_prompts), ("question", questions, a.n_questions)):
            for k in rng.sample(sorted(pool), min(n, len(pool))):
                out.write(json.dumps({"kind": kind, "id": k, "text": scrub(pool[k], keep="head" if kind == "prompt" else "tail")}, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
