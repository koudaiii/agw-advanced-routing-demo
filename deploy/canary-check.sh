#!/usr/bin/env bash
# Sends N consecutive requests to one URI and counts which server answered (x-backend-srv header).
# The canary split is port-wide on port 8080 (srv-web 90 : srv-canary 10), so pass FRONTEND with the port.
# Usage:
#   FRONTEND=<gateway IP>:8080 ./canary-check.sh /app/home 100   # expect about 90 srv-web / 10 srv-canary
#   FRONTEND=<gateway IP>      ./canary-check.sh /app/home 100   # port 80: advanced rules, no canary split
set -uo pipefail
: "${FRONTEND:?Set FRONTEND to the gateway public IP or host name}"
URI="${1:-/app/home}"
N="${2:-100}"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Edge/131.0"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for _ in $(seq 1 "$N"); do
  pool="$(curl -s -o /dev/null -D - --max-time 10 -A "$UA" "http://$FRONTEND$URI" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-backend-srv"{print $2}')"
  echo "${pool:-(no srv header)}" >> "$tmp"
done

echo "URI: $URI  requests: $N"
sort "$tmp" | uniq -c | sort -rn | awk -v n="$N" '{ printf "  %-24s %4d  (%5.1f%%)\n", $2, $1, $1 * 100 / n }'
