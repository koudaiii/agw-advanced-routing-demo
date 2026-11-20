#!/usr/bin/env bash
# Deploys a demo of Azure Application Gateway Advanced Routing (preview) via deploy/main.bicep:
#   - VM 1 (Ubuntu) running 5 backend pools (ports 8080-8083, 8085; backend/pools.conf)
#     and VM 2 running pool-canary (port 8080; backend/pools-canary.conf)
#   - Application Gateway WAF_v2 + WAF policy (custom rule blocks WAF_BLOCK_CIDR)
#   - Advanced routing condition sets / map / rules (same 5 advanced rules as the simulator app)
# Usage:
#   ./deploy.sh
# Requires: az login (the target subscription must be the active one), Bicep (bundled with az).
set -euo pipefail

LOCATION="${LOCATION:-japaneast}"
RG="${RG:-rg-agw-advrouting-demo}"
PREFIX="${PREFIX:-agwdemo}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
WAF_BLOCK_CIDR="${WAF_BLOCK_CIDR:-198.51.100.0/24}"
# true = weighted 90:10 split on port 8080 (needs the AllowApplicationGatewayLoadDistributionPolicy feature). false = all port-8080 traffic to pool-canary.
WEIGHTED_CANARY="${WEIGHTED_CANARY:-false}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$SSH_KEY_FILE" ]; then
  echo "== No SSH public key at $SSH_KEY_FILE; generating one (used only for azureuser on the backend VM)"
  ssh-keygen -t ed25519 -N '' -f "${SSH_KEY_FILE%.pub}" >/dev/null
fi

echo "== cloud-init.yaml (backend VM bootstrap, embeds backend/server.js)"
bash "$HERE/make-cloud-init.sh"
bash "$HERE/make-cloud-init.sh" "$HERE/../backend/pools-canary.conf" "$HERE/cloud-init-canary.yaml"

echo "== Resource group"
az group create -n "$RG" -l "$LOCATION" -o none

echo "== Deploying main.bicep (Application Gateway provisioning takes several minutes)"
FRONTEND_IP="$(az deployment group create -g "$RG" -n "agw-advrouting-$(date +%Y%m%d%H%M%S)" \
  -f "$HERE/main.bicep" \
  --parameters location="$LOCATION" prefix="$PREFIX" \
               wafBlockCidr="$WAF_BLOCK_CIDR" weightedCanary="$WEIGHTED_CANARY" sshPublicKey="$(cat "$SSH_KEY_FILE")" \
  --query properties.outputs.frontendIp.value -o tsv)"

echo
echo "Done. Frontend: http://$FRONTEND_IP/"
echo "Run: FRONTEND=$FRONTEND_IP $HERE/test.sh"
