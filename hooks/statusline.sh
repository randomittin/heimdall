#!/usr/bin/env bash
# statusline.sh — Claude Code's registered `statusLine` entry point.
#
# KEEP THIS FILE AT THIS EXACT PATH. bin/heimdall-statusline-register hardcodes the
# substring "hooks/statusline.sh" as its idempotency marker inside every teammate's
# already-registered ~/.claude/settings.json — renaming or moving this file would
# silently break re-registration detection for everyone already wired up.
#
# All actual rendering now lives in ONE place — bin/heimdall-statusline — so Claude
# Code's live auto-invoked path and the CLI-agnostic manual path (`hmd status`, and
# Cursor CLI's own registered statusLine — see bin/heimdall-statusline-register-cursor)
# render byte-identical output from the same source, never two copies that can
# drift. test/heimdall-statusline-parity.test.sh locks this property. That includes
# the CTX_METER publisher (feat(ctx) 568c7b8) — it now lives in
# bin/heimdall-statusline too, not just the subagent-count block; losing either one
# silently on a future refactor is exactly what the parity suite's ctx-meter
# assertion exists to catch.
exec "$(cd "$(dirname "$0")" && pwd)/../bin/heimdall-statusline" "$@"
