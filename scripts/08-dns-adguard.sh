#!/usr/bin/env bash
# Fix the systemd-resolved / AdGuard Home port 53 conflict, point this
# machine's own DNS resolution at AdGuard Home, and apply the blocklist
# filter set. AdGuard Home's own account/library/first-run wizard is NOT
# scripted - see the manual step this script pauses for.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAN_IP="${LAN_IP:-$(ip -4 addr show scope global | awk '/inet/ {print $2}' | cut -d/ -f1 | head -1)}"
if [ -z "$LAN_IP" ]; then
    echo "ERROR: couldn't auto-detect your LAN IP."
    echo "       Set it explicitly: LAN_IP=192.168.x.x ./scripts/08-dns-adguard.sh"
    exit 1
fi
echo "==> Using LAN IP: $LAN_IP"

echo "==> Checking for the systemd-resolved port 53 conflict"
if grep -q "^hosts:.*resolve" /etc/nsswitch.conf; then
    echo "    nss-resolve confirmed in /etc/nsswitch.conf - safe to disable the"
    echo "    stub listener, most local programs don't use it directly."
else
    echo "    WARNING: nss-resolve not found in nsswitch.conf - disabling the"
    echo "    stub listener might affect local DNS resolution differently than"
    echo "    on the reference machine. Verify with 'resolvectl query' after."
fi

echo "==> Disabling systemd-resolved's stub listener (frees port 53)"
sudo sed -i 's/^#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo sed -i 's/^#DNS=$/DNS='"$LAN_IP"'/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
sleep 1
echo "    sanity check:"
resolvectl query google.com | head -3

echo ""
echo "==> MANUAL STEP REQUIRED:"
echo "    1. sudo systemctl enable --now adguardhome"
echo "    2. Visit http://<this-machine-lan-or-tailscale-ip>:80 (or :3000 on"
echo "       first run before it's configured) and complete the setup wizard"
echo "       yourself - admin account creation is deliberately never scripted."
echo "    3. Once done, come back and run:"
echo "       sudo systemctl stop adguardhome"
echo "       # merge config-templates/adguardhome-filters.yaml's filters: block"
echo "       # into /etc/adguardhome.yaml (see that file's own comments)"
echo "       sudo systemctl start adguardhome"
echo ""
echo "    4. Router: point your router's DHCP-assigned DNS server at"
echo "       $LAN_IP (ISP-specific web UI, not scriptable)."
echo "    5. Tailscale: login.tailscale.com/admin/dns -> Add Nameserver ->"
echo "       your Tailscale IP -> Override local DNS on. Covers every"
echo "       Tailscale-connected device automatically."
echo ""
read -p "Press enter once you've completed the AdGuard Home wizard (step 2) to continue..." _
