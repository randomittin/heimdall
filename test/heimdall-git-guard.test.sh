#!/usr/bin/env bash
# heimdall-git-guard.test.sh — the stale-index.lock self-healer clears an OWNERLESS lock but
# NEVER one a live git op holds, and is a no-op when there's no lock. This is the durable fix
# for the recurring "Unable to create '.git/index.lock'" at ship time (interrupted writers).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$ROOT/bin/heimdall-git-guard"
P=0; F=0
ok()  { P=$((P+1)); echo "  ok   $1"; }
bad() { F=$((F+1)); echo "  FAIL $1"; }
[ -x "$GUARD" ] || { echo "FATAL: $GUARD not executable"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
git -C "$WORK" config user.email t@t.t; git -C "$WORK" config user.name t
echo x > "$WORK/a"; git -C "$WORK" add a; git -C "$WORK" commit -qm init

# 1. no lock → no-op, exit 0
"$GUARD" "$WORK"; [ $? -eq 0 ] && [ ! -f "$WORK/.git/index.lock" ] && ok "no lock → no-op exit 0" || bad "no-lock case wrong"

# 2. ownerless stale lock → cleared (no git process holds it)
: > "$WORK/.git/index.lock"
"$GUARD" "$WORK" 2>/dev/null
[ ! -f "$WORK/.git/index.lock" ] && ok "ownerless stale lock cleared" || bad "stale lock NOT cleared"

# 3. LIVE git op present → guard must NOT remove the lock (conservative wait/preserve). The
#    ownership check is injectable via HMD_GIT_GUARD_PGREP so this is deterministic (a copied
#    `git`-named binary can't run on a code-signed OS). Force "a git proc is always alive":
#    the guard must exhaust its wait budget and leave the lock intact.
: > "$WORK/.git/index.lock"
HMD_GIT_GUARD_PGREP="true" "$GUARD" "$WORK" 2>/dev/null
[ -f "$WORK/.git/index.lock" ] && ok "lock preserved while a git process is alive (never clears a live lock)" \
  || bad "guard cleared a lock while git was alive (unsafe)"

# 4. Once no git process owns it (forced "none alive") → the stale lock is cleared.
HMD_GIT_GUARD_PGREP="false" "$GUARD" "$WORK" 2>/dev/null
[ ! -f "$WORK/.git/index.lock" ] && ok "lock cleared once no git process owns it" || bad "ownerless lock not cleared"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
