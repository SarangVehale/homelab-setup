#!/usr/bin/env bash
# Install the ebook auto-import watcher: watches ~/Media/ebooks-inbox,
# imports new files into ~/Media/ebooks via calibredb (copies, doesn't
# move - the original stays for continued torrent seeding). See
# docs/services.md and docs/storage-and-permissions.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v calibredb >/dev/null || { echo "ERROR: calibredb not found - run scripts/01-packages.sh first (needs the 'calibre' package)."; exit 1; }
command -v inotifywait >/dev/null || { echo "ERROR: inotifywait not found - needs the 'inotify-tools' package."; exit 1; }

echo "==> Installing watcher script"
mkdir -p ~/.local/bin
cp "$REPO_ROOT/files/calibre-auto-import.sh" ~/.local/bin/calibre-auto-import.sh
chmod +x ~/.local/bin/calibre-auto-import.sh

echo "==> Initializing an empty Calibre library at ~/Media/ebooks (if not already one)"
if [ ! -f "$HOME/Media/ebooks/metadata.db" ]; then
    calibredb list --with-library "$HOME/Media/ebooks" >/dev/null
    echo "    initialized"
else
    echo "    already exists, skipping"
fi

echo "==> Enabling the watcher service (systemd unit installed by script 05)"
systemctl --user daemon-reload
systemctl --user enable --now calibre-auto-import.service
sleep 1
systemctl --user is-active calibre-auto-import.service

echo "==> Done. Test with: touch a real .epub in ~/Media/ebooks-inbox and check"
echo "    it gets imported (organized copy appears under ~/Media/ebooks/Author/...)."
