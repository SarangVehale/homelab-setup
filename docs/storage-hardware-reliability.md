# External storage & hardware reliability

Covers the migration of the media library onto an external 2 TB USB HDD, and
the chain of real hardware faults that surfaced afterwards. **Read this
before attaching external storage on any machine** — most of the failures
here were unrelated to the drive itself and cost hours to isolate.

## Layout

The media library lives on an external 2 TB Toshiba HDD (USB-SATA bridge),
mounted **at the same path it previously occupied on internal storage**:

```
/dev/sdX1  ext4  ~/Media
```

### Why mount at the original path instead of `/mnt/something`

Every service references `~/Media/...` — Jellyfin library paths,
Audiobookshelf, Calibre-Web, Navidrome, qBittorrent categories and save
paths, the ebook watcher. Mounting the new disk **at that same path** meant
the migration required **zero config changes in any service**. As far as
every app is concerned nothing moved; only what sits underneath the mount
point changed.

Migrating by pointing services at a new path instead would have meant
touching six services' configs and re-doing every ACL grant. Don't do that.

### Filesystem choice: ext4, not NTFS/exFAT

The drive shipped NTFS-formatted (Windows factory default). **This will not
work** for this setup: the entire permission model depends on POSIX ACLs
(see [`storage-and-permissions.md`](storage-and-permissions.md)), which
NTFS and exFAT do not support on Linux. Reformat to ext4 before migrating
anything.

### fstab: mount by UUID, with `nofail`

```
UUID=<uuid>  ~/Media  ext4  defaults,nofail  0 2
```

- **UUID, not `/dev/sdb1`** — device letters are not stable. This drive was
  observed as `sdb`, `sdc`, `sdd`, and `sde` across a single week of
  disconnect/reconnect cycles. Anything referencing a device letter breaks.
- **`nofail`** — without it, the machine hangs at boot if the drive is
  absent or slow to enumerate.

### Migrating data: `rsync -aAX`, not `cp`

```
rsync -aAX --info=progress2 /old/path/ /new/mount/
```

`-A` preserves ACLs and `-X` extended attributes. A plain `cp` or `rsync -a`
silently drops the ACL grants that every service depends on. Verify with
`getfacl` on the destination afterwards rather than trusting the copy.

## The disconnect saga — three separate root causes

The drive repeatedly dropped off the USB bus. This looked like one problem
and was actually three, fixed in sequence. If external storage is dropping,
work through all three.

### 1. UAS driver incompatibility (JMicron JMS583 bridge)

**Symptom**: random disconnects, `Synchronize Cache(10) failed`, aborted
ext4 journal.

**Cause**: the enclosure's JMicron JMS583 USB-SATA bridge advertises UAS
(USB Attached SCSI) support but behaves badly under the `uas` driver — a
well-documented problem with this chipset family across many Linux projects.

**Fix**: force it onto the older, more conservative `usb-storage` driver via
a kernel quirk keyed to that chip's USB vendor:product ID.

```
# /etc/modprobe.d/usb-storage-quirks.conf
options usb_storage quirks=152d:0583:u
```

Confirm it took effect — the kernel says so explicitly:
```
kernel: usb 3-3.3: UAS is ignored for this device, using usb-storage instead
```

### 2. USB autosuspend

**Symptom**: after the UAS fix, disconnects continued — roughly every two
minutes **while idle**.

**Cause**: USB autosuspend was enabled (`power/control = auto`,
`autosuspend_delay_ms = 2000`). The bridge chip does not resume cleanly
from a suspended link, so the kernel falls back to a full port reset — which
presents as a complete disconnect/reconnect with a new device number.

**Fix**: a udev rule pinning `power/control` to `on` for that device.

### 3. TLP overriding the udev rule (the one that hid the fix)

**Symptom**: the autosuspend fix appeared to apply, then silently reverted —
`power/control` was back to `auto` and disconnects resumed.

**Cause**: `tlp.service` ships its own udev rule (`85-tlp.rules`) that
re-asserts USB power policy on every device event, overriding the earlier
rule moments after it applied. Setting the sysfs value by hand worked
(bypassing udev entirely), which is exactly what made this confusing —
manual fix holds, real reconnect does not.

**Fix**: exclude the device from TLP's USB management rather than fighting
it with rule ordering.

```
# /etc/tlp.d/50-media-hdd.conf
USB_DENYLIST="152d:0583"
```

**Generalisable lesson**: when a udev-applied setting reverts, check for a
*power-management daemon* re-asserting it before assuming your rule is
wrong. `udevadm test` will happily confirm your rule matches and would
write the value — it is a dry run and proves nothing about who writes last.

## Stale mounts: the failure mode that fooled the monitoring

When the drive disconnects mid-write, ext4 shuts the filesystem down but
**the mount entry remains**. On reconnect (under a new device letter) the
recovery path mounts the fresh device at the same path, producing a
*stacked* mount:

```
~/Media  /dev/sde1  ext4  rw,relatime,emergency_ro,shutdown   <- dead
~/Media  /dev/sdb1  ext4  rw,relatime                          <- live
```

**`mountpoint -q` returns true for the dead mount.** Both the auto-recovery
script and the health check originally used exactly that test, so both
reported "mounted, healthy, nothing to do" while services were reading
through a dead handle and getting I/O errors.

**Fix**: never test presence alone — test that the mount actually responds.

```bash
if mountpoint -q "$MP" && timeout 5 ls "$MP" >/dev/null 2>&1; then
    # genuinely healthy
fi
```

To clear a stack, unmount repeatedly until `findmnt` returns nothing, then
`e2fsck -f` and remount.

## Auto-recovery

Two udev-triggered systemd units handle disconnects without manual work:

| Unit | Trigger | Does |
|---|---|---|
| `media-hdd-disconnect.service` | USB remove event for that serial | Stops dependent services so they stop hammering a dead mount |
| `media-hdd-recover.service` | Block add event for that filesystem UUID | Clears any stale mount, `e2fsck -p`, mounts, restarts services |

Recovery deliberately **refuses to auto-mount if `e2fsck` reports
unresolved errors** (exit ≥ 4) — it logs and stops rather than mounting a
possibly-damaged filesystem. Routine journal replay is fine and proceeds.

Match udev rules on `remove` events by `ENV{ID_SERIAL_SHORT}`, not
`ATTRS{serial}` — sysfs attributes are not reliably readable by the time a
remove event is processed.

## Wi-Fi: a hard hardware ceiling

**Chipset**: Qualcomm Atheros AR9285 — single-band **2.4 GHz only**,
single-stream 802.11n. Verify with `iw phy | grep "Band"`: only Band 1 is
present. No 5 GHz, at any router setting.

Observed link rate: **65 Mbit/s**, realistically ~25-30 Mbit/s of usable
throughput, shared with all other traffic and competing with everything
else on a congested 2.4 GHz band.

**This is the binding constraint on streaming quality**, and it interacts
badly with the transcoding decision — see
[`transcoding.md`](transcoding.md): re-encoding HEVC to H.264 roughly
tripled file bitrates, which is fine for CPU but significantly worse for a
saturated 2.4 GHz link.

**Fix on this hardware: use Ethernet.** The machine has an unused gigabit
port (`enp0s25`). This eliminates the bandwidth ceiling, 2.4 GHz
congestion, and the Wi-Fi rekey drop below, all at once — a cable is worth
more here than any amount of software tuning.

**On new hardware**: any modern dual-band card removes this entirely.

### Hourly Wi-Fi reauthentication

Verified across multiple days: the client reauthenticates **on the hour,
every hour**, within a second of `:56:55`. That regularity rules out
interference or signal problems — it is the access point's **group key
(GTK) rekey interval**, typically a router setting defaulting to 3600
seconds. Each rekey causes a brief blip.

Not fixable on the client. Either raise/disable the interval in the router,
or use Ethernet.

## Fan

Worth recording since it was suspected during thermal investigation: the
`hp-wmi` `pwm1_enable` sysfs control **does not function on this model** —
writes are rejected with `Invalid argument` regardless of value, so there is
no OS-level fan override. Fan control is entirely BIOS/EC-managed.

To test the fan, induce real CPU load and watch temperatures. Healthy
behaviour is a plateau (observed: ~74 °C under sustained full load on all
four threads, from a ~49 °C idle) with fast recovery once load stops — not
a climb toward the 100 °C critical point.
