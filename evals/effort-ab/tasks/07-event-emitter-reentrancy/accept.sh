#!/usr/bin/env bash
# Hidden acceptance for 07-event-emitter-reentrancy. cwd = the agent's workdir.
set -u
: "${ACCEPT_DIR:?ACCEPT_DIR must be the absolute path of the task directory}"

[ -f emitter.js ] || { echo "FAIL: emitter.js missing in $PWD" >&2; exit 1; }

# The task forbids delegating to node's built-in events module.
if grep -Eq "require\(\s*['\"](node:)?events['\"]\s*\)|from\s+['\"](node:)?events['\"]|import\(\s*['\"](node:)?events['\"]" emitter.js; then
  echo "FAIL: emitter.js must not use node's built-in events module" >&2
  exit 1
fi

# 8 s hard cap so a hung solution cannot stall the runner (perl alarm survives exec).
limited() {
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' 8 "$@"
  else
    "$@"
  fi
}

limited node "$ACCEPT_DIR/hidden_test.cjs"
