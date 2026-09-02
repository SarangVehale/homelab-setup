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

# Cap the journal FIRST. It is both the preventive fix and, on a machine
# that has already filled up, the fastest way to reclaim enough room to
# install anything else. (The journal reached 4.6GB on a 46GB root here.)
echo "==> Capping journal size and reclaiming space"
sudo mkdir -p /etc/systemd/journald.conf.d
sudo cp "$REPO/config-templates/journald/00-size-limit.conf" \
        /etc/systemd/journald.conf.d/00-size-limit.conf
sudo systemctl restart systemd-journald
sudo journalctl --vacuum-size=500M >/dev/null 2>&1 || true
df -h / | tail -1

# Cap core dumps too. A crash-looping service writes one per restart; left
# unbounded they fill the disk and make the underlying fault worse.
sudo mkdir -p /etc/systemd/coredump.conf.d
sudo cp "$REPO/config-templates/coredump/00-size-limit.conf" \
        /etc/systemd/coredump.conf.d/00-size-limit.conf
sudo rm -rf /var/lib/systemd/coredump/* 2>/dev/null || true
sudo systemctl daemon-reload

# Refuse to install onto a full filesystem. Piping into `sudo tee` on a full
# disk silently truncates the destination mid-write, leaving a syntactically
# broken script installed and running on a timer - which is exactly what
# happened once. Fail loudly instead.
ROOT_AVAIL_MB=$(df --output=avail -m / | tail -1 | tr -d ' ')
if [ "$ROOT_AVAIL_MB" -lt 100 ]; then
    echo "ERROR: only ${ROOT_AVAIL_MB}MB free on / - refusing to install." >&2
    echo "       Reclaim more space, then re-run. Check the biggest consumers:" >&2
    echo "       sudo du -xh --max-depth=2 / | sort -rh | head -15" >&2
    exit 1
fi

# Render to a temp file, verify it parses, then install atomically. `install`
# replaces via rename rather than truncating in place, so a running copy is
# never left half-written.
install_script() {
    local src="$1" dest="$2" tmp
    tmp=$(mktemp)
    sed -e "s|__TAILSCALE_IP__|$TS_IP|g" \
        -e "s|__ALERT_EMAIL__|$ALERT_EMAIL|g" \
        -e "s|__HOME__|$HOME|g" "$src" > "$tmp"
    if ! bash -n "$tmp"; then
        echo "ERROR: $src failed to parse after substitution - not installing." >&2
        rm -f "$tmp"; exit 1
    fi
    sudo install -m 755 -o root -g root "$tmp" "$dest"
    rm -f "$tmp"
    # Verify what actually landed, rather than trusting the copy.
    sudo bash -n "$dest" || { echo "ERROR: installed $dest is broken." >&2; exit 1; }
    echo "    installed $dest ($(stat -c%s "$dest") bytes)"
}

echo "==> Installing self-healing health check"
install_script "$REPO/files/media-server-healthcheck.sh" /usr/local/bin/media-server-healthcheck.sh

echo "==> Installing state backup"
install_script "$REPO/files/media-server-backup.sh" /usr/local/bin/media-server-backup.sh

# Unit files need the same placeholder substitution the scripts get - a
# literal __HOME__ in a ReadWritePaths= silently produces a sandbox that
# denies the service its own data directory.
install_unit() {
    local src="$1" dest="$2" tmp
    tmp=$(mktemp)
    sed -e "s|__TAILSCALE_IP__|$TS_IP|g" \
        -e "s|__ALERT_EMAIL__|$ALERT_EMAIL|g" \
        -e "s|__HOME__|$HOME|g" "$src" > "$tmp"
    if grep -q '__[A-Z_]*__' "$tmp"; then
        echo "ERROR: unsubstituted placeholder left in $src:" >&2
        grep -o '__[A-Z_]*__' "$tmp" | sort -u >&2 || true
        rm -f "$tmp"; exit 1
    fi
    sudo install -m 644 -o root -g root "$tmp" "$dest"
    rm -f "$tmp"
}

echo "==> Installing timers"
for u in media-server-healthcheck.service media-server-healthcheck.timer \
         media-server-backup.service media-server-backup.timer; do
    install_unit "$REPO/config-templates/systemd/$u" "/etc/systemd/system/$u"
done

echo "==> Restart hardening + sandboxing"
for s in jellyfin audiobookshelf calibre-web; do
    sudo mkdir -p "/etc/systemd/system/$s.service.d"
    install_unit "$REPO/config-templates/systemd/$s-override.conf" \
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
