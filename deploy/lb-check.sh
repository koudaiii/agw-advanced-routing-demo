#!/usr/bin/env bash
# Sends N requests to one URI, CONCURRENCY at a time (each finished request starts the next one), and prints
# per pool (x-backend-pool header) the count, the share, and the average response time, then the total time.
# Least Connections only shows its effect while a slow server still holds earlier requests, so the requests
# must overlap; canary-check.sh sends one at a time and cannot show it (#83).
# Usage:
#   FRONTEND=<gateway IP>:8110 ./lb-check.sh /app/home 100 6   # Round Robin: about half each
#   FRONTEND=<gateway IP>:8120 ./lb-check.sh /app/home 100 6   # Round Robin with a slow server
#   FRONTEND=<gateway IP>:8130 ./lb-check.sh /app/home 100 6   # Least Connections: few on pool-slow
# Run one port at a time: 8120 and 8130 share the same two servers.
set -uo pipefail
: "${FRONTEND:?Set FRONTEND to the gateway public IP or host name, with the port}"
URI="${1:-/app/home}"
N="${2:-100}"
CONCURRENCY="${3:-6}"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Edge/131.0"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

one() { # prints "<pool> <seconds>" for one request
  local out pool secs
  out="$(curl -s -o /dev/null -D - -w 'time_total: %{time_total}\n' --max-time 10 -A "$UA" "http://$FRONTEND$URI")"
  pool="$(printf '%s' "$out" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-backend-pool"{print $2}')"
  secs="$(printf '%s' "$out" | awk -F': ' '$1=="time_total"{print $2}')"
  echo "${pool:-(no-pool-header)} ${secs:-0}"
}
export -f one
export FRONTEND URI UA

start="$(date +%s.%N 2>/dev/null || perl -MTime::HiRes=time -e 'printf "%.3f", time')"
seq 1 "$N" | xargs -P "$CONCURRENCY" -I{} bash -c one >> "$tmp"
end="$(date +%s.%N 2>/dev/null || perl -MTime::HiRes=time -e 'printf "%.3f", time')"

echo "URI: $URI  requests: $N  concurrency: $CONCURRENCY"
awk -v n="$N" '{ c[$1]++; s[$1] += $2 } END { for (p in c) printf "  %-24s %4d  (%5.1f%%)  avg %.1f s\n", p, c[p], c[p] * 100 / n, s[p] / c[p] }' "$tmp" | sort -k2 -rn
awk -v a="$start" -v b="$end" 'BEGIN { printf "total: %.1f s\n", b - a }'
