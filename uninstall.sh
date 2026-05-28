#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "ERROR: uninstall.sh must run as root." >&2
  exit 1
fi

systemctl disable --now proxmox-stack-maintainer.timer 2>/dev/null || true
rm -f /etc/systemd/system/proxmox-stack-maintainer.timer
rm -f /etc/systemd/system/proxmox-stack-maintainer.service
systemctl daemon-reload 2>/dev/null || true
rm -f /usr/local/bin/proxmox-stack-maintainer.sh

echo "Removed Proxmox Stack Maintainer systemd timer/service and binary."
echo "Preserved config/log/state directories:"
echo "  /etc/proxmox-stack-maintainer"
echo "  /var/log/proxmox-stack-maintainer"
echo "  /var/lib/proxmox-stack-maintainer"
