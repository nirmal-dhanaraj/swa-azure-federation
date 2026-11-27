#!/bin/bash
# azure/install-autostart.sh - Optional: start the lab automatically after the VM boots (e.g. after Azure auto-shutdown /
#   deallocate + start). Installs systemd unit swa-lab.service that runs 51-lab-start.sh as the lab user after docker.
#   The k3s container already has --restart=unless-stopped; this also brings back the swa-servers and the wl-<env> containers.
# Usage:  sudo ./azure/install-autostart.sh          remove: sudo ./azure/install-autostart.sh --remove
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }
UNIT=/etc/systemd/system/swa-lab.service
if [ "${1:-}" = --remove ]; then
  systemctl disable --now swa-lab.service 2>/dev/null || true; rm -f "$UNIT"; systemctl daemon-reload; echo "removed"; exit 0
fi
DIR=$(cd "$(dirname "$0")/.." && pwd)
LAB_USER=${SUDO_USER:?run via sudo from the lab user}
[ -f "$DIR/config.env" ] || { echo "config.env missing in $DIR" >&2; exit 1; }
cat > "$UNIT" <<EOF
[Unit]
Description=CyberArk SWA k3s lab (k3s, swa-server prod/dev, workload containers)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$LAB_USER
WorkingDirectory=$DIR
ExecStart=$DIR/51-lab-start.sh
ExecStop=$DIR/52-lab-stop.sh
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable swa-lab.service >/dev/null
echo "installed $UNIT (user $LAB_USER, dir $DIR). Starts at next boot; now: sudo systemctl start swa-lab; logs: journalctl -u swa-lab"
