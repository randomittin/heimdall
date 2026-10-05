#!/usr/bin/env bash
#
# runhmd-fixtures.sh — shared fixtures for the two wrapper suites
# (test/runhmd-wrapper.test.sh, test/runhmd-parity.test.sh). SOURCED, never executed: it
# defines functions and touches nothing on source.
#
# Both suites need the same two stand-ins, so they live here once:
#
#   a stand-in `hmd`     reports the version stored beside it (.hmd-version), logs its argv to
#                        $STUB_HMD_LOG, prints a marker line, exits $STUB_HMD_EXIT (default 0).
#   a stand-in install.sh   proves it ran ($STUB_INSTALL_MARK: "ran" + the argc it was given),
#                        then installs the stand-in hmd under $HOME/.local/bin the way the real
#                        installer lays it out. $STUB_INSTALL_MODE steers it:
#                          ok      (default) install hmd reporting $STUB_INSTALL_VERSION (999.0.0)
#                          fail    exit 7 without installing anything
#                          no-hmd  exit 0 without installing anything
#                          stale   exit 0 and leave an hmd that still reports 0.0.1
#
# Nothing here ever runs a real hmd or a real installer.

# rf_sha256 <file> — bare hex sha256 of a file
rf_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# rf_bend_digest <hex> — a well-formed digest that is guaranteed to differ in EVERY position
rf_bend_digest() {
  printf '%s' "$1" | tr '0123456789abcdef' '1234567890badcfe'
}

# rf_make_hmd_template <path>
rf_make_hmd_template() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
# stand-in hmd
here="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--version" ]; then
  printf 'Heimdall v%s\n' "$(cat "$here/.hmd-version" 2>/dev/null || echo '?')"
  exit 0
fi
{ printf 'ARGC=%s\n' "$#"; for a in "$@"; do printf 'ARG=%s\n' "$a"; done; } >> "${STUB_HMD_LOG:-/dev/null}"
printf 'hmd-stub-ran\n'
exit "${STUB_HMD_EXIT:-0}"
STUB
  chmod +x "$1"
}

# rf_make_installer <path>
rf_make_installer() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
# stand-in install.sh
{ printf 'ran\n'; printf '%s\n' "$#"; } > "${STUB_INSTALL_MARK:-/dev/null}"
mode="${STUB_INSTALL_MODE:-ok}"
[ "$mode" = "fail" ] && exit 7
mkdir -p "$HOME/.local/bin"
case "$mode" in
  no-hmd) exit 0 ;;
  stale)
    if [ ! -x "$HOME/.local/bin/hmd" ]; then
      cp "$STUB_HMD_TEMPLATE" "$HOME/.local/bin/hmd"
      printf '0.0.1\n' > "$HOME/.local/bin/.hmd-version"
    fi
    exit 0 ;;
esac
cp "$STUB_HMD_TEMPLATE" "$HOME/.local/bin/hmd"
chmod +x "$HOME/.local/bin/hmd"
printf '%s\n' "${STUB_INSTALL_VERSION:-999.0.0}" > "$HOME/.local/bin/.hmd-version"
exit 0
STUB
}
