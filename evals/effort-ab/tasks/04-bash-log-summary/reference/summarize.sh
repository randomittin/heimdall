#!/usr/bin/env bash
# summarize.sh -- top client IPs in a web server access log.
#
# Usage: bash summarize.sh <logfile> [N]
#
# Reads an Apache/nginx common (or combined) log format file, one request per
# line, e.g.
#   203.0.113.7 - - [10/Oct/2023:13:55:36 +0000] "GET /index.html HTTP/1.1" 200 2326
#
# Prints the top N (default 3) client IPs by number of successful (2xx/3xx)
# requests, one per line as "<count> <ip>", highest count first, ties broken by
# ip in plain string order.  See the task description for the full rules.
set -u
export LC_ALL=C

logfile="${1:-}"
top="${2:-3}"

if [ ! -f "$logfile" ]; then
  echo "error: no such file: $logfile" >&2
  exit 2
fi

# Splitting on '"' makes $1 the part before the request and $3 the part after it,
# so a request that contains spaces cannot shift the status field.
awk -F'"' '
  NF >= 3 && $1 ~ /^[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]? / {
    ip = substr($1, 1, index($1, " ") - 1)
    split($3, after, " ")
    if (after[1] ~ /^[23][0-9][0-9]$/) {
      count[ip]++
    }
  }
  END {
    for (ip in count) print count[ip], ip
  }
' < "$logfile" | sort -k1,1nr -k2,2 | head -n "$top"
