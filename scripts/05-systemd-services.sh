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

echo "==> Installing systemd units"
sudo cp "$TEMPLATES/audiobookshelf.service" /etc/systemd/system/audiobookshelf.service
sudo cp "$TEMPLATES/calibre-web.service" /etc/systemd/system/calibre-web.service

echo "==> AdGuard Home: tailscale-online.target ordering fix"
sudo mkdir -p /etc/systemd/system/adguardhome.service.d
sudo cp "$TEMPLATES/adguardhome-override.conf" /etc/systemd/system/adguardhome.service.d/override.conf

echo "==> Installing dashboard + ebook watcher (systemd --user units)"
mkdir -p ~/.config/systemd/user
cp "$TEMPLATES/dashboard.service" ~/.config/systemd/user/dashboard.service
cp "$TEMPLATES/calibre-auto-import.service" ~/.config/systemd/user/calibre-auto-import.service

echo "==> Ensuring linger is enabled (so --user services survive logout/reboot)"
sudo loginctl enable-linger "$USER"

echo "==> Reloading and enabling everything"
sudo systemctl daemon-reload
sudo systemctl enable --now audiobookshelf calibre-web jellyfin adguardhome
systemctl --user daemon-reload
systemctl --user enable --now dashboard.service calibre-auto-import.service

sleep 3
echo "==> Status check"
systemctl is-active audiobookshelf calibre-web jellyfin adguardhome
systemctl --user is-active dashboard.service calibre-auto-import.service

echo "==> Done. Verify each service is actually listening correctly, not"
echo "    just 'active' - see docs/known-issues-and-decisions.md, several"
echo "    of these have been caught silently misbehaving before despite"
echo "    systemd reporting them healthy."
