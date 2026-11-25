#!/usr/bin/env bash
# Generates a cloud-init file that installs Node.js and runs one systemd service per pool line.
# Usage: make-cloud-init.sh [pools.conf] [output.yaml]
#   default: backend/pools.conf -> deploy/cloud-init.yaml (backend VM)
#   canary VM: backend/pools-canary.conf -> deploy/cloud-init-canary.yaml
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="${1:-$HERE/../backend/pools.conf}"
OUT="${2:-$HERE/cloud-init.yaml}"
SERVER_B64="$(base64 < "$HERE/../backend/server.js" | tr -d '\n')"
{
  echo "#cloud-config"
  echo "package_update: true"
  echo "packages: [nodejs]"
  echo "write_files:"
  echo "  - path: /opt/agw-demo/server.js"
  echo "    encoding: b64"
  echo "    content: $SERVER_B64"
  echo "  - path: /etc/systemd/system/agw-pool@.service"
  echo "    content: |"
  echo "      [Unit]"
  echo "      Description=AGW demo backend %i"
  echo "      After=network-online.target"
  echo "      [Service]"
  echo "      EnvironmentFile=/etc/agw-demo/%i.env"
  echo "      ExecStart=/usr/bin/node /opt/agw-demo/server.js"
  echo "      Restart=always"
  echo "      DynamicUser=yes"
  echo "      [Install]"
  echo "      WantedBy=multi-user.target"
  grep -v '^#' "$CONF" | while IFS='|' read -r name port label color delay; do
    echo "  - path: /etc/agw-demo/$name.env"
    echo "    content: |"
    echo "      POOL_NAME=$name"
    echo "      PORT=$port"
    echo "      POOL_LABEL=\"$label\""
    echo "      POOL_COLOR=\"$color\""
    echo "      DELAY_MS=${delay:-0}"
  done
  echo "runcmd:"
  echo "  - systemctl daemon-reload"
  grep -v '^#' "$CONF" | while IFS='|' read -r name _; do
    echo "  - systemctl enable --now agw-pool@$name"
  done
} > "$OUT"
echo "wrote $OUT"
