#!/bin/bash
# Install and configure Unbound as a RECURSIVE resolver on this host.
# Complements NSD (authoritative, port 53) — Unbound binds port 5353 so the
# two never collide, and serves only a private allowlist of callers:
#   - the host itself (loopback + own public IP, i.e. the VLESS hairpin path
#     used by sing-box's socks-out detour)
#   - $RELAY_IP (the second server), passed as $1
# Idempotent — safe to re-run on every deploy.
# Usage: install-unbound.sh <relay-ip>
set -euo pipefail

RELAY_IP="${1:?usage: install-unbound.sh <relay-ip>}"
SELF_IP=$(hostname -I | awk '{print $1}')
RES_PORT="${BC_RES_PORT:-5353}"
echo "host ip: ${SELF_IP}, resolver port: ${RES_PORT}, relay: ${RELAY_IP}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq unbound

cat > /etc/unbound/unbound.conf.d/bc-recursive.conf <<EOF
server:
    # Loopback for local diagnostics; public IP on a non-standard port for
    # tunnel clients (port 53 belongs to NSD).
    interface: 127.0.0.1
    interface: ${SELF_IP}@${RES_PORT}
    port: 53

    # Recursion is allowed ONLY for the allowlist; everyone else gets REFUSED.
    access-control: 127.0.0.0/8 allow
    access-control: ${SELF_IP} allow
    access-control: ${RELAY_IP} allow

    hide-identity: yes
    hide-version: yes
    do-ip6: no
    qname-minimisation: yes
    prefetch: yes
    do-udp: yes
    do-tcp: yes
    verbosity: 1
EOF

# Defence in depth: even though unbound refuses non-allowlisted recursion,
# keep the port unreachable from the internet. Source-restricted ACCEPTs
# (self + relay) first, everything else dropped.
if command -v iptables >/dev/null 2>&1; then
  # Remove any previous rules for this port (idempotency across re-runs).
  iptables -S INPUT | grep -- "--dport ${RES_PORT}" | while read -r rule; do
    iptables ${rule/-A/-D}
  done
  iptables -I INPUT 1 -p tcp -d "$SELF_IP" --dport "$RES_PORT" -j DROP
  iptables -I INPUT 2 -p udp -d "$SELF_IP" --dport "$RES_PORT" -j DROP
  iptables -I INPUT 1 -p tcp -d "$SELF_IP" --dport "$RES_PORT" -s "$SELF_IP" -j ACCEPT
  iptables -I INPUT 2 -p udp -d "$SELF_IP" --dport "$RES_PORT" -s "$SELF_IP" -j ACCEPT
  iptables -I INPUT 3 -p tcp -d "$SELF_IP" --dport "$RES_PORT" -s "$RELAY_IP" -j ACCEPT
  iptables -I INPUT 4 -p udp -d "$SELF_IP" --dport "$RES_PORT" -s "$RELAY_IP" -j ACCEPT
fi

unbound-checkconf
systemctl enable --now unbound
systemctl restart unbound

echo "--- verification ---"
dig +time=3 +tries=1 "@127.0.0.1" example.org SOA +short
dig +time=3 +tries=1 "@${SELF_IP}" -p "${RES_PORT}" example.org SOA +short
echo "install-unbound: OK"
