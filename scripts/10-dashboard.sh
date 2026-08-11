#!/usr/bin/env bash
# Deploy the static dashboard - a single HTML page linking to every service,
# served by python -m http.server rather than a heavier tool like
# Homarr/Homepage (deliberate choice, see docs/services.md).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TAILSCALE_IP="${TAILSCALE_IP:-$(tailscale ip -4 2>/dev/null)}"
if [ -z "$TAILSCALE_IP" ]; then
    echo "ERROR: couldn't auto-detect your Tailscale IP (is Tailscale up?)."
    echo "       Set it explicitly: TAILSCALE_IP=100.x.x.x ./scripts/10-dashboard.sh"
    exit 1
fi
echo "==> Using Tailscale IP: $TAILSCALE_IP"

echo "==> Creating /srv/dashboard"
sudo mkdir -p /srv/dashboard
sudo chown "$USER":"$USER" /srv/dashboard

echo "==> Rendering dashboard HTML with your Tailscale IP"
sed "s|__TAILSCALE_IP__|$TAILSCALE_IP|g" "$REPO_ROOT/config-templates/dashboard/index.html" > /srv/dashboard/index.html

echo "==> Rendering + installing the systemd --user unit"
mkdir -p ~/.config/systemd/user
sed "s|__TAILSCALE_IP__|$TAILSCALE_IP|g" "$REPO_ROOT/config-templates/systemd/dashboard.service" > ~/.config/systemd/user/dashboard.service

echo "==> Enabling"
systemctl --user daemon-reload
systemctl --user enable --now dashboard.service
sleep 1
systemctl --user is-active dashboard.service

echo "==> Done. Reachable at http://$TAILSCALE_IP:9000"
