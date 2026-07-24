#!/usr/bin/env bash
# heimdall-haid-stable-machine.test.sh
#
# REGRESSION (RJ screenshot: pinned "batsy" hero flipped to "wolf"):
#
# heimdall-haid derives  haid:{human}.{machine}-{hash4}  where machine = `hostname -s`
# and hash4 = sha(human,machine,repo). On macOS `hostname -s` reflects the NETWORK name,
# which on many DHCP networks is the box's own IP (`hostname` => 192.168.27.8 =>
# `hostname -s` => `192`). That makes machine=`192` AND changes hash4, silently re-minting
# the HAID from  haid:rj.rishabhs-macbook-air-46d5  (the batsy CUSTOM_SIGILS pin key)
# to  haid:rj.192-fd18 , which MISSES the pin and falls to the hash-derived hero (wolf).
#
# INVARIANT: the derived HAID must ride the STABLE device identity (macOS scutil
# LocalHostName / Linux hostnamectl --static), NOT the transient network hostname. So an
# IP-flipped `hostname -s` must NOT change the HAID — and a HAID pinned to a custom hero
# must keep resolving that hero (batsy), never a hash fallback.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HAID_BIN="$ROOT/bin/heimdall-haid"
SIG="$ROOT/sentinels/hmd_sigil.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -x "$HAID_BIN" ] || { echo "FATAL: heimdall-haid missing at $HAID_BIN"; exit 2; }
[ -f "$SIG" ]      || { echo "FATAL: hmd_sigil.py missing at $SIG"; exit 2; }

_p=0; _f=0
ok(){ _p=$((_p+1)); echo "  ok   $1"; }
bad(){ _f=$((_f+1)); echo "  FAIL $1"; }

STABLE_NAME="Rishabhs-MacBook-Air"   # what scutil LocalHostName returns (stable device id)
IP_HOST="192.168.27.8"               # what `hostname` returns on the IP-assigning network

# -- controllable stand-in `hostname` / `scutil` on PATH -----------------------
BINROOT="$(mktemp -d "${TMPDIR:-/tmp}/hmd-haid-XXXXXX")"
trap 'rm -rf "$BINROOT"' EXIT

# scutil always resolves the STABLE device name (present on every macOS box).
cat > "$BINROOT/scutil" <<EOF
#!/bin/sh
[ "\$1" = "--get" ] && [ "\$2" = "LocalHostName" ] && { printf '%s\n' "$STABLE_NAME"; exit 0; }
exit 1
EOF
chmod +x "$BINROOT/scutil"

# a `hostname` stub whose short form is controlled by \$HMD_TEST_HOST (bare = short name).
cat > "$BINROOT/hostname" <<'EOF'
#!/bin/sh
full="${HMD_TEST_HOST:?HMD_TEST_HOST unset}"
if [ "$1" = "-s" ]; then printf '%s\n' "${full%%.*}"; else printf '%s\n' "$full"; fi
EOF
chmod +x "$BINROOT/hostname"

derive() {  # $1 = full hostname the network reports -> prints derived HAID
    HMD_TEST_HOST="$1" PATH="$BINROOT:$PATH" "$HAID_BIN" current 2>/dev/null
}

HAID_IP="$(derive "$IP_HOST")"            # on the IP-assigning network
HAID_STABLE="$(derive "$STABLE_NAME")"    # on a network that reports the real name

echo "  ..  HAID (IP network)     = $HAID_IP"
echo "  ..  HAID (stable network) = $HAID_STABLE"

# A) machine part must NOT be a bare IP fragment (`192`) / purely numeric.
mach_ip="$(printf '%s' "$HAID_IP" | sed -E 's/^haid:[a-z0-9_-]+\.(.*)-[0-9a-f]{4}$/\1/')"
case "$mach_ip" in
  ''|*[!0-9.]*) ok "machine part is a stable device name, not an IP fragment (got '$mach_ip')" ;;
  *)            bad "machine part is a transient IP fragment: '$mach_ip' (HAID rides the network, not the device)" ;;
esac

# B) an IP-flipped `hostname` must NOT change the HAID (device identity is stable).
if [ -n "$HAID_IP" ] && [ "$HAID_IP" = "$HAID_STABLE" ]; then
  ok "HAID is invariant to an IP-flipped hostname ($HAID_IP)"
else
  bad "HAID flips with the network hostname: IP='$HAID_IP' vs stable='$HAID_STABLE'"
fi

# C/D) the sigil hero must not flip — and a pinned HAID keeps its custom hero (batsy).
SIG="$SIG" HAID_IP="$HAID_IP" HAID_STABLE="$HAID_STABLE" python3 - <<'PY'
import os, importlib.util, hashlib, sys
spec = importlib.util.spec_from_file_location("hmd_sigil", os.environ["SIG"])
S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
def heroname(seed):
    cs = S._resolve_custom_spec(seed)
    if cs: return cs.get("name")
    idx = hashlib.sha256(seed.encode()).digest()[0] % len(S.ANIMAL_ORDER)
    return "ANIMAL:" + S.ANIMAL_ORDER[idx]
ip, stable = os.environ["HAID_IP"], os.environ["HAID_STABLE"]
h_ip, h_st = heroname(ip), heroname(stable)
p=[0]; f=[0]
def ok(m): p[0]+=1; print("  ok   "+m)
def bad(m): f[0]+=1; print("  FAIL "+m)
(ok if h_ip == h_st else bad)(f"sigil hero does NOT flip with the network: IP={h_ip!r} stable={h_st!r}")
if stable in S.CUSTOM_SIGILS:
    want = S.CUSTOM_SIGILS[stable].get("name")
    (ok if h_ip == want else bad)(f"pinned HAID keeps its custom hero {want!r} under IP-hostname (got {h_ip!r})")
sys.exit(1 if f[0] else 0)
PY
[ $? -eq 0 ] && ok "sigil-hero invariance (python subcheck)" || bad "sigil-hero flipped under IP-hostname"

echo
echo "$_p passed, $_f failed"
[ "$_f" -eq 0 ] || exit 1
