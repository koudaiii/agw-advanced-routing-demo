#!/usr/bin/env bash
# Generates a cloud-init file that installs Node.js and runs one systemd service per server line.
# Usage: make-cloud-init.sh [pools.conf] [output.yaml]
#   default: backend/pools.conf -> deploy/cloud-init.yaml (backend VM)
#   canary VM: backend/pools-canary.conf -> deploy/cloud-init-canary.yaml
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="${1:-$HERE/../backend/pools.conf}"
OUT="${2:-$HERE/cloud-init.yaml}"
SERVER_B64="$(base64 < "$HERE/../backend/server.js" | tr -d '\n')"
# Node.js comes from the NodeSource apt repository (current LTS line), not from Ubuntu (Node.js 18, end of life).
# The signing key is kept in the repo, not downloaded at boot. Fingerprint:
#   6F71 F525 2828 41EE DAF8  51B4 2F59 B5F9 9B1B E0B4  NSolid <nsolid-gpg@nodesource.com>
NODE_MAJOR=26
KEY_FILE="$HERE/nodesource-repo.gpg.key"
{
  echo "#cloud-config"
  echo "package_update: true"
  echo "apt:"
  echo "  sources:"
  echo "    nodesource:"
  echo "      source: \"deb [signed-by=\$KEY_FILE] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main\""
  echo "      key: |"
  sed 's/^./        &/' "$KEY_FILE"
  echo "packages: [nodejs]"
  echo "write_files:"
  # Never install Ubuntu's nodejs: if NodeSource is unreachable, the install fails instead of falling back to 18.
  echo "  - path: /etc/apt/preferences.d/nodejs"
  echo "    content: |"
  echo "      Package: nodejs"
  echo "      Pin: release o=Ubuntu"
  echo "      Pin-Priority: -1"
  echo "  - path: /opt/agw-demo/server.js"
  echo "    encoding: b64"
  echo "    content: $SERVER_B64"
  echo "  - path: /etc/systemd/system/agw-srv@.service"
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
    echo "      SERVER_NAME=$name"
    echo "      PORT=$port"
    echo "      SERVER_LABEL=\"$label\""
    echo "      SERVER_COLOR=\"$color\""
    echo "      DELAY_MS=${delay:-0}"
  done
  echo "runcmd:"
  echo "  - systemctl daemon-reload"
  grep -v '^#' "$CONF" | while IFS='|' read -r name _; do
    echo "  - systemctl enable --now agw-srv@$name"
  done
} > "$OUT"
echo "wrote $OUT"
