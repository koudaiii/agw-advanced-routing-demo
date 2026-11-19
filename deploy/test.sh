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
  printf '%-16s HTTP %-4s %s\n' "$label" "${code:-ERR}" "$target"
}

run "通常アクセス"     -A "$DESKTOP_UA" "$B/app/home"
run "テナント"         -A "$DESKTOP_UA" -H "X-Tenant-Id: customer-1024" "$B/app/dashboard"
run "パートナー"       -X POST -H "X-Partner-Id: fabrikam" "$B/api/orders"
run "API v2"           -H "X-Api-Version: 2.0" "$B/api/orders/1001"
run "エンコード済み"   -H "X-Api-Version: 2" "$B/api%2Forders"
run "社内 IP(GET)"     -A "$DESKTOP_UA" "$B/app/home"
run "キャンペーン"     -A "$DESKTOP_UA" "$B/landing?campaign=summer&utm=mail"
run "モバイル"         -A "$IPHONE_UA" "$B/app/home"
echo
echo "注: '社内 IP' は DEMO_CLIENT_CIDR から送った場合のみ pool-canary になります (そのため '通常アクセス' も canary になります)。"
echo "    WAF ブロックを見せるには: WAF のカスタム ルールに自分の IP を追加し、もう一度実行します。"
