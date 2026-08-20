#!/usr/bin/env bash
# Backs up every service's *state* (databases, configs, watch history,
# torrent state) to the media HDD.
#
# Deliberately does NOT back up the media itself - that's ~180 GB of
# re-downloadable content, and it already lives on the HDD. What is NOT
# re-creatable is everything here: watch positions, Immich's database,
# Calibre's library index, qBittorrent's torrent state.
#
# Direction matters: service state lives on the internal SSD, backups go to
# the external HDD. Either drive can fail without losing this data.
set -uo pipefail

DEST="__HOME__/Media/backups"
STAMP=$(date +%Y-%m-%d)
OUT="$DEST/$STAMP"
KEEP_DAYS=14
TAG="media-backup"
MAILTO="__ALERT_EMAIL__"

log() { logger -t "$TAG" "$*"; }
fail() { log "FAILED: $*"; FAILURES="${FAILURES:-}$*\n"; }

# Refuse to back up onto a dead/stale mount - it would silently succeed
# into an unwritable or wrong filesystem.
if ! mountpoint -q "__HOME__/Media" || ! timeout 8 ls "__HOME__/Media" >/dev/null 2>&1; then
    log "media HDD not mounted/responsive - skipping backup"
    exit 1
fi

mkdir -p "$OUT" || { log "cannot create $OUT"; exit 1; }
log "starting backup to $OUT"

# --- Jellyfin: watch history, users, library metadata ---
if [ -d /var/lib/jellyfin ]; then
    systemctl stop jellyfin.service
    tar czf "$OUT/jellyfin.tar.gz" -C /var/lib jellyfin 2>/dev/null || fail "jellyfin"
    [ -d /etc/jellyfin ] && tar czf "$OUT/jellyfin-etc.tar.gz" -C /etc jellyfin 2>/dev/null
    systemctl start jellyfin.service
fi

# --- Audiobookshelf: listening progress, users ---
if [ -d /var/lib/audiobookshelf ]; then
    systemctl stop audiobookshelf.service
    tar czf "$OUT/audiobookshelf.tar.gz" -C /var/lib audiobookshelf 2>/dev/null || fail "audiobookshelf"
    systemctl start audiobookshelf.service
fi

# --- Calibre-Web: users/settings (app.db). The Calibre library metadata.db
#     lives with the books on the HDD and is covered by the books themselves.
if [ -f /opt/calibre-web/app.db ]; then
    sqlite3 /opt/calibre-web/app.db ".backup '$OUT/calibre-web-app.db'" 2>/dev/null || fail "calibre-web"
fi
[ -f "__HOME__/Media/ebooks/metadata.db" ] && \
    sqlite3 "__HOME__/Media/ebooks/metadata.db" ".backup '$OUT/calibre-metadata.db'" 2>/dev/null

# --- Immich: Postgres dump. pg_dump inside the running container is the
#     supported path; a file copy of a live Postgres data dir is not safe.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q immich_postgres; then
    docker exec -t immich_postgres pg_dumpall --clean --if-exists -U immich 2>/dev/null \
        | gzip > "$OUT/immich-postgres.sql.gz" || fail "immich-postgres"
    # Sanity-check: a dump that's suspiciously small means it failed quietly.
    if [ "$(stat -c%s "$OUT/immich-postgres.sql.gz" 2>/dev/null || echo 0)" -lt 10240 ]; then
        fail "immich-postgres (dump implausibly small)"
    fi
fi
[ -f /opt/immich/.env ] && cp /opt/immich/.env "$OUT/immich.env" && chmod 600 "$OUT/immich.env"
[ -f /opt/immich/docker-compose.yml ] && cp /opt/immich/docker-compose.yml "$OUT/"

# --- qBittorrent: torrent state. Losing this means re-adding every torrent
#     and losing seeding history/ratio on private trackers.
if [ -d "__HOME__/.local/share/qBittorrent" ]; then
    tar czf "$OUT/qbittorrent.tar.gz" \
        -C "__HOME__/.local/share" qBittorrent \
        -C "__HOME__/.config" qBittorrent 2>/dev/null || fail "qbittorrent"
fi

# --- System config that isn't in git ---
tar czf "$OUT/system-config.tar.gz" \
    /etc/fstab /etc/nftables.conf /etc/systemd/system/*.service \
    /etc/systemd/system/*.service.d /etc/udev/rules.d/99-media-hdd.rules \
    /etc/modprobe.d/usb-storage-quirks.conf /etc/tlp.d/50-media-hdd.conf \
    /etc/systemd/network/ 2>/dev/null

# --- Rotate ---
find "$DEST" -maxdepth 1 -type d -name '20*' -mtime "+$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null

SIZE=$(du -sh "$OUT" 2>/dev/null | cut -f1)
log "backup complete: $OUT ($SIZE)"

if [ -n "${FAILURES:-}" ]; then
    printf 'Subject: [media-server] Backup completed with errors\nTo: %s\n\nBackup to %s finished, but these components failed:\n\n%b\nHost: %s\n' \
        "$MAILTO" "$OUT" "$FAILURES" "${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo unknown)}" | msmtp "$MAILTO" 2>/dev/null
    exit 1
fi
