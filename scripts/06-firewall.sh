#!/usr/bin/env bash
# Deploy the nftables ruleset that actually enforces Tailscale-only access
# (the real control layer - don't trust individual apps' own bind-address
# settings, see docs/security-model.md).
#
# Auto-detects your LAN subnet from the default route and substitutes it
# into the template. Override with LAN_SUBNET=x.x.x.x/24 if auto-detection
# picks the wrong interface (e.g. multiple NICs).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "${LAN_SUBNET:-}" ]; then
    GATEWAY=$(ip route | awk '/^default/ {print $3; exit}')
    if [ -z "$GATEWAY" ]; then
        echo "ERROR: couldn't auto-detect your LAN gateway. Set it explicitly:"
        echo "       LAN_SUBNET=192.168.1.0/24 ./scripts/06-firewall.sh"
        exit 1
    fi
    LAN_SUBNET="$(echo "$GATEWAY" | sed -E 's/[0-9]+$/0/')/24"
    echo "==> Auto-detected LAN subnet: $LAN_SUBNET (from gateway $GATEWAY)"
    echo "    If this is wrong (e.g. you have multiple network interfaces),"
    echo "    re-run with: LAN_SUBNET=x.x.x.x/24 ./scripts/06-firewall.sh"
fi

echo "==> Rendering nftables ruleset with LAN_SUBNET=$LAN_SUBNET"
sed "s|__LAN_SUBNET__|$LAN_SUBNET|g" "$REPO_ROOT/config-templates/nftables.conf" | sudo tee /etc/nftables.conf >/dev/null

echo "==> Loading and enabling nftables.service"
sudo nft -f /etc/nftables.conf
sudo systemctl enable --now nftables

echo "==> Verifying the ruleset actually loaded (not just the service 'active')"
sudo nft list table inet jellyfin_restrict
sudo nft list table inet adguard_restrict

echo "==> Firewall setup complete."
