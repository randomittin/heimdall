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
#
# NOT IMPLEMENTED YET.

echo "summarize.sh: not implemented yet" >&2
exit 1
