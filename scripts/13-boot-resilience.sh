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
# Only PARSE errors matter for boot safety of the file itself. findmnt
# --verify also exits non-zero for:
#   [E] unreachable on boot required source  - the device is simply absent,
#       which is exactly what `nofail` exists to handle
#   [W] your fstab has been modified...      - purely cosmetic
# Treating either as failure aborted an earlier run of this script right
# after it had successfully repaired the file.
# NOTE: every layer here needs its own guard. findmnt exits non-zero, which
# pipefail propagates, which `set -e` acts on - including for a plain
# assignment like VAR=$(...). Three separate runs of this script died on
# exactly that.
fstab_parse_errors() {
    local out=""
    out="$(findmnt --verify --fstab 2>&1 || true)"
    printf '%s\n' "$out" | sed -n 's/^\([0-9]\+\) parse error.*/\1/p' | head -1 || true
}

PARSE_ERRS="$(fstab_parse_errors || true)"
PARSE_ERRS="${PARSE_ERRS:-0}"

if [ "$PARSE_ERRS" -gt 0 ]; then
    echo "    $PARSE_ERRS parse error(s) found:"
    findmnt --verify --fstab 2>&1 | grep -E '^\s*\[E\]|parse error' | sed 's/^/      /' || true
    echo "    Repairing spaces inside the options field..."
    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
    sudo sed -i -E 's/(^[^#][^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]*),[ \t]+/\1,/g' /etc/fstab
    sudo systemctl daemon-reload

    PARSE_ERRS="$(fstab_parse_errors)"; PARSE_ERRS="${PARSE_ERRS:-0}"
    if [ "$PARSE_ERRS" -gt 0 ]; then
        echo "ERROR: fstab still has $PARSE_ERRS parse error(s). Fix by hand" >&2
        echo "       before rebooting - a bad fstab can stop boot." >&2
        findmnt --verify --fstab 2>&1 | sed 's/^/      /' >&2 || true
        exit 1
    fi
    echo "    fstab now parses cleanly."
else
    echo "    fstab parses cleanly (0 parse errors)."
fi

# Report, but do not fail on, the non-structural findings.
if findmnt --verify --fstab 2>&1 | grep -q 'unreachable on boot required source'; then
    echo "    note: a source is unreachable (external drive unplugged)."
    echo "          Harmless - the entry has nofail + x-systemd.device-timeout."
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

echo "==> 2b. systemd-networkd-wait-online"
# This waits for a networkd-managed link to come online. Wi-Fi here is
# managed by iwd, so the only link networkd sees is Ethernet - and when no
# cable is plugged in it waits the full 2 minutes and then fails. That was
# 2min 0s of a 2min 24s boot. Nothing in this stack needs networkd's online
# state (tailscale-online.target is what services actually order against).
if systemctl is-enabled systemd-networkd-wait-online.service >/dev/null 2>&1; then
    sudo systemctl disable systemd-networkd-wait-online.service
    echo "    disabled (was adding ~2min to every boot without a cable)"
else
    echo "    already disabled."
fi

echo "==> 2c. Checking for a plaintext Tailscale auth key"
# A one-shot auth key baked into a unit file is a credential sitting in
# plaintext in /etc, and it gets swept into config backups. tailscaled
# persists its own auth state, so this unit is redundant after first login.
if sudo grep -qs -- '--authkey' /etc/systemd/system/tailscale-autoconnect.service 2>/dev/null; then
    echo "    WARNING: tailscale-autoconnect.service contains a plaintext auth key."
    echo "             It is also currently failing (keys are single-use/expiring)."
    echo "             tailscaled already persists login state, so this unit is"
    echo "             redundant. Disabling it; rotate the key in the admin console."
    sudo systemctl disable --now tailscale-autoconnect.service 2>/dev/null || true
else
    echo "    none found."
fi

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
# A broken grub.cfg is itself an unbootable system - the exact failure mode
# this script exists to prevent. Back up, generate to a temp file, sanity
# check it, and only then install it.
GRUB_BACKUP="/boot/grub/grub.cfg.bak.$(date +%s)"
sudo cp /boot/grub/grub.cfg "$GRUB_BACKUP"
echo "    backup: $GRUB_BACKUP"

GRUB_TMP=$(mktemp)
if ! sudo grub-mkconfig -o "$GRUB_TMP" 2>&1 | sed 's/^/    /'; then
    echo "ERROR: grub-mkconfig failed. Existing grub.cfg left untouched." >&2
    rm -f "$GRUB_TMP"; exit 1
fi

# Must contain at least the normal boot entry, or we are about to install a
# menu with no way into the system.
if ! grep -q "^menuentry 'Arch Linux'" "$GRUB_TMP"; then
    echo "ERROR: generated grub.cfg has no primary Arch Linux entry." >&2
    echo "       Refusing to install it. Existing config untouched." >&2
    rm -f "$GRUB_TMP"; exit 1
fi

sudo install -m 600 -o root -g root "$GRUB_TMP" /boot/grub/grub.cfg
rm -f "$GRUB_TMP"
echo "    installed, $(grep -c '^\s*menuentry' /boot/grub/grub.cfg || true) menu entries"

echo
echo "==> Verifying"
echo "--- boot entries ---"
grep -oE "menuentry '[^']*'" /boot/grub/grub.cfg | sed 's/^/    /' || true
echo "--- unit timeouts (none should be infinity) ---"
for u in media-server-healthcheck media-server-backup media-hdd-recover \
         media-hdd-disconnect docker-network-fix; do
    printf "    %-28s %s\n" "$u" \
        "$(systemctl show "$u.service" -p TimeoutStartUSec --value 2>/dev/null)"
done
echo "--- nftables must not call docker inline ---"
grep -H ExecStartPost /etc/systemd/system/nftables.service.d/*.conf 2>/dev/null | sed 's/^/    /' || true

echo
echo "Done. Re-enable the health check timer when ready:"
echo "  sudo systemctl enable --now media-server-healthcheck.timer"
