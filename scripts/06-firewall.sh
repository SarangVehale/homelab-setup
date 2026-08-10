#!/usr/bin/env bash
# Deploy the nftables ruleset that actually enforces Tailscale-only access
# (the real control layer - don't trust individual apps' own bind-address
# settings, see docs/security-model.md).
#
# IMPORTANT: edit config-templates/nftables.conf first if the LAN subnet on
# new hardware isn't 192.168.1.0/24 - check with: ip route | grep default
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CURRENT_SUBNET=$(ip route | awk '/^default/ {print $3}' | sed -E 's/[0-9]+$/0/')
if [ -n "$CURRENT_SUBNET" ] && ! grep -q "$CURRENT_SUBNET" "$REPO_ROOT/config-templates/nftables.conf"; then
    echo "WARNING: detected LAN gateway subnet ($CURRENT_SUBNET/24) does not match"
    echo "         what's hardcoded in config-templates/nftables.conf (192.168.1.0/24)."
    echo "         Edit that file's LAN subnet references before continuing, or"
    echo "         AdGuard Home's DNS port won't be reachable from your actual LAN."
    read -p "Continue anyway? [y/N] " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

echo "==> Installing nftables ruleset"
sudo cp "$REPO_ROOT/config-templates/nftables.conf" /etc/nftables.conf
sudo nft -f /etc/nftables.conf

echo "==> Enabling nftables.service (loads the ruleset at boot)"
sudo systemctl enable --now nftables

echo "==> Verifying the ruleset actually loaded (not just the service 'active')"
sudo nft list table inet jellyfin_restrict
sudo nft list table inet adguard_restrict

echo "==> Firewall setup complete."
