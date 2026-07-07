#!/usr/bin/env bash
# test/heimdall-watch.test.sh — acceptance test for `hmd watch`, the TUI dashboard
# (spec section C of heimdall-tui-statusline-sigil-spec.md; Tests 4-5).
#
# The dashboard is bin/heimdall-watch-tui (a distinct name — bin/heimdall-watch is
# already the H-3 sentinel watch-mode tool, mirroring the heimdall-drain anti-clobber
# convention). Data core: bin/lib/watch_data.py (pure-local reads, NO network).
# Textual app: bin/lib/watch_tui.py (consumes hmd_sigil + hmd_termcaps render core).
#
# HERMETIC: no network, no live model, no control-plane. A NETWORK TRIPWIRE (fake
# curl/wget on PATH + a sitecustomize that hooks socket.connect) records ANY outbound
# connection so the zero-additional-server-load requirement is falsifiable.
#
# Proves (spec Tests 4-5):
#   (1) ZERO ADDITIONAL SERVER CALLS — a watch session (static dump path) issues no
#       network requests. Negative-control: an inline connect IS caught by the same
#       tripwire (proves the assertion in (1) is meaningful, not vacuous).
#   (2) INSPECTOR renders a fixture DENY receipt: reason code + text, failing hunk,
#       falsify/reuse/bloat numbers, retry history.
#   (3) KEYMAP conformance: j/k/enter/c/i/p/r/a/d/?/q all bound to the right action.
#   (4) SHELLS EXISTING CLI (renderer over plumbing): c->hmd clip, i->hmd invite,
#       p->hmd presence, a->hmd approve, d->hmd deny — argv is a shell-out, and the
#       data core carries NO inline verdict/gate/presence logic.
#   (5) ENTITLEMENT pane-locking BOTH states: dark flag OFF (default) => all unlocked;
#       flag ON => history/trends/analytics/archive locked + one-line upsell.
#   (6) DARK FLAG DEFAULTS UNLOCKED: no entitlement key in the roster payload => unlocked.
#   (7) NO team-SIZE gating (Δ1 invariant): a 10-member team and a 2-member team are
#       BOTH fully unlocked at the free tier; wall is never locked at any size.
#   (8) TEXTUAL-ABSENT DEGRADE: heimdall-watch-tui --once prints a wall+feed dump plus
#       a clean `pip install textual` hint, exit 0 (not a hard dependency).
#   (9) LOCAL-ONLY read paths (cp-team-isolation invariant): watch_data.py imports no
#       socket/urllib/http and constructs no cross-team read path.
#  (10) bash -n / py_compile clean.
#
# Exit 0 = "N passed, 0 failed". Any failure is non-zero.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/bin/heimdall-watch-tui"
DATA="$ROOT/bin/lib/watch_data.py"
APP="$ROOT/bin/lib/watch_tui.py"
ENTRY="$ROOT/bin/lib/watch_entry.py"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t watch-tui.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ── existence / compile ─────────────────────────────────────────────────────
[ -f "$BIN" ]   || { echo "FATAL: $BIN missing" >&2; exit 2; }
[ -f "$DATA" ]  || { echo "FATAL: $DATA missing" >&2; exit 2; }
[ -f "$APP" ]   || { echo "FATAL: $APP missing" >&2; exit 2; }
[ -f "$ENTRY" ] || { echo "FATAL: $ENTRY missing" >&2; exit 2; }
chmod +x "$BIN" 2>/dev/null || true

bash -n "$BIN" 2>/dev/null && ok "(10) heimdall-watch-tui passes bash -n" \
  || bad "(10) heimdall-watch-tui FAILS bash -n"
"$PY" -m py_compile "$DATA" "$APP" "$ENTRY" 2>/tmp/wt_pyc.txt \
  && ok "(10) watch_data + watch_tui + watch_entry py_compile clean" \
  || { bad "(10) py_compile FAILED"; cat /tmp/wt_pyc.txt; }

# ── build a fake repo with LOCAL caches (roster, feed, receipt) ──────────────
REPO="$WORK/repo"
mkdir -p "$REPO/.heimdall"
export HEIMDALL_HOME="$WORK/home"; mkdir -p "$HEIMDALL_HOME"

cat > "$REPO/.heimdall/roster-cache.json" <<'JSON'
{
  "team": "acme",
  "members": [
    {"handle": "you",   "haid": "haid:rj-a3f9", "verdict": "PASS", "file": "api.py",   "age_seconds": 5},
    {"handle": "K",     "haid": "haid:nadia",   "verdict": "DENY", "file": "auth.py",  "age_seconds": 42},
    {"handle": "M",     "haid": "haid:arjun",   "verdict": "IDLE", "file": "-",        "age_seconds": 300}
  ]
}
JSON

cat > "$REPO/.heimdall/report-a3f1.json" <<'JSON'
{
  "verdict": "DENY",
  "ref": "a3f1",
  "gate": "oracle",
  "reason_code": "api_contract_break",
  "reason_text": "get_user signature changed; downstream callers break",
  "diff": "- def get_user(id):\n+ def get_user(uid, *, ctx):",
  "diff_lang": "python",
  "falsify": {"survived": 12, "total": 12},
  "reuse": {"score": 0.83},
  "bloat": {"added_lines": 40, "budget": 120},
  "retries": [
    {"attempt": 1, "verdict": "DENY", "reason": "api_contract_break"}
  ],
  "time_to_green": null
}
JSON

cat > "$REPO/.heimdall/feed.jsonl" <<JSON
{"ts": 1700000135, "verdict": "PASS", "kind": "merge", "ref": "a3f1b2", "haid": "haid:rj-a3f9", "handle": "you", "summary": "merge proven"}
{"ts": 1700000101, "verdict": "DENY", "kind": "oracle", "ref": "a3f1", "haid": "haid:nadia", "handle": "K", "summary": "contract break", "receipt_path": "$REPO/.heimdall/report-a3f1.json"}
{"ts": 1700000015, "verdict": "PASS", "kind": "falsify", "ref": "77aa", "haid": "haid:arjun", "handle": "M", "summary": "falsify 12/12 survived"}
JSON

# ── network tripwire: a sitecustomize that logs any socket.connect ───────────
TRIP="$WORK/tripwire"; mkdir -p "$TRIP"
export TRIPWIRE_LOG="$WORK/net.log"; : > "$TRIPWIRE_LOG"
cat > "$TRIP/sitecustomize.py" <<'PY'
import os, socket
_log = os.environ.get("TRIPWIRE_LOG")
def _record(where):
    try:
        with open(_log, "a") as f:
            f.write(where + "\n")
    except Exception:
        return None
_orig_connect = socket.socket.connect
def _connect(self, address):
    _record("socket.connect %r" % (address,))
    return _orig_connect(self, address)
socket.socket.connect = _connect
_orig_cc = socket.create_connection
def _cc(address, *a, **k):
    _record("create_connection %r" % (address,))
    return _orig_cc(address, *a, **k)
socket.create_connection = _cc
PY

FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for c in curl wget nc; do
  cat > "$FAKEBIN/$c" <<SH
#!/usr/bin/env bash
echo "\$0 \$*" >> "$TRIPWIRE_LOG"
exit 7
SH
  chmod +x "$FAKEBIN/$c"
done

run_watch_once() {
  PYTHONPATH="$TRIP${PYTHONPATH:+:$PYTHONPATH}" PATH="$FAKEBIN:$PATH" \
    NO_COLOR=1 HEIMDALL_STATUSLINE_MODE=mono \
    HEIMDALL_WATCH_ROOT="$REPO" HEIMDALL_HOME="$HEIMDALL_HOME" \
    "$BIN" --once 2>&1
}

# ── (1) ZERO ADDITIONAL SERVER CALLS ────────────────────────────────────────
: > "$TRIPWIRE_LOG"
DUMP="$(run_watch_once)"; wrc=$?
if [ -s "$TRIPWIRE_LOG" ]; then
  bad "(1) watch session made a network call:"; sed 's/^/      /' "$TRIPWIRE_LOG"
else
  ok "(1) watch session made ZERO network calls (tripwire log empty)"
fi

# ── (1b) negative control — the tripwire DOES catch a real connection ────────
: > "$TRIPWIRE_LOG"
PYTHONPATH="$TRIP${PYTHONPATH:+:$PYTHONPATH}" "$PY" - <<'PY' >/dev/null 2>&1 || true
import socket
try:
    socket.create_connection(("127.0.0.1", 9), timeout=0.1)
except Exception:
    _ = None
PY
if [ -s "$TRIPWIRE_LOG" ]; then
  ok "(1b) negative control: tripwire catches a real connect (assertion is meaningful)"
else
  bad "(1b) negative control FAILED: tripwire did not catch a real connect"
fi

# ── (8) TEXTUAL-ABSENT DEGRADE ───────────────────────────────────────────────
if [ "$wrc" -eq 0 ]; then ok "(8) heimdall-watch-tui --once exits 0"; else bad "(8) --once exit rc=$wrc"; fi
printf '%s' "$DUMP" | grep -qi 'WALL' && printf '%s' "$DUMP" | grep -qi 'FEED' \
  && ok "(8) static dump shows WALL + FEED sections" \
  || bad "(8) static dump missing WALL/FEED"
printf '%s' "$DUMP" | grep -q 'you' && printf '%s' "$DUMP" | grep -q 'merge proven' \
  && ok "(8) static dump renders roster member + newest feed event" \
  || bad "(8) static dump missing roster/feed content"
if "$PY" -c 'import textual' 2>/dev/null; then
  ok "(8) textual present — install-hint path not exercised (ok)"
else
  printf '%s' "$DUMP" | grep -qi 'pip install textual' \
    && ok "(8) textual-absent prints 'pip install textual' hint" \
    || bad "(8) textual-absent did not print install hint"
fi
if printf '%s' "$DUMP" | grep -n 'merge proven\|falsify 12/12' | head -2 \
     | awk 'NR==1{a=$0} END{exit !(a ~ /merge proven/)}'; then
  ok "(8) feed is newest-first"
else
  bad "(8) feed ordering not newest-first"
fi

# ── (2) INSPECTOR renders the fixture DENY receipt ──────────────────────────
INSP="$(NO_COLOR=1 HEIMDALL_STATUSLINE_MODE=mono "$PY" - "$DATA" "$ROOT/sentinels" "$REPO/.heimdall/report-a3f1.json" "$REPO" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("watch_data", sys.argv[1])
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)
caps = wd.load_caps(sys.argv[2])
# read_receipt is confined to <root>/.heimdall — pass the fixture repo root so the
# (absolute, in-base) fixture receipt resolves inside the allowlisted base.
rec = wd.read_receipt({"receipt_path": sys.argv[3], "ref": "a3f1"}, sys.argv[4])
print("\n".join(wd.render_inspector(rec, caps)))
PY
)"
chk() { printf '%s' "$INSP" | grep -qF -- "$1" && ok "(2) inspector shows: $2" || bad "(2) inspector MISSING: $2"; }
chk "api_contract_break" "deny reason code"
chk "get_user signature changed" "human reason text"
chk "- def get_user(id):" "failing hunk (removed line)"
chk "+ def get_user(uid, *, ctx):" "failing hunk (added line)"
chk "12/12" "falsify numbers"
chk "0.83" "reuse number"
chk "40" "bloat number"
printf '%s' "$INSP" | grep -qiE 'retr(y|ies)' && ok "(2) inspector shows retry history" || bad "(2) inspector missing retry history"

# ── (3)+(4) KEYMAP conformance + SHELLS EXISTING CLI ─────────────────────────
KEYOUT="$("$PY" - "$DATA" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("watch_data", sys.argv[1])
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)
km = wd.KEYMAP
for k in ["j","k","enter","c","i","p","r","a","d","?","q"]:
    print("KEY %s -> %s" % (k, km.get(k, "MISSING")))
ev = {"ref": "a3f1", "haid": "haid:x", "handle": "K"}
for act in ["clip","invite","presence","approve","deny"]:
    argv = wd.build_shell_argv(act, "hmd", ev)
    print("SHELL %s -> %s" % (act, " ".join(argv)))
PY
)"
for pair in "j:select" "k:select" "enter:inspect" "c:clip" "i:invite" "p:presence" "r:reports" "a:approve" "d:deny" "?:help" "q:quit"; do
  key="${pair%%:*}"; act="${pair##*:}"
  # fixed-string match on the "KEY <key> -> " prefix (key may be a regex metachar
  # like '?'), then confirm the action substring on the same line.
  if printf '%s' "$KEYOUT" | grep -F -- "KEY $key -> " | grep -qF -- "$act"; then
    ok "(3) keymap $key -> $act"
  else
    bad "(3) keymap $key NOT -> $act"
  fi
done
printf '%s' "$KEYOUT" | grep -qE 'SHELL clip -> hmd clip'         && ok "(4) c shells 'hmd clip'"     || bad "(4) c does not shell hmd clip"
printf '%s' "$KEYOUT" | grep -qE 'SHELL invite -> hmd invite'     && ok "(4) i shells 'hmd invite'"   || bad "(4) i does not shell hmd invite"
printf '%s' "$KEYOUT" | grep -qE 'SHELL presence -> hmd presence' && ok "(4) p shells 'hmd presence'" || bad "(4) p does not shell hmd presence"
printf '%s' "$KEYOUT" | grep -qE 'SHELL approve -> hmd approve'   && ok "(4) a shells 'hmd approve'"  || bad "(4) a does not shell hmd approve"
printf '%s' "$KEYOUT" | grep -qE 'SHELL deny -> hmd deny'         && ok "(4) d shells 'hmd deny'"     || bad "(4) d does not shell hmd deny"

# ── (5)+(6)+(7) ENTITLEMENT ──────────────────────────────────────────────────
ENT="$("$PY" - "$DATA" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("watch_data", sys.argv[1])
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)
e0 = wd.resolve_entitlement({"members": [1,2]}, env={})
print("DEFAULT enforced=%s" % e0.enforced)
print("DEFAULT history_locked=%s" % e0.locked("history"))
print("DEFAULT wall_locked=%s" % e0.locked("wall"))
big = {"members": list(range(10)), "entitlement": {"enforced": True, "tier": "free"}}
e1 = wd.resolve_entitlement(big, env={})
print("ON enforced=%s" % e1.enforced)
for f in ["history","trends","analytics","archive"]:
    print("ON locked_%s=%s" % (f, e1.locked(f)))
for f in ["wall","feed","inspector","reports","clip","invite","presence"]:
    print("ON free_%s_locked=%s" % (f, e1.locked(f)))
print("ON upsell=%s" % ("yes" if e1.upsell("history") else "no"))
e_small = wd.resolve_entitlement({"members": [1,2]}, env={})
e_big   = wd.resolve_entitlement({"members": list(range(10))}, env={})
print("SIZE small_wall_locked=%s" % e_small.locked("wall"))
print("SIZE big_wall_locked=%s"   % e_big.locked("wall"))
print("SIZE small_history_locked=%s" % e_small.locked("history"))
print("SIZE big_history_locked=%s"   % e_big.locked("history"))
PY
)"
egrep_ok() { printf '%s' "$ENT" | grep -qxF "$1" && ok "$2" || { bad "$2 (want: $1)"; printf '%s\n' "$ENT" | sed 's/^/      /'; }; }
egrep_ok "DEFAULT enforced=False"       "(6) dark flag defaults OFF"
egrep_ok "DEFAULT history_locked=False" "(6) default: history UNLOCKED"
egrep_ok "DEFAULT wall_locked=False"    "(6) default: wall UNLOCKED"
egrep_ok "ON enforced=True"             "(5) flag ON: enforced"
egrep_ok "ON locked_history=True"       "(5) flag ON: history LOCKED"
egrep_ok "ON locked_trends=True"        "(5) flag ON: trends LOCKED"
egrep_ok "ON locked_analytics=True"     "(5) flag ON: analytics LOCKED"
egrep_ok "ON locked_archive=True"       "(5) flag ON: archive LOCKED"
egrep_ok "ON free_wall_locked=False"    "(5) flag ON: wall still FREE"
egrep_ok "ON free_feed_locked=False"    "(5) flag ON: feed still FREE"
egrep_ok "ON free_reports_locked=False" "(5) flag ON: reports still FREE"
egrep_ok "ON upsell=yes"                "(5) flag ON: locked pane carries an upsell line"
egrep_ok "SIZE small_wall_locked=False" "(7) 2-member team: wall FREE (no size gate)"
egrep_ok "SIZE big_wall_locked=False"   "(7) 10-member team: wall FREE (no size gate)"
egrep_ok "SIZE small_history_locked=False" "(7) 2-member: history free when flag off"
egrep_ok "SIZE big_history_locked=False"   "(7) 10-member: history free when flag off (Δ1)"

# ── (9) LOCAL-ONLY read paths (cp-team-isolation invariant) ─────────────────
if grep -qE '^[[:space:]]*import[[:space:]]+(socket|urllib|http|requests|ftplib|telnetlib)|^[[:space:]]*from[[:space:]]+(urllib|http)[[:space:]. ]' "$DATA"; then
  bad "(9) watch_data.py imports a NETWORK module (violates zero-server-load)"
else
  ok "(9) watch_data.py imports NO network module (local-only)"
fi
if grep -qE 'teams/|/teams|team_id|other.?team|foreign.?team' "$DATA"; then
  bad "(9) watch_data.py references a cross-team path (new read path)"
else
  ok "(9) watch_data.py builds no cross-team read path (caller scope only)"
fi

# ── (4b) data core carries NO inline verdict/gate/presence LOGIC ─────────────
if grep -qiE 'def [a-z_]*(compute|decide|evaluate)[a-z_]*verdict|def run_gate|def do_approv|signing_seed|hmac\.' "$DATA"; then
  bad "(4b) data core reimplements verdict/gate/presence logic (invariant breach)"
else
  ok "(4b) data core is a renderer — no reimplemented verdict/gate/presence logic"
fi

# ── (11) dispatcher route: `hmd watch` reaches the TUI launcher ──────────────
HELP_OUT="$("$ROOT/bin/hmd" watch --help 2>&1 || true)"
printf '%s' "$HELP_OUT" | grep -qi 'TUI dashboard' \
  && ok "(11) 'hmd watch' routes to heimdall-watch-tui" \
  || bad "(11) 'hmd watch' did not route to the TUI launcher"

# ── SECURITY (each check is a falsifier: pre-fix RED, post-fix GREEN) ─────────
# Two vulns found in a security review of the merged TUI:
#   SEC-1 ARGUMENT-INJECTION — a data-derived ref (feed/roster) reaching a CLI as
#         an ARG could be read as a FLAG (--foo/-rf) or carry a shell metachar.
#   SEC-2 PATH-TRAVERSAL — a feed item's receipt_path reaching the INSPECTOR could
#         escape .heimdall via an absolute path / `..` / a symlink and read /etc/passwd.
printf "\n  ── SECURITY ──\n"

# ── SEC-1 argument-injection: a hostile ref is NEVER a flag / NEVER a shell string ─
SARG="$("$PY" - "$DATA" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("watch_data", sys.argv[1])
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)
bad_refs = ["--malicious", "-rf", "--output=/etc/cron.d/x", "; rm -rf /",
            "$(touch pwned)", "`id`", "a b c", "x;y", "\n--flag", "--"]
ok = True
for r in bad_refs:
    for act in ["approve", "deny", "clip"]:
        argv = wd.build_shell_argv(act, "hmd", {"ref": r})
        if not isinstance(argv, list):
            ok = False; print("UNSAFE %s %r: not a list -> %r" % (act, r, argv)); continue
        if not argv:
            continue  # rejected by the allowlist — a safe no-op (value never reaches CLI)
        if "--" not in argv:
            ok = False; print("UNSAFE %s %r: no -- terminator -> %r" % (act, r, argv)); continue
        term = argv.index("--")
        if r in argv[:term]:
            ok = False; print("UNSAFE %s %r: value BEFORE -- (flag position) -> %r" % (act, r, argv)); continue
print("ARGV", "ALLSAFE" if ok else "HASUNSAFE")
PY
)"
printf '%s' "$SARG" | grep -q 'ARGV ALLSAFE' \
  && ok "(SEC-1) argv-injection: hostile ref never a flag/shell string (rejected, or positional after --)" \
  || { bad "(SEC-1) argv-injection: a data-derived ref reached the CLI as a flag/metachar"; printf '%s\n' "$SARG" | sed 's/^/      /'; }

# executor must pass the argv LIST with shell=False — never build a shell string
if grep -q 'shell=True' "$APP"; then
  bad "(SEC-1) executor uses shell=True (shell-string / metachar risk)"
else
  ok "(SEC-1) executor never uses shell=True (argv list, shell=False)"
fi
grep -qE 'subprocess\.run\(argv' "$APP" \
  && ok "(SEC-1) executor passes the argv LIST to subprocess (never a joined string)" \
  || bad "(SEC-1) executor does not pass the argv list to subprocess"

# legit refs still work (allowlist accepts real ids; positional after --)
LEGITARG="$("$PY" - "$DATA" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("watch_data", sys.argv[1])
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)
for act in ["approve", "deny", "clip"]:
    print("LEGIT %s -> %s" % (act, " ".join(wd.build_shell_argv(act, "hmd", {"ref": "a3f1"}))))
print("LEGITHAID -> %s" % " ".join(wd.build_shell_argv("approve", "hmd", {"ref": "haid:rj-a3f9"})))
PY
)"
printf '%s' "$LEGITARG" | grep -qE 'LEGIT approve -> hmd approve -- a3f1' \
  && ok "(SEC-1c) legit ref still shells (positional after --)" \
  || { bad "(SEC-1c) legit ref no longer shells"; printf '%s\n' "$LEGITARG" | sed 's/^/      /'; }
printf '%s' "$LEGITARG" | grep -qE 'LEGITHAID -> hmd approve -- haid:rj-a3f9' \
  && ok "(SEC-1c) legit haid ref accepted by the allowlist" \
  || { bad "(SEC-1c) legit haid ref rejected by the allowlist"; printf '%s\n' "$LEGITARG" | sed 's/^/      /'; }

# ── SEC-2 path-traversal: INSPECTOR reads are confined to <root>/.heimdall ────
# A valid-JSON secret OUTSIDE the base (would be read+leaked pre-fix), plus a
# symlink inside .heimdall that escapes the base (realpath resolves it out).
printf '%s' '{"reason_text":"TOPSECRET_LEAK","ref":"pwned"}' > "$WORK/secret.json"
ln -sf "$WORK/secret.json" "$REPO/.heimdall/escape.json"

STRAV="$(NO_COLOR=1 "$PY" - "$DATA" "$REPO" "$WORK/secret.json" "$REPO/.heimdall/escape.json" "$REPO/.heimdall/report-a3f1.json" <<'PY' 2>&1
import importlib.util, sys, json
spec = importlib.util.spec_from_file_location("watch_data", sys.argv[1])
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)
root, abs_outside, symlink_escape, legit = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
def leaks(ref):
    blob = json.dumps(wd.read_receipt({"receipt_path": ref, "ref": "x", "summary": "s"}, root))
    return ("TOPSECRET_LEAK" in blob) or ("root:x:0:0" in blob) or ("root:*:0:0" in blob)
cases = [
    ("abs_outside_base", abs_outside),
    ("rel_traversal", "../../secret.json"),
    ("etc_passwd_abs", "/etc/passwd"),
    ("etc_passwd_rel", "../../../../../../etc/passwd"),
    ("symlink_escape", symlink_escape),
]
allrefused = True
for name, ref in cases:
    if leaks(ref):
        allrefused = False; print("LEAK %s via %r" % (name, ref))
    else:
        print("REFUSED %s" % name)
print("TRAVERSAL", "ALLREFUSED" if allrefused else "LEAKED")
# legit in-base receipt (absolute path under .heimdall) still readable
legit_blob = json.dumps(wd.read_receipt({"receipt_path": legit, "ref": "a3f1"}, root))
print("LEGIT_OK" if "api_contract_break" in legit_blob else "LEGIT_FAIL")
# legit in-base receipt (relative to the base) also readable
rel_blob = json.dumps(wd.read_receipt({"receipt_path": "report-a3f1.json", "ref": "a3f1"}, root))
print("LEGITREL_OK" if "api_contract_break" in rel_blob else "LEGITREL_FAIL")
PY
)"
printf '%s' "$STRAV" | grep -q 'TRAVERSAL ALLREFUSED' \
  && ok "(SEC-2) path-traversal: receipt reads confined to .heimdall (abs / .. / symlink escapes REFUSED)" \
  || { bad "(SEC-2) path-traversal: a crafted receipt_path escaped .heimdall"; printf '%s\n' "$STRAV" | sed 's/^/      /'; }
printf '%s' "$STRAV" | grep -q 'LEGIT_OK' \
  && ok "(SEC-2c) legit in-base receipt (absolute) still readable" \
  || { bad "(SEC-2c) legit in-base receipt broke"; printf '%s\n' "$STRAV" | sed 's/^/      /'; }
printf '%s' "$STRAV" | grep -q 'LEGITREL_OK' \
  && ok "(SEC-2c) legit in-base receipt (relative) still readable" \
  || bad "(SEC-2c) legit relative in-base receipt broke"

# ── summary ─────────────────────────────────────────────────────────────────
printf "\n  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
