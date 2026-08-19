#!/usr/bin/env bash
# Deploys the self-healing layer: auto-remediating health check, nightly
# state backups, journal size cap, and restart hardening.
#
# Idempotent - safe to re-run.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS_IP="${TAILSCALE_IP:-$(tailscale ip -4 2>/dev/null)}"
ALERT_EMAIL="${ALERT_EMAIL:-}"

if [ -z "$TS_IP" ]; then
    echo "ERROR: could not detect Tailscale IP. Set TAILSCALE_IP=... and re-run." >&2
    exit 1
fi
if [ -z "$ALERT_EMAIL" ]; then
    echo "ERROR: set ALERT_EMAIL=you@example.com and re-run." >&2
    exit 1
fi

subst() {
    sed -e "s|__TAILSCALE_IP__|$TS_IP|g" \
        -e "s|__ALERT_EMAIL__|$ALERT_EMAIL|g" \
        -e "s|__HOME__|$HOME|g" "$1"
}

echo "==> Installing self-healing health check"
subst "$REPO/files/media-server-healthcheck.sh" | sudo tee /usr/local/bin/media-server-healthcheck.sh >/dev/null
sudo chmod 755 /usr/local/bin/media-server-healthcheck.sh

echo "==> Installing state backup"
subst "$REPO/files/media-server-backup.sh" | sudo tee /usr/local/bin/media-server-backup.sh >/dev/null
sudo chmod 755 /usr/local/bin/media-server-backup.sh

echo "==> Installing timers"
for u in media-server-healthcheck.service media-server-healthcheck.timer \
         media-server-backup.service media-server-backup.timer; do
    sudo cp "$REPO/config-templates/systemd/$u" "/etc/systemd/system/$u"
done

echo "==> Capping journal size"
sudo mkdir -p /etc/systemd/journald.conf.d
sudo cp "$REPO/config-templates/journald/00-size-limit.conf" \
        /etc/systemd/journald.conf.d/00-size-limit.conf
sudo systemctl restart systemd-journald
sudo journalctl --vacuum-size=500M >/dev/null 2>&1 || true

echo "==> Restart hardening + sandboxing"
for s in jellyfin audiobookshelf calibre-web; do
    sudo mkdir -p "/etc/systemd/system/$s.service.d"
    sudo cp "$REPO/config-templates/systemd/$s-override.conf" \
            "/etc/systemd/system/$s.service.d/override.conf"
done

sudo systemctl daemon-reload
sudo systemctl enable --now media-server-healthcheck.timer media-server-backup.timer
sudo systemctl restart jellyfin audiobookshelf calibre-web

echo
echo "==> Verifying"
systemctl is-active media-server-healthcheck.timer media-server-backup.timer
sudo /usr/local/bin/media-server-healthcheck.sh
echo "--- health state ---"
cat /var/lib/media-server-healthcheck/state

echo
echo "Done. Backups run nightly to ~/Media/backups (14 days retained)."
echo "Run one now to verify:  sudo /usr/local/bin/media-server-backup.sh"
