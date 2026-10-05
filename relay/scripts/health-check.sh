#!/usr/bin/env bash
# health-check.sh -- poll a relay's GET /health until it answers healthy, or give up.
#
#   bash scripts/health-check.sh <base-url> [expected-version]
#
# Healthy is HTTP 200 with a JSON body {"ok":true,"version":"<v>"} (src/health.ts). Given
# <expected-version>, <v> must equal it: that is what makes this a check of the build just shipped
# rather than of whatever was already answering, and why relay-deploy.yml passes the commit sha it
# injected as BUILD_ID. Without one any healthy answer passes, which is what the post-rollback check
# uses: the version it should then see is whatever was live before the deploy.
#
# It retries because a deploy takes a few seconds to reach every edge, so the first answers can
# still come from the previous build, or fail outright.
#
# Exit: 0 healthy | 1 never healthy within the attempts | 2 usage error or a missing tool.
# Env:  HEALTH_ATTEMPTS   attempts before giving up                    (default 24)
#       HEALTH_DELAY_S    seconds to wait between attempts             (default 5)
#
# Output is attempt numbers, reasons and the one version it checked, never a response body. /health
# carries nothing secret by design, but whatever answers is not necessarily the relay, and a line
# beginning `::` in a GitHub Actions log is a workflow command: so a version is only echoed once it
# matches a conservative character set, and anything else is reported as not-a-health-body.
set -uo pipefail

die() { echo "health-check: $*" >&2; exit 2; }

base="${1:-}"
expected="${2:-}"
attempts="${HEALTH_ATTEMPTS:-24}"
delay="${HEALTH_DELAY_S:-5}"

[ -n "$base" ] || die "usage: health-check.sh <base-url> [expected-version]"
[[ "$base" =~ ^https?://[^[:space:]]+$ ]] || die "base url must be http(s)://..., got: $base"
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || die "HEALTH_ATTEMPTS must be a positive integer, got: $attempts"
[[ "$delay" =~ ^[0-9]+$ ]] || die "HEALTH_DELAY_S must be a non-negative integer, got: $delay"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

url="${base%/}/health"
reason=""

# The version is printed only if the whole answer is {"ok":true,"version":<safe string>}.
health_version='if .ok == true and (.version | type) == "string" and (.version | test("^[A-Za-z0-9._+-]{1,128}$")) then .version else empty end'

for ((attempt = 1; attempt <= attempts; attempt++)); do
  # -f: an HTTP error status is a failure. -sS: silent, except for the error itself, which names the
  # status, DNS, TLS or timeout cause and lands in the log (the body of an error is never printed).
  if body="$(curl -fsS --max-time 10 "$url")"; then
    if version="$(jq -er "$health_version" <<<"$body" 2>/dev/null)"; then
      if [ -z "$expected" ] || [ "$version" = "$expected" ]; then
        echo "healthy: $url reports version $version (attempt $attempt/$attempts)"
        exit 0
      fi
      reason="serving version $version, want $expected"
    else
      reason="200 but not a {\"ok\":true,\"version\":\"...\"} health body"
    fi
  else
    reason="request failed"
  fi
  echo "attempt $attempt/$attempts: $reason" >&2
  if ((attempt < attempts)); then sleep "$delay"; fi
done

echo "unhealthy: $url never reported healthy${expected:+ at version $expected} in $attempts attempts (last: $reason)" >&2
exit 1
