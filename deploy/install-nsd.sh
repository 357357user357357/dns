#!/bin/bash
# Install and configure NSD as an authoritative server for ONE zone on this
# host. Idempotent — safe to re-run on every deploy.
# Usage: install-nsd.sh <zone-name>
#   The zone file must already exist at /tmp/<zone-name>.zone (deploy.ps1
#   transports it there via base64 over ssh).
set -euo pipefail

ZONE_NAME="${1:?usage: install-nsd.sh <zone-name>}"
HOST_IP=$(hostname -I | awk '{print $1}')
echo "host ip: ${HOST_IP}"

test -s "/tmp/${ZONE_NAME}.zone" || { echo "FATAL: /tmp/${ZONE_NAME}.zone missing"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nsd

mkdir -p /etc/nsd/zones

# Bind the public IP only: a wildcard 0.0.0.0:53 bind collides with
# systemd-resolved's loopback stub (127.0.0.53/54) on modern Debian/Ubuntu.
cat > /etc/nsd/nsd.conf <<EOF
server:
    ip-address: ${HOST_IP}
    hide-version: yes
    identity: ""
    database: ""
    zonesdir: "/etc/nsd/zones"
    verbosity: 1

remote-control:
    control-enable: no

zone:
    name: "${ZONE_NAME}"
    zonefile: "${ZONE_NAME}.zone"
EOF

install -m 0644 "/tmp/${ZONE_NAME}.zone" "/etc/nsd/zones/${ZONE_NAME}.zone"
rm -f "/tmp/${ZONE_NAME}.zone"

nsd-checkconf /etc/nsd/nsd.conf
nsd-checkzone "${ZONE_NAME}" "/etc/nsd/zones/${ZONE_NAME}.zone"

systemctl enable nsd >/dev/null 2>&1 || true
systemctl restart nsd
sleep 1
systemctl is-active nsd

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 53/udp >/dev/null
  ufw allow 53/tcp >/dev/null
  echo "ufw: 53/udp+tcp allowed"
fi

echo "OK: ${ZONE_NAME} served on ${HOST_IP}"
