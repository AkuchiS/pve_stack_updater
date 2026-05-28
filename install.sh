#!/usr/bin/env bash
set -euo pipefail

APP="proxmox-stack-maintainer"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$ROOT_DIR/proxmox-stack-maintainer.sh"
BIN_DEST="/usr/local/bin/proxmox-stack-maintainer.sh"
CONFIG_DIR="/etc/proxmox-stack-maintainer"
CONFIG_DEST="$CONFIG_DIR/config.env"
LOG_DIR="/var/log/proxmox-stack-maintainer"
STATE_DIR="/var/lib/proxmox-stack-maintainer"
SERVICE_SRC="$ROOT_DIR/systemd/proxmox-stack-maintainer.service"
TIMER_SRC="$ROOT_DIR/systemd/proxmox-stack-maintainer.timer"
SERVICE_DEST="/etc/systemd/system/proxmox-stack-maintainer.service"
TIMER_DEST="/etc/systemd/system/proxmox-stack-maintainer.timer"
ENABLE_TIMER=1
RUN_CHECK=1

usage() {
  cat <<'EOF'
Install Proxmox Stack Maintainer as a systemd timer.

Usage:
  sudo ./install.sh [--no-enable] [--no-check]

Options:
  --no-enable   Install files but do not enable/start the systemd timer.
  --no-check    Skip post-install runtime check.
  -h, --help    Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-enable) ENABLE_TIMER=0 ;;
    --no-check) RUN_CHECK=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "ERROR: install.sh must run as root on the Proxmox host." >&2
  exit 1
fi

if [ ! -f "$BIN_SRC" ]; then
  echo "ERROR: missing $BIN_SRC" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemd/systemctl is required for autonomous timer install." >&2
  exit 1
fi

install -d -m 0755 /usr/local/bin "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR" /etc/systemd/system
install -m 0755 "$BIN_SRC" "$BIN_DEST"

if [ -f "$ROOT_DIR/config/proxmox-stack-maintainer.env" ] && [ ! -f "$CONFIG_DEST" ]; then
  install -m 0644 "$ROOT_DIR/config/proxmox-stack-maintainer.env" "$CONFIG_DEST"
elif [ ! -f "$CONFIG_DEST" ]; then
  cat > "$CONFIG_DEST" <<'EOF'
# Proxmox Stack Maintainer configuration
SKIP_IDS="600"
LOG_RETENTION_DAYS="30"
SERVICE_CHECKS=(
  "Prismarr=http://10.12.0.30:7070"
)
EOF
fi

install -m 0644 "$SERVICE_SRC" "$SERVICE_DEST"
install -m 0644 "$TIMER_SRC" "$TIMER_DEST"
systemctl daemon-reload

if [ "$ENABLE_TIMER" -eq 1 ]; then
  systemctl enable --now proxmox-stack-maintainer.timer
fi

if [ "$RUN_CHECK" -eq 1 ]; then
  "$BIN_DEST" --check
fi

echo "Installed $APP"
echo "Binary: $BIN_DEST"
echo "Config: $CONFIG_DEST"
echo "Logs:   $LOG_DIR"
echo "State:  $STATE_DIR"
echo "Timer:  systemctl status proxmox-stack-maintainer.timer"
