#!/usr/bin/env bash
# Deploys a demo of Azure Application Gateway Advanced Routing (preview):
#   - 1 Ubuntu VM running 6 backend "pools" (ports 8080-8085, see backend/pools.conf)
#   - Application Gateway WAF_v2 + WAF policy (custom rule blocks WAF_BLOCK_CIDR)
#   - Advanced routing map with the same 6 rules as the simulator app
# Usage:
#   DEMO_CLIENT_CIDR=<your public IP>/32 ./deploy.sh
# Requires: Azure CLI with the advanced-routing-map / advanced-routing-set commands, logged in (az login).
set -euo pipefail

LOCATION="${LOCATION:-japaneast}"
RG="${RG:-rg-agw-advrouting-demo}"
PREFIX="${PREFIX:-agwdemo}"
GW="${PREFIX}-agw"
VM="${PREFIX}-backend"
VNET="${PREFIX}-vnet"
WAF="${PREFIX}-waf"
MAP="advancedRoutingMap1"
: "${DEMO_CLIENT_CIDR:?Set DEMO_CLIENT_CIDR to the public IP you demo from, e.g. 203.0.113.25/32 (canary rule)}"
WAF_BLOCK_CIDR="${WAF_BLOCK_CIDR:-198.51.100.0/24}"
HERE="$(cd "$(dirname "$0")" && pwd)"
az_gw() { az network application-gateway "$@" -g "$RG" --gateway-name "$GW" --only-show-errors -o none; }

echo "== Resource group / network"
az group create -n "$RG" -l "$LOCATION" -o none
az network vnet create -g "$RG" -n "$VNET" --address-prefixes 10.20.0.0/16 \
  --subnet-name appgw --subnet-prefixes 10.20.0.0/24 -o none
az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n backend --address-prefixes 10.20.1.0/24 -o none

echo "== Backend VM (no inbound from the Internet; public IP is only for outbound package install)"
bash "$HERE/make-cloud-init.sh"
az vm create -g "$RG" -n "$VM" --image Ubuntu2404 --size Standard_B2s \
  --vnet-name "$VNET" --subnet backend --nsg-rule NONE \
  --admin-username azureuser --generate-ssh-keys \
  --custom-data "$HERE/cloud-init.yaml" -o none
VM_IP="$(az vm show -d -g "$RG" -n "$VM" --query privateIps -o tsv)"
echo "   backend VM private IP: $VM_IP"

echo "== WAF policy (custom rule runs before routing)"
az network application-gateway waf-policy create -g "$RG" -n "$WAF" -l "$LOCATION" -o none
az network application-gateway waf-policy policy-setting update -g "$RG" --policy-name "$WAF" \
  --state Enabled --mode Prevention -o none
az network application-gateway waf-policy custom-rule create -g "$RG" --policy-name "$WAF" \
  -n BlockDemoIp --priority 10 --rule-type MatchRule --action Block -o none
az network application-gateway waf-policy custom-rule match-condition add -g "$RG" --policy-name "$WAF" \
  -n BlockDemoIp --match-variables RemoteAddr --operator IPMatch --values "$WAF_BLOCK_CIDR" -o none

echo "== Application Gateway (WAF_v2) — this takes several minutes"
az network public-ip create -g "$RG" -n "${GW}-pip" --sku Standard --allocation-method Static -o none
az network application-gateway create -g "$RG" -n "$GW" -l "$LOCATION" \
  --sku WAF_v2 --capacity 1 --vnet-name "$VNET" --subnet appgw \
  --public-ip-address "${GW}-pip" --waf-policy "$WAF" \
  --frontend-port 80 --priority 100 \
  --servers "$VM_IP" --http-settings-port 8080 --http-settings-protocol Http -o none

echo "== Probe, pools and backend settings (one per pool / port)"
az_gw probe create -n healthz --protocol Http --host 127.0.0.1 --path /healthz
grep -v '^#' "$HERE/../backend/pools.conf" | while IFS='|' read -r name port _; do
  echo "   $name -> $VM_IP:$port"
  az_gw address-pool create -n "$name" --servers "$VM_IP"
  az_gw http-settings create -n "hs-$name" --port "$port" --protocol Http --probe healthz --timeout 20
done

echo "== Redirect target for the campaign rule"
az_gw redirect-config create -n redirect-campaign --type Found \
  --target-url "https://www.contoso.com/campaign" --include-path false --include-query-string true

echo "== Advanced routing condition sets (same as the simulator)"
cs() { az network application-gateway advanced-routing-set create -g "$RG" --gateway-name "$GW" \
         -n "$1" --routing-conditions "$2" --only-show-errors -o none; }
cs cs-partner  "[{condition-type:Header,property-name:X-Partner-Id,property-values:[contoso,fabrikam]}]"
cs cs-tenant   "[{condition-type:Header,property-name:X-Tenant-Id,property-value-matcher:{pattern:'^customer-[0-9]+\$'}},{condition-type:Path,property-value-matcher:{pattern:'^/app(/.*)?\$'}}]"
cs cs-apiv2    "[{condition-type:Header,property-name:X-Api-Version,property-values:['2','2.0']},{condition-type:Path,property-value-matcher:{pattern:'^/api/orders(/.*)?\$'}}]"
cs cs-canary   "[{condition-type:ClientIP,property-values:['$DEMO_CLIENT_CIDR']},{condition-type:Method,property-values:[GET,HEAD]}]"
cs cs-campaign "[{condition-type:QueryString,property-name:campaign,property-values:[spring,summer]}]"
cs cs-mobile   "[{condition-type:Header,property-name:User-Agent,property-value-matcher:{pattern:'(iPhone|Android)'}}]"

echo "== Advanced routing map + rules"
az network application-gateway advanced-routing-map create -g "$RG" --gateway-name "$GW" -n "$MAP" \
  --default-address-pool pool-web --default-http-settings hs-pool-web \
  --rule-name partner --priority 10 --condition-set cs-partner \
  --address-pool pool-partner --http-settings hs-pool-partner --only-show-errors -o none
rule() { az network application-gateway advanced-routing-map rule create -g "$RG" --gateway-name "$GW" \
           --map-name "$MAP" "$@" --only-show-errors -o none; }
rule -n tenant   --priority 20 --condition-set cs-tenant   --address-pool pool-tenant --http-settings hs-pool-tenant
rule -n api-v2   --priority 30 --condition-set cs-apiv2    --address-pool pool-api-v2 --http-settings hs-pool-api-v2
rule -n canary   --priority 40 --condition-set cs-canary   --address-pool pool-canary --http-settings hs-pool-canary
rule -n campaign --priority 50 --condition-set cs-campaign --redirect-config redirect-campaign
rule -n mobile   --priority 60 --condition-set cs-mobile   --address-pool pool-mobile --http-settings hs-pool-mobile

echo "== Switch the listener's rule (rule1, Basic) to AdvancedRouting"
if ! az_gw rule update -n rule1 --rule-type AdvancedRouting --advanced-routing-map "$MAP"; then
  echo "!! Could not switch rule1 with the CLI. In the portal: Rules > rule1 > Routing > Rule type = Advanced,"
  echo "!! then select the advanced routing map '$MAP'."
fi

FRONTEND_IP="$(az network public-ip show -g "$RG" -n "${GW}-pip" --query ipAddress -o tsv)"
echo
echo "Done. Frontend: http://$FRONTEND_IP/"
echo "Run: FRONTEND=$FRONTEND_IP ./test.sh"
