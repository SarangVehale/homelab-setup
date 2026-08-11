#!/usr/bin/env bash
# Configure qBittorrent: private-tracker settings, categories, WebUI
# binding, tray behavior. qBittorrent must be launched once manually first
# so it creates its own base config file - this script patches specific
# keys into it, it doesn't create the file from scratch.
#
# IMPORTANT: qBittorrent must NOT be running while this script edits its
# config - it holds config in memory and overwrites the file on exit,
# silently clobbering these changes. See docs/services.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QBT_CONF="$HOME/.config/qBittorrent/qBittorrent.conf"
QBT_CATEGORIES="$HOME/.config/qBittorrent/categories.json"
TAILSCALE_IP="${TAILSCALE_IP:-$(tailscale ip -4 2>/dev/null)}"
if [ -z "$TAILSCALE_IP" ]; then
    echo "ERROR: couldn't auto-detect your Tailscale IP (is Tailscale up? 'tailscale ip -4')."
    echo "       Set it explicitly: TAILSCALE_IP=100.x.x.x ./scripts/07-qbittorrent.sh"
    exit 1
fi

if pgrep -x qbittorrent >/dev/null; then
    echo "ERROR: qBittorrent is running. Quit it fully first (tray -> Exit, not"
    echo "       just closing the window - 'close to tray' means the window"
    echo "       close doesn't actually quit it), then re-run this script."
    exit 1
fi

if [ ! -f "$QBT_CONF" ]; then
    echo "ERROR: $QBT_CONF doesn't exist yet."
    echo "       Launch qBittorrent once manually, close it, then re-run this script."
    exit 1
fi

echo "==> Installing categories (routes downloads by type into ~/Media)"
mkdir -p "$(dirname "$QBT_CATEGORIES")"
sed "s|__HOME__|$HOME|g" "$REPO_ROOT/config-templates/qbittorrent-categories.json" > "$QBT_CATEGORIES"

echo "==> Patching qBittorrent.conf"
mkdir -p "$HOME/Media"/{movies,tv,audiobooks,ebooks-inbox,incomplete}

# Private-tracker requirements - mandatory, leaving these on risks a ban
grep -q "^Session\\\\DHTEnabled=" "$QBT_CONF" && \
    sed -i 's/^Session\\DHTEnabled=.*/Session\\DHTEnabled=false/' "$QBT_CONF" || \
    echo 'Session\DHTEnabled=false' >> "$QBT_CONF"
grep -q "^Session\\\\PeXEnabled=" "$QBT_CONF" && \
    sed -i 's/^Session\\PeXEnabled=.*/Session\\PeXEnabled=false/' "$QBT_CONF" || \
    echo 'Session\PeXEnabled=false' >> "$QBT_CONF"
grep -q "^Session\\\\LSDEnabled=" "$QBT_CONF" && \
    sed -i 's/^Session\\LSDEnabled=.*/Session\\LSDEnabled=false/' "$QBT_CONF" || \
    echo 'Session\LSDEnabled=false' >> "$QBT_CONF"

echo "==> NOTE: the following still need manual attention in the conf/GUI:"
echo "    - Session\\DefaultSavePath = $HOME/Media/ebooks-inbox"
echo "    - Session\\TempPath = $HOME/Media/incomplete"
echo "    - [Preferences] WebUI\\Enabled=true"
echo "    - [Preferences] WebUI\\Address=$TAILSCALE_IP"
echo "    - [Preferences] WebUI\\Port=8080"
echo "    - [Preferences] General\\CloseToTray=true"
echo "    - [Preferences] General\\MinimizeToTray=true"
echo "    - [Preferences] General\\StartMinimized=true"
echo "    These are easiest to set via Tools -> Options in the GUI once,"
echo "    since qBittorrent validates them on save. WebUI username/password"
echo "    is NOT scripted anywhere - set your own via Tools -> Options -> Web UI"
echo "    immediately, don't rely on the auto-generated temporary one."

echo "==> Setting up autostart"
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/qbittorrent.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=qBittorrent
Comment=Start qBittorrent minimized so seeding runs in the background at login
Exec=qbittorrent --no-splash
Icon=qbittorrent
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

echo "==> Done. Launch qBittorrent, set the settings noted above via the GUI, then quit and relaunch."
