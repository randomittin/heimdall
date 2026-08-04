#!/usr/bin/env bash
# module_preflight.sh — decide whether a module CAN install before trying, and
# name the fix for every precondition that fails.
#
# WHY THIS EXISTS. `uv tool install --python 3.13 "headroom-ai[all]==<pin>"` has
# roughly eight ways to fail and exactly one way to succeed, and seven of the
# eight surface as something that is not a diagnosis: a compiler traceback, a
# connect timeout, a "command not found" for a binary that IS installed but is
# not on PATH. A user cannot act on any of those. They can act on
#   "uv not found — run: curl -LsSf https://astral.sh/uv/install.sh | sh".
# So every check here answers two questions, never one: is the precondition met,
# and what exact command meets it.
#
# REQUIREMENTS ARE DATA, NOT CODE — the same rule the class contracts follow.
# Nothing here is hardcoded per module. The requirements are DERIVED from the
# manifest's own `installs_via.fetch` (the first token is the tool that must
# exist; `--python X.Y` is the interpreter that must be resolvable) and may be
# extended by an optional `preflight` object in the manifest. A module that
# declares nothing still gets a real preflight, because the install command it
# already ships is itself the specification.
#
# HONESTY OVER COVERAGE. A check that cannot run reports `skip` with the reason,
# never `pass`. We do not know how many megabytes an upstream wheel set needs
# unless the manifest says so, so an undeclared size is measured against a stated
# FLOOR and reported as OUR floor — not invented and presented as the module's
# requirement. Claiming a check that did not run is the one thing worse than not
# running it.
#
# NOTHING HERE HANGS. macOS ships no timeout(1), so every external command runs
# under a hard wall-clock alarm (perl's, with a portable watchdog fallback) and
# every network probe is additionally bounded by curl's own --max-time. A probe
# that outlives its budget is a FAILED probe, never an ignored one — a preflight
# that can hang is worse than no preflight, because it converts a fast, legible
# failure into a wedged terminal.
#
# ABSENCE IS NEVER AN ERROR. This library is sourced by `heimdall-modules` and by
# `heimdall-autoupdate`. Neither may break because a module cannot install: the
# module is optional, the tool is not. Every function here returns a status; none
# exits, and none writes to a path outside the state root it is handed.
#
# INTERFACE (source this file, then call):
#   hmd_preflight <name> <manifest> <state_root>
#       Runs every applicable check. Sets PF_RESULTS (a JSON array), PF_FAILED
#       (count of blocking failures) and PF_WARNED. Returns 0 iff nothing blocks.
#   hmd_preflight_render [<name>]
#       Human-readable report of PF_RESULTS on stdout.
#   hmd_preflight_remedies
#       Just the remedy commands for the blocking failures, one per line.
#
# MANIFEST KEYS THIS READS (all optional — derivation covers the common case):
#   preflight.disk_mb        megabytes the install needs; overrides the floor
#   preflight.index_url      package index to probe (default: derived from tool)
#   preflight.model_repo     HuggingFace repo whose availability to probe
#   preflight.port           local port the module binds; probed for a conflict
#   preflight.tools[]        {name, remedy} extra required tools
#   preflight.bin_dir        where the installer lands binaries (default ~/.local/bin)

# The disk floor. This is OURS, not a claim about any module, and it is stated
# as ours everywhere it is reported. 4 GB, because an upstream install that may
# fall back to a source build pays for it three times over: the wheel/sdist
# download, the compiler's scratch and target directories, and the unpacked
# result — and a Rust+ONNX extra set clears a gigabyte on its own. A floor that
# is merely "some space free" would greenlight exactly the install that dies
# half-way through a build, which is the most expensive failure in the list to
# clean up by hand.
#
# A module that knows its REAL size declares preflight.disk_mb and that wins;
# this only governs the case where nobody has measured it. Overridable so a test
# can pin both sides of the boundary.
HMD_PREFLIGHT_DISK_FLOOR_MB="${HMD_PREFLIGHT_DISK_FLOOR_MB:-4096}"

# Network probes are bounded twice: curl's --max-time AND the outer alarm.
HMD_PREFLIGHT_NET_TIMEOUT="${HMD_PREFLIGHT_NET_TIMEOUT:-15}"
# Local probes (command -v, df, a port connect) are fast or they are broken.
HMD_PREFLIGHT_LOCAL_TIMEOUT="${HMD_PREFLIGHT_LOCAL_TIMEOUT:-10}"

# Set to 1 to skip every network probe (air-gapped CI, and the test suite's
# default — a preflight test must not depend on the internet to be meaningful).
HMD_PREFLIGHT_NO_NET="${HMD_PREFLIGHT_NO_NET:-0}"

PF_RESULTS="[]"
PF_FAILED=0
PF_WARNED=0

# ── bounded execution ────────────────────────────────────────────────────────
# Sets PF_OUT / PF_RC. A command that exceeds its budget is killed and reported
# as failed with a reason, so a hung probe degrades to a legible failure.
PF_OUT=""
PF_RC=0
pf_bounded() {
  local secs="$1"; shift
  local cmd="$1"
  if command -v perl >/dev/null 2>&1; then
    PF_OUT="$(perl -e 'alarm shift @ARGV; exec @ARGV' -- "$secs" bash -c "$cmd" 2>&1)"
    PF_RC=$?
    # perl's alarm surfaces as SIGALRM: 142 (128+14) from the shell, 14 raw.
    if [ "$PF_RC" -eq 142 ] || [ "$PF_RC" -eq 14 ]; then
      PF_OUT="timed out after ${secs}s"
      PF_RC=124
    fi
    return 0
  fi
  # Portable fallback for a machine with no perl: run detached, shoot it on the
  # deadline. Same contract — no path can block forever.
  local tmp; tmp="$(mktemp 2>/dev/null)" || { PF_OUT="cannot create temp file"; PF_RC=125; return 0; }
  bash -c "$cmd" >"$tmp" 2>&1 &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watchdog=$!
  wait "$pid" 2>/dev/null; PF_RC=$?
  kill -9 "$watchdog" 2>/dev/null
  PF_OUT="$(cat "$tmp" 2>/dev/null)"
  rm -f "$tmp" 2>/dev/null
  # 137 = SIGKILL from the watchdog → the deadline fired.
  [ "$PF_RC" -eq 137 ] && { PF_OUT="timed out after ${secs}s"; PF_RC=124; }
  return 0
}

# ── result accumulation ──────────────────────────────────────────────────────
pf_reset() { PF_RESULTS="[]"; PF_FAILED=0; PF_WARNED=0; }

# pf_add <id> <status> <requirement> <found> <remedy>
# status: pass | fail | warn | skip. Only `fail` blocks.
pf_add() {
  local id="$1" status="$2" req="$3" found="$4" remedy="${5:-}"
  case "$status" in
    fail) PF_FAILED=$((PF_FAILED+1)) ;;
    warn) PF_WARNED=$((PF_WARNED+1)) ;;
  esac
  PF_RESULTS="$(jq -n --argjson acc "$PF_RESULTS" \
    --arg id "$id" --arg st "$status" --arg req "$req" \
    --arg found "$found" --arg rem "$remedy" \
    '$acc + [{id:$id, status:$st, requirement:$req, found:$found, remedy:$rem}]')"
}

# ── the known-remedy table ───────────────────────────────────────────────────
# Real installation commands for the tools a module manifest is likely to name.
# An unknown tool still gets an actionable line — "install <tool>" plus the
# repair command — rather than nothing.
pf_tool_remedy() {
  case "$1" in
    uv)     printf 'curl -LsSf https://astral.sh/uv/install.sh | sh' ;;
    uvx)    printf 'curl -LsSf https://astral.sh/uv/install.sh | sh' ;;
    pipx)   printf 'python3 -m pip install --user pipx && python3 -m pipx ensurepath' ;;
    pip|pip3) printf 'python3 -m ensurepip --upgrade' ;;
    cargo|rustc) printf 'curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh' ;;
    npm|node) printf 'install Node.js from https://nodejs.org (or: brew install node)' ;;
    git)    printf 'xcode-select --install   # macOS, or: apt-get install git' ;;
    *)      printf 'install `%s` and put it on PATH' "$1" ;;
  esac
}

# The package index a given installer tool reads. Used only when the manifest
# does not name one. These are the tools' real defaults, not guesses.
pf_tool_index() {
  case "$1" in
    uv|uvx|pip|pip3|pipx) printf 'https://pypi.org/simple/' ;;
    cargo)  printf 'https://crates.io/' ;;
    npm)    printf 'https://registry.npmjs.org/' ;;
    *)      printf '' ;;
  esac
}

# ── individual checks ────────────────────────────────────────────────────────

# The pin must be a complete 64-hex sha256 BEFORE any network work happens. A
# short, empty or non-hex pin means the artifact can never be proven to be the
# reviewed one, and installing something we cannot identify is exactly the
# "yanked/moved pin silently installs something else" failure. Fail here, loudly,
# while nothing has been fetched.
pf_check_pin() {
  local mf="$1"
  local pin; pin="$(jq -r '.pinned_version.artifact_sha256 // ""' "$mf" 2>/dev/null || echo "")"
  local ver; ver="$(jq -r '.pinned_version.version // ""' "$mf" 2>/dev/null || echo "")"
  if [ -z "$pin" ]; then
    pf_add pin fail "a 64-hex sha256 pin in the manifest" "no pinned_version.artifact_sha256" \
      "edit the manifest to record the artifact sha256 — an unpinned install cannot be verified"
    return 0
  fi
  case "$pin" in
    *[!0-9a-f]*) pf_add pin fail "pinned_version.artifact_sha256 lowercase hex" "non-hex characters" \
                   "fix the manifest pin — it must be 64 lowercase hex characters"; return 0 ;;
  esac
  if [ "${#pin}" -ne 64 ]; then
    pf_add pin fail "pinned_version.artifact_sha256 64 chars" "${#pin} chars" \
      "fix the manifest pin — it must be 64 lowercase hex characters"
    return 0
  fi
  pf_add pin pass "a complete 64-hex pin to verify the artifact against" \
    "version ${ver:-?}, sha256 ${pin%"${pin#????????}"}…" ""
}

# The installer tool itself. This is failure mode #1 and by far the most common:
# uv is not universal, and a machine with pip/pipx/brew-python has never heard of it.
pf_check_tool() {
  local tool="$1" name="$2"
  if [ -z "$tool" ]; then
    pf_add tool skip "an installer tool named by installs_via.fetch" "fetch command is empty" ""
    return 0
  fi
  if command -v "$tool" >/dev/null 2>&1; then
    local where; where="$(command -v "$tool" 2>/dev/null)"
    pf_add tool pass "\`$tool\` on PATH" "$where" ""
  else
    pf_add tool fail "\`$tool\` on PATH" "not found" \
      "$(pf_tool_remedy "$tool"), then: hmd modules repair $name"
  fi
}

# The interpreter the pin demands. uv CAN provision one, but that is a large
# download, so it is reported as a deliberate step with its exact command rather
# than performed as a surprise. Resolvable means: on PATH, or already provisioned
# inside uv's own python store.
pf_check_python() {
  local want="$1" name="$2" tool="$3"
  [ -n "$want" ] || { pf_add python skip "no interpreter pinned by the fetch command" "n/a" ""; return 0; }

  if command -v "python$want" >/dev/null 2>&1; then
    pf_add python pass "python $want available" "$(command -v "python$want")" ""
    return 0
  fi
  # uv keeps provisioned interpreters out of PATH; ask it directly.
  if [ "$tool" = "uv" ] && command -v uv >/dev/null 2>&1; then
    pf_bounded "$HMD_PREFLIGHT_LOCAL_TIMEOUT" "uv python list --only-installed 2>/dev/null"
    if [ "$PF_RC" -eq 0 ] && printf '%s' "$PF_OUT" | grep -q "cpython-${want}\."; then
      pf_add python pass "python $want available" "provisioned in uv's python store" ""
      return 0
    fi
  fi
  local how
  if [ "$tool" = "uv" ]; then how="uv python install $want"
  else how="install python $want and put it on PATH"; fi
  pf_add python fail "python $want available" "not found on PATH or in uv's store" \
    "$how   # a real download — run it deliberately, then: hmd modules repair $name"
}

# Free space at the install target. Rust + ONNX + weights is measured in GB and
# a disk that fills mid-build leaves a half-unpacked toolchain, which is the
# single most expensive failure in the list to clean up by hand.
pf_check_disk() {
  local target="$1" need="$2" source="$3"
  local probe="$target"
  # df needs a path that exists; walk up to the nearest ancestor that does.
  while [ -n "$probe" ] && [ ! -d "$probe" ] && [ "$probe" != "/" ]; do probe="$(dirname "$probe")"; done
  [ -d "$probe" ] || probe="/"
  pf_bounded "$HMD_PREFLIGHT_LOCAL_TIMEOUT" "df -Pm '$probe' 2>/dev/null | awk 'NR==2{print \$4}'"
  local free_mb; free_mb="$(printf '%s' "$PF_OUT" | tr -dc '0-9')"
  if [ -z "$free_mb" ]; then
    pf_add disk skip "free space at $probe" "df did not report a usable figure" ""
    return 0
  fi
  if [ "$free_mb" -lt "$need" ]; then
    pf_add disk fail "at least ${need} MB free at $probe ($source)" "${free_mb} MB free" \
      "free up $(( need - free_mb )) MB — e.g. \`hmd gc\`, empty Trash, or remove old caches"
  else
    pf_add disk pass "at least ${need} MB free at $probe ($source)" "${free_mb} MB free" ""
  fi
}

# PATH. `uv tool install` lands binaries in ~/.local/bin; if that is not on PATH
# the module installs perfectly and then reads as missing, which looks exactly
# like a broken install and is the most misleading state in the whole list.
#
# We DETECT and REPORT only. install.sh already owns PATH (ensure_path_on_profile),
# and a second mechanism writing to the same profile is how a shell rc ends up
# with duplicate exports — so the remedy points at the one owner, never at a
# second writer.
pf_check_path() {
  local bin_dir="$1"
  case ":${PATH:-}:" in
    *":$bin_dir:"*)
      pf_add path pass "$bin_dir on PATH" "present" ""
      return 0 ;;
  esac
  if [ ! -d "$bin_dir" ]; then
    pf_add path warn "$bin_dir on PATH" "directory does not exist yet (the installer creates it)" \
      "no action needed now — re-check after the module installs"
    return 0
  fi
  pf_add path fail "$bin_dir on PATH" "directory exists but is NOT on PATH" \
    "hmd --reinstall   # install.sh owns the PATH entry; it appends one guarded export"
}

# Reachability of the package index. A corporate proxy or firewall is not
# fixable from here, but it MUST be named: an unnamed block surfaces as a
# connect timeout minutes into an install, which reads as "the tool is broken".
pf_check_network() {
  local url="$1" name="$2"
  [ -n "$url" ] || { pf_add network skip "a package index to probe" "none derivable from the manifest" ""; return 0; }
  if [ "$HMD_PREFLIGHT_NO_NET" = "1" ]; then
    pf_add network skip "reachability of $url" "network probes disabled (HMD_PREFLIGHT_NO_NET=1)" ""
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    pf_add network fail "reachability of $url" "curl is not installed" \
      "install curl, then: hmd modules repair $name"
    return 0
  fi
  # Bounded twice: curl's own deadline, and the outer alarm as the backstop.
  pf_bounded "$(( HMD_PREFLIGHT_NET_TIMEOUT + 5 ))" \
    "curl -fsS --max-time $HMD_PREFLIGHT_NET_TIMEOUT -o /dev/null -w '%{http_code}' '$url' 2>&1"
  case "$PF_RC" in
    0)  pf_add network pass "reachability of $url" "HTTP ${PF_OUT}" "" ;;
    6)  pf_add network fail "reachability of $url" "DNS lookup failed" \
          "check your DNS/VPN — the package index host does not resolve here" ;;
    7)  pf_add network fail "reachability of $url" "connection refused or blocked" \
          "a firewall or proxy is blocking the package index. Set HTTPS_PROXY, or install the module on a permitted network. This is NOT fixable from hmd." ;;
    22) pf_add network fail "reachability of $url" "the index returned an HTTP error" \
          "the package index rejected the request (proxy auth, or the index is down)" ;;
    28|124) pf_add network fail "reachability of $url" "timed out after ${HMD_PREFLIGHT_NET_TIMEOUT}s" \
          "a proxy is likely swallowing the connection. Set HTTPS_PROXY, or install on a permitted network." ;;
    *)  pf_add network fail "reachability of $url" "curl exit $PF_RC" \
          "network probe failed — see \`curl -v $url\` for the detail" ;;
  esac
}

# The trained model the module fetches at first use. We probe REACHABILITY and
# deliberately do NOT prefetch — see hmd_preflight's header note on why lazy wins.
pf_check_model() {
  local repo="$1"
  [ -n "$repo" ] || { pf_add model skip "a model repo to probe" "manifest declares no preflight.model_repo" ""; return 0; }
  if [ "$HMD_PREFLIGHT_NO_NET" = "1" ]; then
    pf_add model skip "reachability of model $repo" "network probes disabled (HMD_PREFLIGHT_NO_NET=1)" ""
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { pf_add model skip "reachability of model $repo" "curl is not installed" ""; return 0; }
  pf_bounded "$(( HMD_PREFLIGHT_NET_TIMEOUT + 5 ))" \
    "curl -fsS --max-time $HMD_PREFLIGHT_NET_TIMEOUT -o /dev/null -w '%{http_code}' 'https://huggingface.co/api/models/$repo' 2>&1"
  case "$PF_RC" in
    0)  pf_add model pass "model $repo is reachable" "HTTP ${PF_OUT}" "" ;;
    22) pf_add model warn "model $repo is reachable anonymously" "the API returned an HTTP error (gated repo, or rate-limited)" \
          "if the repo is gated: export HF_TOKEN=<your token>. Weights download on FIRST USE, not now — hmd stays usable either way." ;;
    28|124) pf_add model warn "model $repo is reachable" "timed out after ${HMD_PREFLIGHT_NET_TIMEOUT}s" \
          "HuggingFace is slow or blocked from here. Weights download on first use; the module installs fine without this probe passing." ;;
    *)  pf_add model warn "model $repo is reachable" "probe failed (curl exit $PF_RC)" \
          "weights download on first use, not at install — this is advisory only" ;;
  esac
}

# Will there be a prebuilt wheel, or is this about to become a source build? A
# musl userland (Alpine) has no manylinux wheels, so `[all]` extras that pull
# Rust/ONNX fall back to compiling — which needs a toolchain the user does not
# know they need. A compiler traceback is not a diagnosis; this is.
pf_check_platform() {
  local os arch musl=0
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  [ -f /etc/alpine-release ] && musl=1
  if [ "$musl" -eq 0 ] && command -v ldd >/dev/null 2>&1; then
    pf_bounded "$HMD_PREFLIGHT_LOCAL_TIMEOUT" "ldd --version 2>&1 | head -1"
    printf '%s' "$PF_OUT" | grep -qi musl && musl=1
  fi
  if [ "$musl" -eq 1 ]; then
    if command -v cargo >/dev/null 2>&1; then
      pf_add platform warn "a prebuilt wheel for ${os}/${arch}" \
        "musl libc — PyPI ships no manylinux wheel, so this WILL build from source" \
        "a Rust toolchain is present, so the build can proceed. Expect several minutes and extra disk."
    else
      pf_add platform fail "a prebuilt wheel for ${os}/${arch}" \
        "musl libc and no Rust toolchain — the install would fall back to a source build and fail in the compiler" \
        "$(pf_tool_remedy cargo)   # then: hmd modules repair"
    fi
    return 0
  fi
  pf_add platform pass "a platform PyPI publishes wheels for" "${os}/${arch} (glibc/darwin)" ""
}

# A port the module binds. Occupied means the failure lands at WRAP time, long
# after install "succeeded" — so it is probed and recorded here, where it is
# still cheap to explain.
pf_check_port() {
  local port="$1"
  [ -n "$port" ] || { pf_add port skip "a local port to probe" "manifest declares no preflight.port" ""; return 0; }
  case "$port" in *[!0-9]*) pf_add port skip "a numeric preflight.port" "got \"$port\"" ""; return 0 ;; esac
  local busy=0
  if command -v lsof >/dev/null 2>&1; then
    pf_bounded "$HMD_PREFLIGHT_LOCAL_TIMEOUT" "lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null"
    [ -n "$PF_OUT" ] && busy=1
  elif command -v nc >/dev/null 2>&1; then
    pf_bounded "$HMD_PREFLIGHT_LOCAL_TIMEOUT" "nc -z 127.0.0.1 $port 2>/dev/null"
    [ "$PF_RC" -eq 0 ] && busy=1
  else
    pf_add port skip "port $port free" "no lsof or nc to probe with" ""
    return 0
  fi
  if [ "$busy" -eq 1 ]; then
    local who; who="$(printf '%s' "$PF_OUT" | awk 'NR==2{print $1" (pid "$2")"}')"
    pf_add port fail "port $port free for the module to bind" "in use by ${who:-another process}" \
      "stop the process on port $port, or set the module's port — otherwise this fails at wrap time, not install time"
  else
    pf_add port pass "port $port free for the module to bind" "free" ""
  fi
}

# ── derivation from the manifest ─────────────────────────────────────────────
# The fetch command IS the specification. `uv tool install --python 3.13 "x[all]==1.2"`
# yields tool=uv and python=3.13 with no manifest author having to restate either.
pf_derive_tool()   { printf '%s' "${1:-}" | awk '{print $1}'; }
pf_derive_python() {
  printf '%s' "${1:-}" \
    | sed -n -E 's/.*--python[= ]+v?([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1
}

# ── the orchestrator ─────────────────────────────────────────────────────────
# hmd_preflight <name> <manifest> <state_root>
# Returns 0 iff no check is blocking. Never exits; never mutates anything.
#
# PREFETCH-VS-LAZY, DECIDED: the trained model is fetched LAZILY, on first use,
# and only probed here. Prefetching hundreds of megabytes at install time buys a
# capability the user may never invoke, and the weights are versioned by the
# library rather than by our manifest pin — so a prefetch would cache an artifact
# we cannot pin and therefore cannot verify. Probing instead means a token or
# rate-limit problem is NAMED at diagnosis time, while the download itself
# happens where the user has the context for why it is happening.
hmd_preflight() {
  local name="$1" mf="$2" state="${3:-}"
  pf_reset

  if ! command -v jq >/dev/null 2>&1; then
    # Without jq we cannot even build a result set. Say so; do not pretend.
    PF_FAILED=1
    return 1
  fi
  if [ ! -f "$mf" ]; then
    pf_add manifest fail "a manifest for \"$name\" in the registry" "no manifest at $mf" \
      "hmd modules list   # to see what the registry actually offers"
    return 1
  fi

  local fetch kind tool pyver index model port need disk_src bin_dir
  kind="$(jq -r '.installs_via.kind // ""' "$mf")"
  fetch="$(jq -r '.installs_via.fetch // ""' "$mf")"
  tool="$(pf_derive_tool "$fetch")"
  pyver="$(pf_derive_python "$fetch")"
  index="$(jq -r '.preflight.index_url // ""' "$mf")"
  model="$(jq -r '.preflight.model_repo // ""' "$mf")"
  port="$(jq -r '.preflight.port // ""' "$mf")"
  bin_dir="$(jq -r '.preflight.bin_dir // ""' "$mf")"
  [ -n "$bin_dir" ] || bin_dir="$HOME/.local/bin"
  need="$(jq -r '.preflight.disk_mb // ""' "$mf")"
  if [ -n "$need" ] && [ -z "${need//[0-9]/}" ]; then
    disk_src="declared by the manifest"
  else
    need="$HMD_PREFLIGHT_DISK_FLOOR_MB"
    disk_src="hmd's floor; the manifest declares no preflight.disk_mb"
  fi
  [ -n "$index" ] || index="$(pf_tool_index "$tool")"

  # Cheapest and most decisive first, so a hard stop costs no network time.
  pf_check_pin "$mf"
  if [ "$kind" = "upstream" ]; then
    pf_check_tool "$tool" "$name"
    pf_check_python "$pyver" "$name" "$tool"
    pf_check_platform
  else
    pf_add tool skip "an installer tool" "installs_via.kind is \"$kind\" — the artifact ships with the manifest" ""
  fi
  pf_check_disk "${state:-$HOME}" "$need" "$disk_src"
  pf_check_path "$bin_dir"
  # Extra tools the manifest names beyond the one it derives from `fetch`.
  local extra
  while IFS= read -r extra; do
    [ -n "$extra" ] || continue
    if command -v "$extra" >/dev/null 2>&1; then
      pf_add "tool:$extra" pass "\`$extra\` on PATH" "$(command -v "$extra")" ""
    else
      local rem; rem="$(jq -r --arg t "$extra" '.preflight.tools[]? | select(.name==$t) | .remedy // ""' "$mf")"
      [ -n "$rem" ] || rem="$(pf_tool_remedy "$extra")"
      pf_add "tool:$extra" fail "\`$extra\` on PATH" "not found" "$rem, then: hmd modules repair $name"
    fi
  done <<< "$(jq -r '.preflight.tools[]?.name // empty' "$mf")"
  [ "$kind" = "upstream" ] && pf_check_network "$index" "$name"
  pf_check_model "$model"
  pf_check_port "$port"

  [ "$PF_FAILED" -eq 0 ]
}

# ── rendering ────────────────────────────────────────────────────────────────
hmd_preflight_render() {
  local name="${1:-}"
  printf '\n  Preflight%s\n\n' "${name:+ — $name}"
  # @tsv, because every field here contains spaces -- a space-split would
  # silently truncate each message to its first word, which is the kind of
  # "renders something, means nothing" bug a preflight can least afford.
  printf '%s' "$PF_RESULTS" \
    | jq -r '.[] | [.status, .id, .requirement, .found, .remedy] | @tsv' \
  | while IFS="$(printf '\t')" read -r st id req found rem; do
      case "$st" in
        pass) printf '    \033[32mPASS\033[0m %-12s %s\n' "$id" "$req" ;;
        fail) printf '    \033[31mFAIL\033[0m %-12s %s\n' "$id" "$req"
              printf '         \033[2mfound:\033[0m %s\n' "$found"
              [ -n "$rem" ] && printf '         \033[36mfix:\033[0m   %s\n' "$rem" ;;
        warn) printf '    \033[33mWARN\033[0m %-12s %s\n' "$id" "$req"
              printf '         \033[2mfound:\033[0m %s\n' "$found"
              [ -n "$rem" ] && printf '         \033[36mnote:\033[0m  %s\n' "$rem" ;;
        skip) printf '    \033[2mSKIP\033[0m %-12s %s — %s\n' "$id" "$req" "$found" ;;
      esac
    done
  printf '\n'
  if [ "$PF_FAILED" -eq 0 ]; then
    printf '  %s blocking failure(s). Preflight is GREEN.\n\n' "$PF_FAILED"
  else
    printf '  \033[31m%s blocking failure(s).\033[0m Fix the lines marked FAIL, then re-run.\n\n' "$PF_FAILED"
  fi
}

# Just the remedies for blocking failures — what `repair` echoes and what a
# caller pipes somewhere useful.
hmd_preflight_remedies() {
  printf '%s' "$PF_RESULTS" | jq -r '.[] | select(.status=="fail") | select(.remedy != "") | .remedy'
}
