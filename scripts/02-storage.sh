#!/usr/bin/env bash
# Create the ~/Media layout and grant each service account scoped ACL
# access. See docs/storage-and-permissions.md for why ACLs instead of
# group permissions or a /srv-based layout.
set -euo pipefail

MEDIA="$HOME/Media"

echo "==> Creating directory structure"
mkdir -p "$MEDIA"/{movies,tv,audiobooks,ebooks,ebooks-inbox,incomplete}

echo "==> Confirming home directory stays locked (should be 700, or after ACLs, group::--- in getfacl)"
chmod 700 "$HOME" 2>/dev/null || true

# Service accounts must already exist at this point - they're created by
# their respective package/systemd-unit installs (scripts 01, 03, 04).
for svc in jellyfin audiobookshelf calibre-web; do
    if ! id "$svc" &>/dev/null; then
        echo "WARNING: user '$svc' doesn't exist yet - run the relevant install script first, then re-run this one."
    fi
done

echo "==> Granting traverse-only access on the home directory itself"
# --x lets each service account pass through $HOME to reach its own
# subfolder, without being able to list or read anything else in it.
for svc in jellyfin audiobookshelf calibre-web; do
    id "$svc" &>/dev/null && setfacl -m u:"$svc":--x "$HOME"
done

echo "==> Jellyfin: read-only on movies + tv"
if id jellyfin &>/dev/null; then
    setfacl -R -m u:jellyfin:r-X "$MEDIA/movies" "$MEDIA/tv"
    setfacl -R -d -m u:jellyfin:r-X "$MEDIA/movies" "$MEDIA/tv"
fi

echo "==> Audiobookshelf: read-only on audiobooks"
if id audiobookshelf &>/dev/null; then
    setfacl -R -m u:audiobookshelf:r-X "$MEDIA/audiobooks"
    setfacl -R -d -m u:audiobookshelf:r-X "$MEDIA/audiobooks"
fi

echo "==> Calibre-Web: read-write on ebooks (it actively manages the library)"
if id calibre-web &>/dev/null; then
    setfacl -R -m u:calibre-web:rwX "$MEDIA/ebooks"
    setfacl -R -d -m u:calibre-web:rwX "$MEDIA/ebooks"
fi

echo "==> Verifying home directory group permission is genuinely unaffected"
getfacl "$HOME" | grep "^group::"
echo "    (should read 'group::---' - if not, something is wrong, stop and investigate)"

echo "==> Storage setup complete."
