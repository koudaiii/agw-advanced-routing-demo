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
run "パートナー"       -H "X-Partner-Id: fabrikam" "$B/api/orders"
run "API v2"           -H "X-Api-Version: 2.0" "$B/api/orders/1001"
run "エンコード済み"   -H "X-Api-Version: 2" "$B/api%2Forders"
run "カナリア (:8080 90:10)" -A "$DESKTOP_UA" "http://$FRONTEND:8080/app/home"
run "キャンペーン"     -A "$DESKTOP_UA" "$B/landing?campaign=summer&utm=mail"
run "A/B 変種 A"      -A "$DESKTOP_UA" -H "X-Variant: A" "$B/ab"
run "A/B 変種 B"      -A "$DESKTOP_UA" -H "X-Variant: B" "$B/ab"
run "モバイル"         -A "$IPHONE_UA" "$B/app/home"
run "WAF ブロック (UA)" -A "agw-block-demo" "$B/app/home"
echo
echo "注: カナリアは ポート 8080 全体を pool-web 90% / pool-canary 10% で振り分けます。割合は FRONTEND=$FRONTEND:8080 ./canary-check.sh /app/home 100 で確認。"
echo "    WAF ブロック (UA) は User-Agent の WAF ルール (BlockDemoUA) による 403 です。curl -A agw-block-demo で確認できます。"
