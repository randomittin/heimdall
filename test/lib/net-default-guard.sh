# net-default-guard.sh — the GLOBAL default-on egress guard for the presence test corpus.
#
# WHY THIS EXISTS. After the presence network-default flip (opt-in -> opt-OUT / auto-on), ANY
# UNDECIDED or connected presence call now resolves the baked-in HEIMDALL_DEFAULT_CP_URL — which
# in production is the REAL public control plane (https://heimdall-cp-public-...run.app). In the
# test corpus that must NEVER be reached: a hermetic test that forgot to pin a URL would silently
# beat/enroll/retire against prod. This guard pins the baked-in default at a DEAD, unroutable
# local port (9 = discard) so an un-pinned presence call fails-safe to a connection refusal
# instead of phoning prod home.
#
# HOW TO USE. Source this ONCE near the top of every test that can execute the real
# bin/heimdall-presence (or a wrapper / git hook that shells it) under undecided/connected
# consent. It is the lowest common env point: every child process the suite spawns inherits the
# export unless that invocation sets its OWN HEIMDALL_DEFAULT_CP_URL (a recording server) — the
# `:-` keeps such explicit per-invocation pins winning, so this never fights a suite that stands
# up its own localhost CP.
#
#   . "$REPO/test/lib/net-default-guard.sh"   # after REPO is defined
#
# NOTE: this pins only the ZERO-config baked-in DEFAULT. An explicit HEIMDALL_CP_URL / BASE_URL /
# --url / cp-endpoint.json still overrides it (as in production) — those are the suite's own
# deliberate wiring and are left untouched.
export HEIMDALL_DEFAULT_CP_URL="${HEIMDALL_DEFAULT_CP_URL:-http://127.0.0.1:9}"
