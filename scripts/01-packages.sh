#!/usr/bin/env bash
# Install everything available as a native Arch package.
# Audiobookshelf and Calibre-Web are deliberately NOT here - they're built
# from source in scripts/03 and 04. See docs/known-issues-and-decisions.md
# for why.
set -euo pipefail

echo "==> Full system update first (avoids partial-upgrade dependency conflicts)"
sudo pacman -Syu --noconfirm

echo "==> Installing packages"
sudo pacman -S --needed --noconfirm \
    qbittorrent \
    calibre \
    inotify-tools \
    jellyfin-server jellyfin-web jellyfin-ffmpeg \
    adguardhome \
    acl \
    git \
    npm

echo "==> Done. Package installs complete."
echo "    qBittorrent, Jellyfin, AdGuard Home are ready to configure."
echo "    Audiobookshelf and Calibre-Web still need scripts/03 and 04."
