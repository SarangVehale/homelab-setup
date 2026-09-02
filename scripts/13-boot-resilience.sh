#!/usr/bin/env bash
# Makes boot survivable: recovery menu entries, fallback initramfs, bounded
# timeouts on every custom unit, and a correctly-ordered Docker network fix.
#
# Written after a boot hang caused by custom units in this repo. See
# docs/boot-resilience.md.
#
# Idempotent - safe to re-run.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 1. Validating /etc/fstab"
# A stray space inside the options field silently breaks the line: the
# remaining options are parsed as the dump/pass columns, so things like
# x-systemd.device-timeout are never applied. findmnt catches this; a
# successful boot does not.
if ! findmnt --verify --fstab >/dev/null 2>&1; then
    echo "    fstab has parse errors:"
    findmnt --verify --fstab 2>&1 | grep -iE "parse|error" | sed 's/^/      /'
    echo "    Fixing spaces inside the options field..."
    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
    # Collapse ", " to "," only within a line's option list.
    sudo sed -i -E 's/(^[^#][^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]*),[ \t]+/\1,/g' /etc/fstab
    if findmnt --verify --fstab >/dev/null 2>&1; then
        echo "    fstab now parses cleanly."
    else
        echo "    STILL BROKEN - fix by hand before rebooting:" >&2
        findmnt --verify --fstab 2>&1 | sed 's/^/      /' >&2
        exit 1
    fi
else
    echo "    fstab parses cleanly."
fi

echo "==> 2. Bounded timeouts on every custom unit"
for u in media-server-healthcheck.service media-server-backup.service \
         media-hdd-recover.service media-hdd-disconnect.service \
         docker-network-fix.service; do
    [ -f "$REPO/config-templates/systemd/$u" ] || continue
    sudo install -m 644 -o root -g root "$REPO/config-templates/systemd/$u" \
         "/etc/systemd/system/$u"
done
sudo mkdir -p /etc/systemd/system/nftables.service.d
sudo install -m 644 -o root -g root \
     "$REPO/config-templates/systemd/nftables-docker-fix.conf" \
     /etc/systemd/system/nftables.service.d/docker-network-fix.conf
sudo systemctl daemon-reload

echo "==> 3. Recovery entries in GRUB"
sudo install -m 755 -o root -g root "$REPO/config-templates/grub/40_rescue" \
     /etc/grub.d/40_rescue
# Arch defaults this to true, which is why a stock install has no way in.
if grep -q '^GRUB_DISABLE_RECOVERY=true' /etc/default/grub 2>/dev/null; then
    sudo sed -i 's/^GRUB_DISABLE_RECOVERY=true/GRUB_DISABLE_RECOVERY=false/' /etc/default/grub
    echo "    GRUB_DISABLE_RECOVERY -> false"
fi
# A 5s timeout is easy to miss when you need the menu.
sudo sed -i 's/^GRUB_TIMEOUT=5$/GRUB_TIMEOUT=10/' /etc/default/grub 2>/dev/null || true

echo "==> 4. Fallback initramfs"
# The fallback image includes all modules rather than an autodetected
# subset, so it still boots when hardware changes or autodetect got it wrong.
if ! ls /boot/initramfs-*fallback* >/dev/null 2>&1; then
    echo "    building fallback initramfs..."
    sudo mkinitcpio -P
else
    echo "    already present."
fi

echo "==> 5. Regenerating GRUB config"
sudo grub-mkconfig -o /boot/grub/grub.cfg

echo
echo "==> Verifying"
echo "--- boot entries ---"
grep -oE "menuentry '[^']*'" /boot/grub/grub.cfg | sed 's/^/    /'
echo "--- unit timeouts (none should be infinity) ---"
for u in media-server-healthcheck media-server-backup media-hdd-recover \
         media-hdd-disconnect docker-network-fix; do
    printf "    %-28s %s\n" "$u" \
        "$(systemctl show "$u.service" -p TimeoutStartUSec --value 2>/dev/null)"
done
echo "--- nftables must not call docker inline ---"
grep -H ExecStartPost /etc/systemd/system/nftables.service.d/*.conf 2>/dev/null | sed 's/^/    /'

echo
echo "Done. Re-enable the health check timer when ready:"
echo "  sudo systemctl enable --now media-server-healthcheck.timer"
