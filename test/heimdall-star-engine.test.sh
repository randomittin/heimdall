#!/usr/bin/env bash
# test/heimdall-star-engine.test.sh — acceptance for the STAR ENGINE + Δ6 funnel
# (queue #8): the viral README badge (bin/heimdall-badge), the shareable gate/wall
# clip card (bin/heimdall-clip), audit-on-init (bin/lib/repo_audit.py wired into
# bin/heimdall-init, Δ2), and the launch FUNNEL (bin/lib/funnel.py +
# bin/heimdall-funnel, Δ6) — all client-side, reusing the merged corpus #4
# consent/zero-content/secret-scan machinery with NO new control-plane route.
#
# Every assertion runs against the REAL bins + REAL engines (no network, no ingest).
# Sections:
#   (A) BADGE — markdown + SVG carry the runheimdall.dev BACKLINK and the LOCAL
#       proven-merge number. FALSIFIER: a badge string with the backlink stripped
#       fails the backlink check (the check is real, not X-vs-X).
#   (B) CLIP — `clip --last` renders a card from a verdict fixture carrying the
#       sigil + the runheimdall.dev tag; `--wall` + `--json` shapes hold.
#   (C) AUDIT-ON-INIT — `hmd init` PRINTS + STORES a number, exit 0 (non-blocking).
#   (D) FUNNEL — install/init/invite_sent/join/badge_added land in the shared
#       telemetry spool; consent OFF => none; a planted source/path => BLOCKED.
#   (E) ROUTER — `hmd badge|clip|funnel` dispatch to their bins + forward args;
#       an unknown command does NOT route (falsifier).
#   (S) SYNTAX — bash -n on the bins + py_compile on the engines.
#
# Exit 0 = every executed assertion passed. Non-zero = a regression.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BADGE="$ROOT/bin/heimdall-badge"
CLIP="$ROOT/bin/heimdall-clip"
FUNNEL="$ROOT/bin/heimdall-funnel"
INIT="$ROOT/bin/heimdall-init"
INVITE="$ROOT/bin/heimdall-invite"
HMD="$ROOT/bin/heimdall"
TEL="$ROOT/bin/heimdall-telemetry-corpus"
FUNNEL_LIB="$ROOT/bin/lib/funnel.py"
AUDIT_LIB="$ROOT/bin/lib/repo_audit.py"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
for f in "$BADGE" "$CLIP" "$FUNNEL" "$INIT" "$HMD"; do
  [ -x "$f" ] || { echo "FATAL: $f not executable" >&2; exit 2; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "hmd-star-test.$(printf 'q%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

BACKLINK="https://runheimdall.dev"

# make_repo DIR — a git repo with a verdict + a beats spool (2 pass, 1 deny).
make_repo() {
  local d="$1"
  mkdir -p "$d/.heimdall/receipts"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
  printf '{"verdict":"pass","phase":"pre-commit","ts":"2026-06-26T10:00:00Z","gate":"oracle","file":"src/api/users.js","reasons":[]}\n' \
    > "$d/.heimdall/verdict.json"
  printf '2026-06-26T09:00:00Z\tpass\tsrc/a.js\n2026-06-26T09:30:00Z\tpass\tsrc/b.js\n2026-06-26T09:45:00Z\tdeny\tsrc/c.js\n' \
    > "$d/.heimdall/receipts/beats.log"
}

funnel_count() {  # $1 corpus home, $2 stage
  "$FUNNEL" counts --home "$1" --json 2>/dev/null \
    | "$PY" -c "import json,sys;print(json.load(sys.stdin)['counts']['$2'])" 2>/dev/null
}

printf "\n=== heimdall-star-engine (badge + clip + audit-on-init + Δ6 funnel) ===\n"

# ─────────────────────────────────────────────────────────────────────────────
# (A) BADGE — backlink + local number in markdown AND svg; falsifier is real.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[A] badge: markdown + SVG carry the runheimdall.dev backlink + the number\n"
export HEIMDALL_CORPUS_HOME="$WORK/A-home"
REPO_A="$WORK/A-repo"; make_repo "$REPO_A"

MD="$(cd "$REPO_A" && "$BADGE" --markdown 2>/dev/null)"
SVG="$(cd "$REPO_A" && "$BADGE" --svg 2>/dev/null)"
CNT="$(cd "$REPO_A" && "$BADGE" --count 2>/dev/null)"

if grep -qF "$BACKLINK" <<<"$MD"; then
  ok "(A1) badge markdown carries the runheimdall.dev backlink"
else
  bad "(A1) badge markdown missing backlink: $MD"
fi
if grep -qF "2 proven merges" <<<"$MD"; then
  ok "(A2) badge markdown carries the LOCAL number (2 proven merges)"
else
  bad "(A2) badge markdown missing the local number: $MD"
fi
if grep -qF "$BACKLINK" <<<"$SVG"; then
  ok "(A3) badge SVG carries the runheimdall.dev backlink"
else
  bad "(A3) badge SVG missing backlink"
fi
if [ "$CNT" = "2" ]; then
  ok "(A4) badge --count reports the proven-merge count (2)"
else
  bad "(A4) badge --count wrong: $CNT (want 2)"
fi
# FALSIFIER: strip the backlink from the markdown → the SAME check must go RED.
MD_STRIPPED="$(printf '%s' "$MD" | sed "s#$BACKLINK##g")"
if grep -qF "$BACKLINK" <<<"$MD_STRIPPED"; then
  bad "(A5) FALSIFIER broken: backlink check passed on a stripped badge"
else
  ok "(A5) falsifier real: a badge WITHOUT the backlink fails the backlink check"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (B) CLIP — a card from a fixture: sigil + runheimdall.dev tag.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[B] clip --last: card from a verdict fixture (sigil + tag)\n"
export HEIMDALL_CORPUS_HOME="$WORK/B-home"
REPO_B="$WORK/B-repo"; make_repo "$REPO_B"

CARD="$(cd "$REPO_B" && "$CLIP" --last 2>/dev/null)"
if grep -qF "🛡" <<<"$CARD"; then
  ok "(B1) clip --last renders the sigil (🛡)"
else
  bad "(B1) clip --last missing the sigil"
fi
if grep -qF "runheimdall.dev" <<<"$CARD"; then
  ok "(B2) clip --last carries the runheimdall.dev tag"
else
  bad "(B2) clip --last missing the runheimdall.dev tag"
fi
if grep -qF "PASS" <<<"$CARD"; then
  ok "(B3) clip --last reflects the fixture verdict (PASS)"
else
  bad "(B3) clip --last did not reflect the fixture verdict: $CARD"
fi
CJSON="$(cd "$REPO_B" && "$CLIP" --last --json 2>/dev/null)"
CJ_OK="$(printf '%s' "$CJSON" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print('OK' if d.get('kind')=='last' and d.get('tag')=='runheimdall.dev' and d.get('verdict')=='pass' and d.get('proven_count')==2 else 'BAD:%s'%d)" 2>/dev/null)"
if [ "$CJ_OK" = "OK" ]; then
  ok "(B4) clip --json carries kind/tag/verdict/proven_count"
else
  bad "(B4) clip --json shape wrong: $CJ_OK"
fi
WALL="$(cd "$REPO_B" && "$CLIP" --wall 2>/dev/null)"
if grep -qF "🛡" <<<"$WALL" && grep -qF "2 merges proven" <<<"$WALL"; then
  ok "(B5) clip --wall renders the proven wall (sigil + count)"
else
  bad "(B5) clip --wall wrong: $WALL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (C) AUDIT-ON-INIT — hmd init PRINTS + STORES a number, exit 0, non-blocking.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[C] audit-on-init: prints + stores a number, init still exit 0\n"
export HEIMDALL_CORPUS_HOME="$WORK/C-home"
REPO_C="$WORK/C-repo"; mkdir -p "$REPO_C/src" "$REPO_C/test"
( cd "$REPO_C" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'export const a=1\n' > src/users.js \
  && printf 'test(1)\n' > test/users.test.js \
  && printf 'x=1\n' > src/thing.py \
  && git add -A && git commit -qm init )

INIT_OUT="$(cd "$REPO_C" && "$INIT" 2>/dev/null)"; INIT_RC=$?
if [ "$INIT_RC" = "0" ]; then
  ok "(C1) hmd init exit 0 (audit is non-blocking)"
else
  bad "(C1) hmd init exit $INIT_RC (audit must not block)"
fi
if grep -qE "heimdall audited .*: [0-9]+ files, [0-9]+% gate-covered, [0-9]+ reuse candidates" <<<"$INIT_OUT"; then
  ok "(C2) init printed the postable audit number"
else
  bad "(C2) init did not print the audit headline: $INIT_OUT"
fi
if [ -f "$REPO_C/.heimdall/audit.json" ]; then
  AUD_OK="$("$PY" -c "import json;d=json.load(open('$REPO_C/.heimdall/audit.json'));print('OK' if d.get('schema')=='audit_v1' and isinstance(d.get('files'),int) and isinstance(d.get('gate_covered_pct'),int) and isinstance(d.get('reuse_candidates'),int) else 'BAD')" 2>/dev/null)"
  [ "$AUD_OK" = "OK" ] && ok "(C3) audit.json stored with numeric files/gate_covered_pct/reuse_candidates" \
                       || bad "(C3) audit.json shape wrong: $AUD_OK"
else
  bad "(C3) audit.json was not stored"
fi
# audit.json must be gitignored (transient local state, like verdict.json).
if grep -qxF ".heimdall/audit.json" "$REPO_C/.gitignore" 2>/dev/null; then
  ok "(C4) audit.json is gitignored (transient local state)"
else
  bad "(C4) audit.json not added to .gitignore"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (D) FUNNEL — the five stages land in the shared spool; off => none; planted
#     source/path => BLOCKED; the local view counts them.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[D] Δ6 funnel: stages -> spool, consent-gated, zero-content\n"
export HEIMDALL_CORPUS_HOME="$WORK/D-home"
# funnel + pmr share ONE corpus home (sibling namespaces) — prove it.
FDIR="$("$PY" -c "import sys;sys.path.insert(0,'$ROOT/bin/lib');import funnel;print(funnel.funnel_dir('$HEIMDALL_CORPUS_HOME'))")"
PDIR="$("$PY" -c "import sys;sys.path.insert(0,'$ROOT/bin/lib');import pmr_corpus;print(pmr_corpus.pmr_dir('$HEIMDALL_CORPUS_HOME'))")"
if [ "$(dirname "$FDIR")" = "$(dirname "$PDIR")" ]; then
  ok "(D1) funnel spool is a SIBLING of the pmr spool (shared telemetry home, no CP route)"
else
  bad "(D1) funnel/pmr not siblings: $FDIR vs $PDIR"
fi
# Emit each of the five growth-loop stages through the bin.
for st in install init invite_sent join badge_added; do
  "$FUNNEL" emit "$st" --context test --home "$HEIMDALL_CORPUS_HOME" >/dev/null 2>&1
done
ALL5="$("$FUNNEL" counts --home "$HEIMDALL_CORPUS_HOME" --json 2>/dev/null | "$PY" -c "import json,sys;c=json.load(sys.stdin)['counts'];print(all(c[s]>=1 for s in ['install','init','invite_sent','join','badge_added']))" 2>/dev/null)"
if [ "$ALL5" = "True" ]; then
  ok "(D2) all five stages (install/init/invite_sent/join/badge_added) recorded to the spool"
else
  bad "(D2) not all five stages recorded: $("$FUNNEL" counts --home "$HEIMDALL_CORPUS_HOME" --json)"
fi
# consent OFF (env kill-switch) => a fresh home records NOTHING.
export HEIMDALL_CORPUS_HOME="$WORK/D-off"
OFF="$(HEIMDALL_TELEMETRY=off "$FUNNEL" emit init --home "$HEIMDALL_CORPUS_HOME" 2>/dev/null)"
OFF_N="$(funnel_count "$HEIMDALL_CORPUS_HOME" init)"
if grep -q '"reason": *"disabled"' <<<"$OFF" && [ "${OFF_N:-0}" = "0" ]; then
  ok "(D3) consent OFF -> emit is a no-op, ZERO events written"
else
  bad "(D3) off not honored: $OFF (init count=$OFF_N)"
fi
# consent OFF via persisted telemetry consent (the `hmd telemetry off` control).
export HEIMDALL_CORPUS_HOME="$WORK/D-off2"
if [ -x "$TEL" ]; then
  "$TEL" off >/dev/null 2>&1
  OFF2="$("$FUNNEL" emit init --home "$HEIMDALL_CORPUS_HOME" 2>/dev/null)"
  if grep -q '"reason": *"disabled"' <<<"$OFF2"; then
    ok "(D4) persisted 'telemetry off' consent is honored by the funnel (shared consent)"
  else
    bad "(D4) persisted off not honored by funnel: $OFF2"
  fi
else
  bad "(D4) telemetry-corpus CLI missing"
fi
# ZERO-CONTENT: a planted real path in --context => BLOCKED + nothing written.
export HEIMDALL_CORPUS_HOME="$WORK/D-zc"
BEFORE_ZC="$(funnel_count "$HEIMDALL_CORPUS_HOME" init)"; BEFORE_ZC="${BEFORE_ZC:-0}"
ZC="$("$FUNNEL" emit init --context "/Users/rj/secret/app/config.py" --home "$HEIMDALL_CORPUS_HOME" 2>"$WORK/zc.err")"
AFTER_ZC="$(funnel_count "$HEIMDALL_CORPUS_HOME" init)"; AFTER_ZC="${AFTER_ZC:-0}"
if grep -q 'zero-content-blocked' <<<"$ZC" && [ "$BEFORE_ZC" = "$AFTER_ZC" ]; then
  ok "(D5) planted PATH in a funnel event -> BLOCKED, nothing written (zero-content)"
else
  bad "(D5) planted path not blocked: $ZC (before=$BEFORE_ZC after=$AFTER_ZC)"
fi
# ZERO-CONTENT: a planted source line (code punctuation) => BLOCKED.
ZC2="$("$FUNNEL" emit join --context "const x = (a,b) => a+b;" --home "$HEIMDALL_CORPUS_HOME" 2>/dev/null)"
if grep -q 'zero-content-blocked' <<<"$ZC2"; then
  ok "(D6) planted SOURCE LINE in a funnel event -> BLOCKED (zero-content)"
else
  bad "(D6) planted source line not blocked: $ZC2"
fi

# FUNCTIONAL WIRING: the real surfaces emit their stage.
printf "\n[D-wire] the growth-loop surfaces emit their funnel stage\n"
# init -> init event (fresh home + fresh repo).
export HEIMDALL_CORPUS_HOME="$WORK/Dw-init"
REPO_DI="$WORK/Dw-repo"; mkdir -p "$REPO_DI"
( cd "$REPO_DI" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'x\n' > a.py && git add -A && git commit -qm init )
( cd "$REPO_DI" && "$INIT" >/dev/null 2>&1 )
sleep 0.4
if [ "$(funnel_count "$HEIMDALL_CORPUS_HOME" init)" -ge 1 ] 2>/dev/null; then
  ok "(D7) hmd init emits the 'init' funnel stage"
else
  bad "(D7) init did not emit an init funnel event"
fi
# badge -> badge_added event.
export HEIMDALL_CORPUS_HOME="$WORK/Dw-badge"
REPO_DB="$WORK/Dw-badge-repo"; make_repo "$REPO_DB"
( cd "$REPO_DB" && "$BADGE" --count >/dev/null 2>&1 )
sleep 0.4
if [ "$(funnel_count "$HEIMDALL_CORPUS_HOME" badge_added)" -ge 1 ] 2>/dev/null; then
  ok "(D8) hmd badge emits the 'badge_added' funnel stage"
else
  bad "(D8) badge did not emit a badge_added funnel event"
fi
# The remaining three surfaces carry the emit wiring (install.sh / invite / join route).
WIRE_OK=1
grep -q 'FUNNEL_BIN" emit install'      "$ROOT/install.sh" || WIRE_OK=0
grep -q 'FUNNEL_BIN" emit invite_sent'  "$INVITE"          || WIRE_OK=0
grep -q 'FUNNEL_BIN" emit join'         "$HMD"             || WIRE_OK=0
if [ "$WIRE_OK" = "1" ]; then
  ok "(D9) install.sh / hmd invite / hmd join carry the funnel emit wiring"
else
  bad "(D9) a growth-loop surface is missing its funnel emit wiring"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (E) ROUTER — hmd badge|clip|funnel dispatch + forward args; unknown does not.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[E] router: hmd badge|clip|funnel dispatch + forward args\n"
FAKE="$(mktemp -d /tmp/star-routing-XXXXXX)"
mkdir -p "$FAKE/bin" "$FAKE/home" "$FAKE/.claude-plugin"
cp "$HMD" "$FAKE/bin/heimdall"; chmod +x "$FAKE/bin/heimdall"
touch "$FAKE/home/setup-done"
cat > "$FAKE/bin/claude" <<'EOB'
#!/usr/bin/env bash
exit 0
EOB
chmod +x "$FAKE/bin/claude"
STUB_OUT="$(mktemp /tmp/star-stub-XXXXXX)"
TRACE="$(mktemp /tmp/star-trace-XXXXXX)"
mk_stub() {
  cat > "$FAKE/bin/$1" <<EOB
#!/usr/bin/env bash
printf '%s ARGS: %s\n' "$1" "\$*" >> "\${HMD_STUB_OUT:-/dev/null}"
exit 0
EOB
  chmod +x "$FAKE/bin/$1"
}
mk_stub heimdall-badge
mk_stub heimdall-clip
mk_stub heimdall-funnel
run_fake() {
  PATH="$FAKE/bin:$PATH" HEIMDALL_HOME="$FAKE/home" HEIMDALL_NO_INTRO=1 \
    HEIMDALL_NO_UPDATE_CHECK=1 HMD_STUB_OUT="$STUB_OUT" HEIMDALL_TRACE_ORDER="$TRACE" \
    bash "$FAKE/bin/heimdall" "$@" >/dev/null 2>&1 || true
}
rstub() { : > "$STUB_OUT"; : > "$TRACE"; }

rstub; run_fake badge --svg
if grep -q "heimdall-badge" "$STUB_OUT" && grep -qF -- "--svg" "$STUB_OUT"; then
  ok "(E1) hmd badge routes to heimdall-badge (--svg forwarded)"
else
  bad "(E1) badge routing failed: $(cat "$STUB_OUT")"
fi
rstub; run_fake clip --wall
if grep -q "heimdall-clip" "$STUB_OUT" && grep -qF -- "--wall" "$STUB_OUT"; then
  ok "(E2) hmd clip routes to heimdall-clip (--wall forwarded)"
else
  bad "(E2) clip routing failed: $(cat "$STUB_OUT")"
fi
rstub; run_fake funnel emit init --context cli
if grep -q "heimdall-funnel" "$STUB_OUT" && grep -qF -- "emit init --context cli" "$STUB_OUT"; then
  ok "(E3) hmd funnel routes to heimdall-funnel (args forwarded)"
else
  bad "(E3) funnel routing failed: $(cat "$STUB_OUT")"
fi
# FALSIFIER: an unknown command must NOT route to any of the three stubs.
rstub; run_fake "build-something-unknown-xyz-abcdef"
if grep -q "launch:task" "$TRACE" \
   && ! grep -q "heimdall-badge" "$STUB_OUT" \
   && ! grep -q "heimdall-clip" "$STUB_OUT" \
   && ! grep -q "heimdall-funnel" "$STUB_OUT"; then
  ok "(E4) unknown command falls through to Claude, routes to no star stub (falsifier)"
else
  bad "(E4) unknown command mis-routed: trace=$(cat "$TRACE") stubs=$(cat "$STUB_OUT")"
fi
rm -rf "$FAKE" "$STUB_OUT" "$TRACE"

# ─────────────────────────────────────────────────────────────────────────────
# (S) SYNTAX — bash -n on the bins + py_compile on the engines.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[S] syntax: bash -n + py_compile\n"
SYN=1
for f in "$BADGE" "$CLIP" "$FUNNEL" "$INIT" "$INVITE" "$HMD" "$ROOT/install.sh"; do
  bash -n "$f" 2>/dev/null || { SYN=0; echo "    bash -n FAILED: $f" >&2; }
done
[ "$SYN" = "1" ] && ok "(S1) all touched bash files pass bash -n" || bad "(S1) a bash file failed bash -n"
if "$PY" -m py_compile "$FUNNEL_LIB" "$AUDIT_LIB" 2>/dev/null; then
  ok "(S2) funnel.py + repo_audit.py pass py_compile"
else
  bad "(S2) an engine failed py_compile"
fi

# ─────────────────────────────────────────────────────────────────────────────
printf "\n=== RESULT: %d passed, %d failed ===\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
