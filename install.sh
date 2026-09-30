#!/usr/bin/env bash
# Installs the script + a systemd timer. Run as root: sudo ./install.sh /path/to/config.env
set -euo pipefail
CFG="${1:?usage: install.sh CONFIG_FILE}"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
command -v oci >/dev/null || { echo "OCI CLI not found (see README)"; exit 1; }
command -v jq  >/dev/null || { echo "jq not found"; exit 1; }
INTERVAL=$(awk -F= '/^INTERVAL_MINUTES=/{print $2}' "$CFG"); INTERVAL=${INTERVAL:-5}
install -d -m 700 /etc/oc-reserve
install -m 600 "$CFG" /etc/oc-reserve/config.env
install -m 755 "$(dirname "$0")/oc-reserve.sh" /usr/local/sbin/oc-reserve
cat > /etc/systemd/system/oc-reserve.service <<U
[Unit]
Description=Oracle Cloud instance reservation attempt
After=network-online.target
[Service]
Type=oneshot
ProtectHome=read-only
ExecStart=/usr/local/sbin/oc-reserve --config /etc/oc-reserve/config.env
U
cat > /etc/systemd/system/oc-reserve.timer <<U
[Unit]
Description=Run oc-reserve every ${INTERVAL} minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}min
AccuracySec=10s
[Install]
WantedBy=timers.target
U
systemctl daemon-reload
systemctl enable --now oc-reserve.timer
echo "installed; logs: /var/lib/oc-reserve/run.log  status: oc-reserve --status"
