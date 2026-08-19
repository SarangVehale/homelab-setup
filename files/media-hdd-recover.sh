#!/usr/bin/env bash
set -uo pipefail
TAG="media-hdd-recover"
UUID="__MEDIA_HDD_UUID__"
MOUNTPOINT="__HOME__/Media"

logger -t "$TAG" "Device event received, waiting for settle"
udevadm settle --timeout=10

# A dead/disconnected device can leave a STALE mount behind (ext4 "shutdown"
# state) even after the real device reconnects under a new /dev/sdX letter -
# mountpoint -q alone returns true for that stale mount, which previously
# caused this script to wrongly conclude "already mounted, nothing to do"
# while services kept reading through a dead handle. Actually verify the
# mount is alive by touching it, not just checking it's present.
if mountpoint -q "$MOUNTPOINT"; then
    if timeout 5 ls "$MOUNTPOINT" >/dev/null 2>&1; then
        logger -t "$TAG" "Already mounted and healthy, nothing to do"
        exit 0
    fi
    logger -t "$TAG" "Mounted but unresponsive (stale/dead mount) - clearing it before remounting"
    systemctl stop jellyfin.service audiobookshelf.service calibre-web.service
    umount "$MOUNTPOINT" 2>&1 | logger -t "$TAG"
    umount "$MOUNTPOINT" 2>&1 | logger -t "$TAG"
fi

DEV=$(readlink -f "/dev/disk/by-uuid/$UUID" 2>/dev/null)
if [ -z "$DEV" ]; then
    logger -t "$TAG" "Device node for UUID $UUID not found, aborting"
    exit 1
fi

logger -t "$TAG" "Running e2fsck -p on $DEV"
e2fsck -p "$DEV"
rc=$?

if [ "$rc" -ge 4 ]; then
    logger -t "$TAG" "e2fsck reported unresolved errors (exit $rc) - NOT auto-mounting, needs manual e2fsck -f review"
    exit 1
fi

logger -t "$TAG" "fsck clean (exit $rc), mounting"
if ! mount "$MOUNTPOINT"; then
    logger -t "$TAG" "mount failed, aborting"
    exit 1
fi

logger -t "$TAG" "Mounted, restarting dependent services"
systemctl start jellyfin.service audiobookshelf.service calibre-web.service

logger -t "$TAG" "Recovery complete"
