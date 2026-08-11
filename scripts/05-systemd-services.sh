#!/usr/bin/env bash
# Create the audiobookshelf/calibre-web service accounts, fix ownership on
# their source builds, install all systemd units (including the
# tailscale-online.target ordering fix - see
# docs/known-issues-and-decisions.md for why that matters), and start
# everything.
#
# Run AFTER scripts/03 and 04 (source builds must exist) and AFTER
# Tailscale is installed and logged in (these units wait for it at start).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES="$REPO_ROOT/config-templates/systemd"

TAILSCALE_IP="${TAILSCALE_IP:-$(tailscale ip -4 2>/dev/null)}"
if [ -z "$TAILSCALE_IP" ]; then
    echo "ERROR: couldn't auto-detect your Tailscale IP (is Tailscale up?)."
    echo "       Set it explicitly: TAILSCALE_IP=100.x.x.x ./scripts/05-systemd-services.sh"
    exit 1
fi
echo "==> Using Tailscale IP: $TAILSCALE_IP"

echo "==> Creating service accounts (system users, no login, no home dir)"
sudo tee /etc/sysusers.d/audiobookshelf.conf >/dev/null <<'EOF'
u audiobookshelf - "Audiobookshelf" /var/lib/audiobookshelf
EOF
sudo tee /etc/sysusers.d/calibre-web.conf >/dev/null <<'EOF'
u calibre-web - "Calibre-Web" /opt/calibre-web
EOF
sudo systemd-sysusers

echo "==> Creating audiobookshelf data directory"
sudo mkdir -p /var/lib/audiobookshelf/{config,metadata,backup}
sudo chown -R audiobookshelf:audiobookshelf /var/lib/audiobookshelf

echo "==> Fixing ownership on the source builds"
sudo chown -R audiobookshelf:audiobookshelf /opt/audiobookshelf
sudo chown -R calibre-web:calibre-web /opt/calibre-web

echo "==> Installing systemd units (substituting your Tailscale IP)"
sed "s|__TAILSCALE_IP__|$TAILSCALE_IP|g" "$TEMPLATES/audiobookshelf.service" | sudo tee /etc/systemd/system/audiobookshelf.service >/dev/null
sed "s|__TAILSCALE_IP__|$TAILSCALE_IP|g" "$TEMPLATES/calibre-web.service" | sudo tee /etc/systemd/system/calibre-web.service >/dev/null

echo "==> AdGuard Home: tailscale-online.target ordering fix"
sudo mkdir -p /etc/systemd/system/adguardhome.service.d
sudo cp "$TEMPLATES/adguardhome-override.conf" /etc/systemd/system/adguardhome.service.d/override.conf

echo "==> Installing ebook watcher (systemd --user unit; dashboard is handled"
echo "    separately by scripts/10-dashboard.sh, since it also needs to render"
echo "    the dashboard HTML, not just the unit file)"
mkdir -p ~/.config/systemd/user
cp "$TEMPLATES/calibre-auto-import.service" ~/.config/systemd/user/calibre-auto-import.service

echo "==> Ensuring linger is enabled (so --user services survive logout/reboot)"
sudo loginctl enable-linger "$USER"

echo "==> Reloading and enabling everything"
sudo systemctl daemon-reload
sudo systemctl enable --now audiobookshelf calibre-web jellyfin adguardhome
systemctl --user daemon-reload
systemctl --user enable --now calibre-auto-import.service

sleep 3
echo "==> Status check"
systemctl is-active audiobookshelf calibre-web jellyfin adguardhome
systemctl --user is-active calibre-auto-import.service
echo "    (dashboard.service comes up in scripts/10-dashboard.sh)"

echo "==> Done. Verify each service is actually listening correctly, not"
echo "    just 'active' - see docs/known-issues-and-decisions.md, several"
echo "    of these have been caught silently misbehaving before despite"
echo "    systemd reporting them healthy."
