#!/usr/bin/env bash
# Sends the simulator's demo scenarios to the real gateway and prints which pool answered.
set -uo pipefail
: "${FRONTEND:?Set FRONTEND to the gateway public IP or host name}"
B="http://$FRONTEND"
DESKTOP_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Edge/131.0"
IPHONE_UA="Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X)"

run() { # label, curl args...
  local label="$1"; shift
  local out
  out="$(curl -s -o /dev/null -D - --max-time 10 "$@")"
  local code pool loc
  code="$(printf '%s' "$out" | head -1 | awk '{print $2}')"
  pool="$(printf '%s' "$out" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-backend-pool"{print $2}')"
  loc="$(printf '%s' "$out" | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')"
  local target="$pool"
  if [ -z "$target" ] && [ -n "$loc" ]; then target="redirect -> $loc"; fi
  printf '%-22s HTTP %-4s %s\n' "$label" "${code:-ERR}" "$target"
}

run "Default"          -A "$DESKTOP_UA" "$B/app/home"
run "Tenant"           -A "$DESKTOP_UA" -H "X-Tenant-Id: customer-1024" "$B/app/dashboard"
run "Partner"          -H "X-Partner-Id: fabrikam" "$B/api/orders"
run "API v2"           -H "X-Api-Version: 2.0" "$B/api/orders/1001"
run "Encoded path"     -H "X-Api-Version: 2" "$B/api%2Forders"
run "Canary (:8080 90:10)" -A "$DESKTOP_UA" "http://$FRONTEND:8080/app/home"
run "Campaign"         -A "$DESKTOP_UA" "$B/landing?campaign=summer&utm=mail"
run "A/B variant A"    -A "$DESKTOP_UA" -H "X-Variant: A" "http://$FRONTEND:8100/"
run "A/B variant B"    -A "$DESKTOP_UA" -H "X-Variant: B" "http://$FRONTEND:8100/"
run "Mobile"           -A "$IPHONE_UA" "$B/app/home"
run "WAF block (UA)" -A "agw-block-demo" "$B/app/home"
echo
echo "Note: the canary splits all of port 8080 into pool-web 90% / pool-canary 10%. Check the ratio with FRONTEND=$FRONTEND:8080 ./canary-check.sh /app/home 100"
echo "      WAF block (UA) is the 403 from the User-Agent WAF rule (BlockDemoUA). Reproduce it with curl -A agw-block-demo"
echo "      A/B uses port 8100 (abMap). The output shows the process name: variant A is pool-A (pool-web on VM 1), variant B is pool-B (pool-canary on VM 2)."
