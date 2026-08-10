#!/usr/bin/env bash
# test/chat-ops.test.sh — acceptance for CHAT-OPS P2 (Telegram verb core).
#
# Proves, against the REAL bin/lib/chat_*.py + the REAL cp stores + a REAL throwaway git repo
# carrying a REAL hmd/context branch (no network, no live bot required — the adapter transport
# is an injected seam and the bot token is absent):
#
#   (1) CLASSIFIER — the bounded verb set: explicit verbs classify; free text ("what's
#       breaking this") maps to investigate; P3 verbs (fix/approve/deny) and any unmapped/
#       empty/non-str text map to help. classify() NEVER returns raw text.
#   (2) BINDING LIFECYCLE — mint (6-digit, team SERVER-DERIVED) -> redeem binds
#       {chat_id<->HAID<->team} -> resolve returns the bound team. Single-use (a second
#       redeem is refused, the forged chat stays unbound). TTL-expired code refused. Unbound/
#       forged chat_id resolves to None.
#   (3) FULL BOUND PATH — mint -> /hmd link <code> -> a bound `status` returns team data.
#   (4) ISOLATION — verbs are team-scoped: team A's chat can never see team B's queue; an
#       unbound chat is refused with the link instruction and NO data.
#   (5) INVESTIGATE — reads P1's hmd/context worklog FIRST and CITES the resume; the
#       BYO-inference gate refuses (connect instruction, NO dispatch) with no team credential
#       and ENQUEUES a triage task into the team's OWN partition once a credential is present.
#   (6) ADAPTER — pure parse (tolerant of junk), injected transport carries the message, and
#       the bot token comes from env ONLY (inactive without it => a clean send no-op).
#   (7) CLI — `heimdall-chat handle` refuses an unbound chat and serves a bound one.
#
# Exit 0 = every assertion passed. Non-zero = a regression.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib"
CHAT_BIN="$ROOT/bin/heimdall-chat"

PY="$(command -v python3 || command -v python)"
[ -x "$CHAT_BIN" ] || { echo "FATAL: $CHAT_BIN not executable" >&2; exit 2; }
[ -n "$PY" ]       || { echo "FATAL: python3 required" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HEIMDALL_HOME="$WORK/home"
export PYTHONPATH="$LIB"
# The bot token MUST be absent so the adapter is inactive (a clean no-op) throughout.
unset HEIMDALL_TELEGRAM_BOT_TOKEN || true

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# ── build a throwaway repo carrying a REAL hmd/context branch (via git plumbing, so main is
#    never touched — the exact shape P1 writes). Echoes the repo path. ──
make_context_repo() {
  local repo="$WORK/ctxrepo" stage="$WORK/ctxstage" gitdir idx tree commit
  mkdir -p "$repo" "$stage"
  git -C "$repo" init -q
  git -C "$repo" config user.email "t@runheimdall.dev"
  git -C "$repo" config user.name "t"
  printf 'seed\n' > "$repo/app.py"
  git -C "$repo" add app.py
  git -C "$repo" commit -qm "MAIN: seed"
  cat > "$stage/worklog.json" <<'JSON'
{"schema":"hmd-context/worklog@1","repo":"rj/heimdall","by":"RJ","goal":"ship auth","summary":"auth refactor, gate red on oracle/contract","last_state":"working the token verifier","open_cases":["case-101"],"recent_commits":["abc123 feat: token verifier"]}
JSON
  gitdir="$(cd "$repo" && git rev-parse --absolute-git-dir)"
  idx="$WORK/ctxidx"; rm -f "$idx"
  ( cd "$stage" && GIT_DIR="$gitdir" GIT_WORK_TREE="$stage" GIT_INDEX_FILE="$idx" git add -f -A . )
  tree="$(GIT_DIR="$gitdir" GIT_INDEX_FILE="$idx" git write-tree)"
  commit="$(GIT_DIR="$gitdir" GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h \
            GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
            git commit-tree "$tree" -m 'hmd context')"
  GIT_DIR="$gitdir" git update-ref refs/heads/hmd/context "$commit"
  printf '%s' "$repo"
}

CTX_REPO="$(make_context_repo)"
export CHAT_TEST_REPO="$CTX_REPO"

echo "-- chat-ops P2: classifier + binding + verbs + adapter -----------------------"

# The core driver: all shared-state assertions run in ONE python process against the REAL
# modules (bindings persist to $HEIMDALL_HOME on disk for the CLI checks that follow).
"$PY" - <<'PYEOF'
import os, sys
LIB = os.environ["PYTHONPATH"]; HOME = os.environ["HEIMDALL_HOME"]
REPO = os.environ["CHAT_TEST_REPO"]
sys.path.insert(0, LIB)

import cp_auth, cp_team_creds, cp_team_queue
import chat_classifier, chat_link, chat_core, chat_verbs, chat_adapter, chat_worklog

P = {"pass": 0, "fail": 0}
def ok(m):  P["pass"] += 1; print("  \033[32mPASS\033[0m %s" % m)
def bad(m): P["fail"] += 1; print("  \033[31mFAIL\033[0m %s" % m)
def check(cond, m): ok(m) if cond else bad(m)

TEAM_A = "aaaa0000" * 4  # 32 hex — the non-secret partition handle shape.
TEAM_B = "bbbb1111" * 4
cp_auth.register_key("haid:alice", "cHViQQ==", team_id=TEAM_A, home=HOME)
cp_auth.register_key("haid:bob",   "cHViQg==", team_id=TEAM_B, home=HOME)

# ── (1) CLASSIFIER ────────────────────────────────────────────────────────────────
check(chat_classifier.classify("status") == "status", "classify: status")
check(chat_classifier.classify("investigate now") == "investigate", "classify: investigate")
check(chat_classifier.classify("what's breaking this?") == "investigate",
      "classify: free-text 'what's breaking' -> investigate")
check(chat_classifier.classify("report") == "report", "classify: report")
check(chat_classifier.classify("/hmd link 123456") == "link", "classify: /hmd link -> link")
check(chat_classifier.classify("total gibberish xyzzy") == "help", "classify: unmapped -> help")
check(chat_classifier.classify("fix the auth bug") == "help", "classify: P3 fix absent -> help")
check(chat_classifier.classify("approve 12") == "help", "classify: P3 approve absent -> help")
check(chat_classifier.classify("deny 12") == "help", "classify: P3 deny absent -> help")
check(chat_classifier.classify("") == "help", "classify: empty -> help")
check(chat_classifier.classify(None) == "help", "classify: non-str -> help")
_probe = ["status", "x", "", None, "fix", "@bot investigate", "12345", "what broke"]
check(all(chat_classifier.classify(t) in chat_classifier.VERBS for t in _probe),
      "classify: total — every input maps into the bounded verb set (never raw text)")

# ── (2) BINDING LIFECYCLE ───────────────────────────────────────────────────────────
m = chat_link.mint_code("haid:alice", home=HOME)
check(m["ok"] and len(m["code"]) == 6 and m["code"].isdigit() and m["team_id"] == TEAM_A,
      "mint: 6-digit code, team SERVER-DERIVED from the HAID")
code = m["code"]
# Only the HASH is persisted — the plaintext code never appears in the stored record.
stored = chat_link._backend(HOME).get_record(chat_link._code_rel(code))
check(isinstance(stored, dict) and code not in str(stored) and stored.get("code_hash"),
      "mint: only the sha256 hash is stored, never the plaintext code")

check(chat_link.resolve("chat:alice", home=HOME) is None, "resolve: unbound chat_id -> None")
r = chat_link.redeem(code, "chat:alice", home=HOME)
check(r["ok"] and r["team_id"] == TEAM_A, "redeem: binds {chat_id<->HAID<->team}")
check(chat_link.resolve("chat:alice", home=HOME) == TEAM_A, "resolve: bound chat -> team")

# Single-use: a second redeem of the same code (even for a different, forged chat) is refused.
r2 = chat_link.redeem(code, "chat:mallory", home=HOME)
check((not r2["ok"]) and r2["reason"] == "already_used", "redeem: single-use — second redeem refused")
check(chat_link.resolve("chat:mallory", home=HOME) is None,
      "redeem: the forged chat stays UNBOUND after a reused-code attempt")

# TTL: an expired code is refused (mint at t, redeem past created+ttl).
mexp = chat_link.mint_code("haid:alice", home=HOME, ttl=300, now=1000)
rexp = chat_link.redeem(mexp["code"], "chat:late", home=HOME, now=1000 + 301)
check((not rexp["ok"]) and rexp["reason"] == "expired", "redeem: TTL-expired code refused")
check(chat_link.resolve("chat:late", home=HOME) is None, "redeem: expired code binds nothing")

# ── (3) FULL BOUND PATH via the dispatch seam (mint -> link -> bound status returns data) ──
mb = chat_link.mint_code("haid:bob", home=HOME)
link_res = chat_core.handle_message("chat:bob", "/hmd link %s" % mb["code"], home=HOME)
check(link_res["ok"] and link_res["bound"], "core: /hmd link <code> binds via handle_message")
st = chat_core.handle_message("chat:alice", "status", home=HOME)
check(st["ok"] and st.get("bound") and st["team"] == TEAM_A and "status for team" in st["reply"],
      "core: a BOUND status returns team data")

# ── (4) ISOLATION — unbound refused; verbs never cross team ──────────────────────────
un = chat_core.handle_message("chat:ghost", "status", home=HOME)
check((not un["ok"]) and un.get("reason") == "unbound" and un["team"] is None
      and "link" in un["reply"].lower(),
      "core: UNBOUND status refused with the link instruction, NO data")

# Enqueue a task into team B; team A's status must never see it.
cp_team_queue.enqueue(TEAM_B, "rotate token", home=HOME)
sa = chat_verbs.status("chat:alice", home=HOME)
sb = chat_verbs.status("chat:bob", home=HOME)
check(sa["team"] == TEAM_A and sb["team"] == TEAM_B, "verbs: each bound chat scoped to its OWN team")
check(sa["data"]["queued"] == 0 and sb["data"]["queued"] >= 1,
      "verbs: team A status cannot see team B's queue (never cross-team)")

# ── (5) INVESTIGATE — cites the worklog + BYO-inference gate ─────────────────────────
wl = chat_worklog.read_worklog(REPO)
check(wl.get("available") and wl["worklog"].get("by") == "RJ",
      "worklog: read from hmd/context via git plumbing (no checkout)")

inv = chat_verbs.investigate("chat:alice", hint="auth", home=HOME, repo=REPO)
check("Continuing from RJ" in inv["citation"], "investigate: CITES the P1 worklog resume")
check(inv["byo_ready"] is False and inv["dispatched"] is False
      and "connect" in inv["reply"].lower(),
      "investigate: BYO gate — no team credential -> connect instruction, NO dispatch")
# No task was enqueued into team A's partition by the refused investigate.
check(cp_team_queue.depth(TEAM_A, home=HOME) == 0, "investigate: refused BYO enqueues NOTHING")

# Now register a team credential -> investigate enqueues a triage task into team A's partition.
cp_team_creds.put_team_cred(TEAM_A, "api_key", "tok-teamA-credential", home=HOME)
inv2 = chat_verbs.investigate("chat:alice", hint="auth", home=HOME, repo=REPO)
check(inv2["byo_ready"] and inv2["dispatched"] and inv2["task_id"],
      "investigate: BYO ready — credential present -> triage task enqueued")
rows = cp_team_queue.list(TEAM_A, home=HOME)
def _text(r):
    it = r.get("item")
    return it.get("text", "") if isinstance(it, dict) else ""
check(any("investigate" in _text(r) for r in rows),
      "investigate: triage task lands in team A's OWN partition")
check(cp_team_queue.depth(TEAM_B, home=HOME) >= 1 and
      all("investigate" not in _text(r) for r in cp_team_queue.list(TEAM_B, home=HOME)),
      "investigate: team A's triage never crosses into team B's partition")

# ── (6) ADAPTER — pure parse, injected transport, token from env ONLY ────────────────
p = chat_adapter.parse_update({"update_id": 7, "message": {"chat": {"id": 42}, "text": "status"}})
check(p == {"chat_id": "42", "text": "status", "update_id": 7}, "adapter: parses a text update")
check(chat_adapter.parse_update({"nomessage": 1}) is None, "adapter: tolerant of a non-message update")
check(chat_adapter.parse_update("not a dict") is None, "adapter: tolerant of a non-dict update")
check(chat_adapter.parse_update({"message": {"chat": {"id": 1}}}) is None,
      "adapter: a message with no text is ignored")

check(chat_adapter.is_active() is False, "adapter: INACTIVE without a bot token")
noop = chat_adapter.send_message("42", "hi")
check((not noop["ok"]) and noop["reason"] == "inactive", "adapter: send is a clean no-op when inactive")

calls = []
def tx(method, payload, token):
    calls.append((method, payload, token))
    return {"ok": True, "result": {"message_id": 1}}
sent = chat_adapter.send_message("42", "hello", transport=tx, token="inj-token")
check(sent["ok"] and calls and calls[0][0] == "sendMessage"
      and calls[0][1] == {"chat_id": "42", "text": "hello"} and calls[0][2] == "inj-token",
      "adapter: injected transport carries the exact message")

import re
src = open(os.path.join(LIB, "chat_adapter.py")).read()
check("HEIMDALL_TELEGRAM_BOT_TOKEN" in src
      and re.search(r"\d{6,}:[A-Za-z0-9_-]{25,}", src) is None,
      "adapter: bot token from env only — no hardcoded token literal in the source")

print("::SUMMARY::%d::%d" % (P["pass"], P["fail"]))
sys.exit(1 if P["fail"] else 0)
PYEOF
DRIVER_RC=$?

# Fold the python driver's tally into the bash counters (parse the ::SUMMARY:: line is
# unnecessary — the RC already gates; count the driver as one aggregate result too).
if [ "$DRIVER_RC" -eq 0 ]; then
  ok "python driver: all classifier/binding/verb/adapter assertions passed"
else
  bad "python driver: one or more assertions FAILED (see above)"
fi

echo "-- (7) CLI — unbound refused, bound served ----------------------------------"

# Unbound chat via the CLI: the link instruction, NEVER team data.
CLI_UNBOUND="$("$CHAT_BIN" handle --chat-id "chat:ghost" --text "status" 2>&1 || true)"
if grep -qi "link" <<<"$CLI_UNBOUND" && \
   ! grep -q "status for team" <<<"$CLI_UNBOUND"; then
  ok "CLI: unbound chat is refused with the link instruction (no data)"
else
  bad "CLI: unbound chat was not cleanly refused: $CLI_UNBOUND"
fi

# Bound chat via the CLI (chat:alice was bound by the python driver, same HEIMDALL_HOME).
CLI_BOUND="$("$CHAT_BIN" handle --chat-id "chat:alice" --text "status" 2>&1 || true)"
if grep -q "status for team" <<<"$CLI_BOUND"; then
  ok "CLI: a bound chat is served its team status"
else
  bad "CLI: a bound chat was not served: $CLI_BOUND"
fi

# Bindings audit surface lists the bound chats.
CLI_BINDINGS="$("$CHAT_BIN" bindings 2>&1 || true)"
if grep -q "chat:alice" <<<"$CLI_BINDINGS"; then
  ok "CLI: bindings lists the bound chats"
else
  bad "CLI: bindings did not list the binding: $CLI_BINDINGS"
fi

# serve without a token exits 2 (inactive) — never blocks a tokenless box.
if "$CHAT_BIN" serve >/dev/null 2>&1; then
  bad "CLI: serve should refuse without a bot token"
else
  ok "CLI: serve refuses cleanly without a bot token (inactive)"
fi

echo "------------------------------------------------------------------------------"
echo "chat-ops P2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
