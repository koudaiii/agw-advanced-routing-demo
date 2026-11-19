#!/usr/bin/env bash
# Generates cloud-init.yaml that installs Node.js and runs one systemd service per pool.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER_B64="$(base64 -w0 "$HERE/../backend/server.js")"
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
  grep -v '^#' "$HERE/../backend/pools.conf" | while IFS='|' read -r name port label color; do
    echo "  - path: /etc/agw-demo/$name.env"
    echo "    content: |"
    echo "      POOL_NAME=$name"
    echo "      PORT=$port"
    echo "      POOL_LABEL=\"$label\""
    echo "      POOL_COLOR=\"$color\""
  done
  echo "runcmd:"
  echo "  - systemctl daemon-reload"
  grep -v '^#' "$HERE/../backend/pools.conf" | while IFS='|' read -r name _; do
    echo "  - systemctl enable --now agw-pool@$name"
  done
} > "$HERE/cloud-init.yaml"
echo "wrote $HERE/cloud-init.yaml"
