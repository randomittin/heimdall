#!/usr/bin/env bash
# dream-data.sh — the SHELL TWIN of bin/lib/dream_data.py.
#
# WHY A TWIN AND NOT A SHELL-OUT.
#   Four of dream's binaries are bash (runner, notice, permission, schedule) and three
#   are python (dream, self-improve, metric). Both halves must resolve the SAME state
#   directory or the loop reads one corpus and writes another. Shelling out to python
#   from bash would guarantee agreement, but heimdall-dream-notice runs on EVERY
#   SessionStart and its entire budget is "a few file reads" — paying an interpreter
#   start-up there to compute a path is the wrong trade. So the derivation is
#   reimplemented here in two cheap processes, and test/dream-data-root.test.sh asserts
#   byte-for-byte agreement between the two implementations. A duplicated algorithm is
#   only safe when a test pins the duplicates together; that test is the safety.
#
# THE KEY (identical to dream_data.repo_key):
#   <slug of basename>-<first 12 hex of sha256 of the repo's PHYSICAL path>
#   slug = lowercase, every run of non [a-z0-9] -> one '-', trimmed, capped at 24.
#
# ENV
#   HEIMDALL_HOME             state dir (default $HOME/.heimdall)
#   HEIMDALL_DREAM_DATA_DIR   explicit override; wins outright (the test seam)

# heimdall_dream_home — the state dir both halves agree on.
heimdall_dream_home() {
  printf '%s' "${HEIMDALL_HOME:-$HOME/.heimdall}"
}

# heimdall_dream_physical <path> — resolve symlinks the way python's realpath does, so a
# /tmp -> /private/tmp alias cannot fork one repo's evidence into two corpora. A path
# that cannot be entered is returned as given: it is the best answer available, and it
# keeps this total rather than letting a vanished checkout abort a caller.
heimdall_dream_physical() {
  local p="$1" resolved
  if resolved="$(cd "$p" 2>/dev/null && pwd -P)"; then
    printf '%s' "$resolved"
  else
    printf '%s' "$p"
  fi
}

# heimdall_dream_repo_key <repo>
heimdall_dream_repo_key() {
  local phys slug digest
  phys="$(heimdall_dream_physical "$1")"
  # printf '%s' — never echo. echo would append a newline and hash a DIFFERENT string
  # than python's .encode(), and the two halves would silently resolve different dirs.
  digest="$(printf '%s' "$phys" | shasum -a 256 2>/dev/null | cut -c1-12)"
  slug="$(printf '%s' "${phys##*/}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-*//; s/-*$//' \
    | cut -c1-24 \
    | sed 's/-*$//')"
  if [ -n "$slug" ]; then
    printf '%s-%s' "$slug" "$digest"
  else
    printf '%s' "$digest"
  fi
}

# heimdall_dream_data_root <repo>
heimdall_dream_data_root() {
  if [ -n "${HEIMDALL_DREAM_DATA_DIR:-}" ]; then
    printf '%s' "$HEIMDALL_DREAM_DATA_DIR"
    return 0
  fi
  printf '%s/data/%s' "$(heimdall_dream_home)" "$(heimdall_dream_repo_key "$1")"
}

# heimdall_dream_planning_dir <repo> — dream's relocated state dir.
heimdall_dream_planning_dir() {
  printf '%s/planning' "$(heimdall_dream_data_root "$1")"
}

# heimdall_dream_report_dir <repo> — where the relocated morning reports land.
heimdall_dream_report_dir() {
  printf '%s/dream' "$(heimdall_dream_planning_dir "$1")"
}
