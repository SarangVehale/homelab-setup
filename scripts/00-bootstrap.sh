#!/usr/bin/env bash
# Orchestrates the full setup, in order, pausing at manual/account-creation
# steps. Read docs/known-issues-and-decisions.md BEFORE running this on new
# hardware - some scripted decisions (Haswell VAAPI workarounds especially)
# are specific to the old machine and should be reconsidered, not blindly
# reapplied.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

confirm() {
    read -p "$1 [Press enter to continue, Ctrl-C to stop] " _
}

echo "############################################################"
echo "# Homelab bootstrap"
echo "# Full picture: README.md and docs/ in this repo"
echo "############################################################"
echo
confirm "About to install packages and do a full system update (scripts/01)."
./scripts/01-packages.sh

echo
echo "############################################################"
echo "# MANUAL STEP: Tailscale"
echo "############################################################"
echo "Install and log in to Tailscale now if not already done:"
echo "  curl -fsSL https://tailscale.com/install.sh | sh"
echo "  sudo tailscale up"
echo "Everything from here on assumes tailscale0 exists and is connected."
confirm "Press enter once Tailscale is up and you have your assigned IP noted."

echo
confirm "Setting up ~/Media storage + ACLs (scripts/02). Service accounts for"
echo "audiobookshelf/calibre-web/jellyfin should already exist from script 01"
echo "(jellyfin) - audiobookshelf/calibre-web accounts get created in script 05,"
echo "this script will warn and continue if they're not there yet, re-run"
echo "script 02 again after script 05 completes."
./scripts/02-storage.sh

echo
confirm "Building Audiobookshelf from source (scripts/03) - takes a few minutes."
./scripts/03-build-audiobookshelf.sh

echo
confirm "Building Calibre-Web from source (scripts/04)."
./scripts/04-build-calibre-web.sh

echo
confirm "Installing all systemd services (scripts/05) - creates service"
echo "accounts, fixes ownership, installs units with the tailscale-online.target"
echo "ordering fix, starts everything."
./scripts/05-systemd-services.sh

echo
confirm "Re-running storage ACL setup now that all service accounts exist (scripts/02)."
./scripts/02-storage.sh

echo
confirm "Deploying the firewall (scripts/06) - the actual Tailscale-only"
echo "enforcement layer, not the individual apps' own bind settings."
./scripts/06-firewall.sh

echo
echo "############################################################"
echo "# MANUAL STEP: qBittorrent first launch"
echo "############################################################"
echo "Launch qBittorrent once now (creates its base config file), then quit"
echo "it fully (tray -> Exit)."
confirm "Press enter once qBittorrent has been launched and fully quit."
./scripts/07-qbittorrent.sh

echo
confirm "Setting up DNS / AdGuard Home (scripts/08) - has its own manual"
echo "pause for the AdGuard Home setup wizard."
./scripts/08-dns-adguard.sh

echo
confirm "Setting up the ebook auto-import watcher (scripts/09)."
./scripts/09-watcher.sh

echo
echo "############################################################"
echo "# Remaining manual steps (deliberately never scripted)"
echo "############################################################"
cat <<'EOF'
1. Jellyfin: complete its setup wizard, add libraries pointed at
   ~/Media/movies (type: Movies) and ~/Media/tv (type: Shows).
   Before touching Transcoding settings, read
   docs/known-issues-and-decisions.md - the Haswell HEVC hardware bug may
   or may not apply to your new hardware, test before assuming either way.

2. Audiobookshelf: complete its setup wizard, add a library pointed at
   ~/Media/audiobooks.

3. Calibre-Web: log in with the default admin/admin123 (change it
   immediately), set library path to ~/Media/ebooks.

4. qBittorrent WebUI: set your own username/password via
   Tools -> Options -> Web UI (don't rely on the auto-generated one).

5. MyAnonamouse account, if migrating that too - this has to be you, live,
   see the site's own invite/interview process. Not something any script
   can do.

6. Router: point DHCP DNS at this machine's LAN IP (for AdGuard Home).

7. Tailscale admin console: register this machine's Tailscale IP as the
   tailnet's global DNS nameserver, for automatic ad-blocking on every
   Tailscale-connected device.
EOF
echo
echo "Bootstrap script sequence complete. Work through the manual steps above."
