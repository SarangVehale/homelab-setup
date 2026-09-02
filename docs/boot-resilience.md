# Boot resilience

Written after custom units from this repo made the machine **unbootable**.
Three separate units each hung boot indefinitely, each masking the next, and
the stock Arch install had no recovery entry to boot into. This document
exists so that cannot happen again.

## The incident

Boot hung with no error. Three causes, discovered in sequence:

1. **External media mount** — `nofail` in `/etc/fstab` prevents a *failed*
   mount from stopping boot, but does nothing about a *slow* one. The
   default per-device wait is 90 s.
2. **`media-server-healthcheck.service`** — ran at boot for 17+ minutes with
   no timeout.
3. **`recreate-docker-networks.sh`** wired into `nftables.service` as
   `ExecStartPost=` — the actual root cause, hanging with no limit.

## Why each one hung

### `Type=oneshot` defaults to `TimeoutStartSec=infinity`

This is the single most important fact here. Ordinary services default to
90 s; **oneshot services default to no timeout at all.** Every custom unit
in this repo is oneshot, so every one of them could hang boot forever, and
three did.

```bash
# Confirm on any unit:
systemctl show <unit> -p TimeoutStartUSec --value   # "infinity" is a bug
```

Every unit here now sets an explicit `TimeoutStartSec=`.

### `ExecStartPost=` blocks its parent unit

A unit is not "started" until its `ExecStartPost=` finishes. Hanging a
script there makes the parent hang too.

Worse, `nftables.service` runs `Before=network-pre.target` — very early,
before routing, DNS, or Docker exist. Calling `docker compose up` from there
waits on a network that is not up yet, forever.

**Fix**: an independent unit, correctly ordered, triggered without blocking.

```ini
# nftables drop-in - queues the job and returns immediately
ExecStartPost=-/usr/bin/systemctl start --no-block docker-network-fix.service
```

```ini
# docker-network-fix.service
After=nftables.service docker.service network-online.target
Wants=network-online.target
TimeoutStartSec=180
```

### `nofail` is not a timeout

`nofail` means "do not fail boot if this mount fails". A device that is
merely *slow* (or a USB drive being probed) still blocks for the default
90 s. Both are needed:

```
UUID=<uuid> /path ext4 defaults,nofail,x-systemd.device-timeout=5s 0 2
```

### A space in `fstab` options silently breaks the line

```
defaults,nofail, x-systemd.device-timeout=5s   # BROKEN
defaults,nofail,x-systemd.device-timeout=5s    # correct
```

`fstab` is whitespace-delimited, so the space ends the options field and
the rest is parsed as the dump/pass columns. The timeout is silently never
applied. A successful boot does not prove `fstab` is valid — check
explicitly:

```bash
findmnt --verify --fstab
```

## Recovery entries

Arch ships `GRUB_DISABLE_RECOVERY=true`, so a stock install has **one** boot
entry. When a custom unit hangs boot, there is nothing to fall back to —
which is what turned a self-inflicted hang into a painful recovery.

`config-templates/grub/40_rescue` adds a "Recovery options" submenu:

| Entry | Boots to | Use when |
|---|---|---|
| Rescue shell | `systemd.unit=rescue.target` | A custom service hangs boot. Starts almost nothing — no timers, no oneshots, no graphical target. |
| Emergency shell | `systemd.unit=emergency.target` | Even rescue is blocked. Read-only root, a shell, nothing else. |
| No custom units | `systemd.mask=…` on this repo's units | Boot normally but with this repo's units masked — best for diagnosing *which* one is at fault. |

Also enabled: `GRUB_DISABLE_RECOVERY=false`, `GRUB_TIMEOUT=10` (5 s is easy
to miss when you need it), and a **fallback initramfs** (all modules rather
than an autodetected subset, so it boots when autodetect is wrong).

### Recovering without a recovery entry

If it happens before these are installed, edit the boot entry in place:
press `e` at the GRUB menu, append to the `linux` line, `Ctrl-X` to boot.

```
systemd.unit=rescue.target
```

Then look at what actually hung:

```bash
systemd-analyze blame | head
systemctl list-jobs                 # what is still "running"
journalctl -b -p err
systemctl disable --now <culprit>
```

## Rules for any unit added here

1. **Always set `TimeoutStartSec=`.** Especially on `Type=oneshot`.
2. **Never call out to Docker, a network, or a remote host from
   `ExecStartPost=`** on an early-boot unit. Use a separate unit with
   `After=network-online.target` and trigger it with
   `systemctl start --no-block`.
3. **Bound external commands inside scripts too** — `timeout 60 docker
   compose down`. A unit-level timeout kills the unit but a script that
   hangs mid-way can still leave things half-done.
4. **Prefer `WantedBy=timers.target` over boot-time execution** for anything
   periodic. A timer that fires 2 minutes after boot cannot hang boot.
5. **Verify `findmnt --verify --fstab` after editing `fstab`**, every time.
6. **Test a reboot after adding units.** These faults are invisible until
   the machine is restarted, which may be weeks later — long after the
   change that caused them.


### `set -euo pipefail` + a diagnostic pipeline = script dies mid-repair

The first run of `13-boot-resilience.sh` printed the fstab errors it found
and then **silently stopped**, having fixed nothing:

```bash
findmnt --verify --fstab 2>&1 | grep -iE "parse|error" | sed 's/^/      /'
```

`findmnt --verify` exits non-zero **when it finds problems** — which is
precisely when this line runs. `pipefail` propagates that through the pipe,
and `set -e` terminates the script. The repair code immediately after it
never executed.

This is a general hazard with tools whose non-zero exit means "I found
something" rather than "I failed": `findmnt --verify`, `grep` (1 = no
match), `diff`, `cmp`. Under `set -euo pipefail`, guard them:

```bash
some_check | formatter || true
```

The tell is a script that stops right after printing a diagnostic, with no
error of its own.


### `findmnt --verify` exits non-zero for warnings too

Even after the parse error was fixed, this still returned exit 1:

```
0 parse errors, 1 error, 1 warning
   [E] unreachable on boot required source: UUID=...
   [W] your fstab has been modified, but systemd still uses the old version
```

Neither finding is a structural problem:

- **unreachable source** — the external drive is simply unplugged, which is
  exactly the case `nofail` exists to cover. `findmnt` reports it as `[E]`
  regardless.
- **modified fstab** — cosmetic; cleared by `systemctl daemon-reload`.

So `if findmnt --verify ...` as a pass/fail gate is wrong: it aborted the
repair script immediately *after* it had successfully fixed the file. Test
the number that actually reflects file validity instead:

```bash
findmnt --verify --fstab 2>&1 | sed -n 's/^\([0-9]\+\) parse error.*/\1/p'
```


### `set -e` fires on assignments too — and `bash -n` will not tell you

Three consecutive runs of the repair script aborted on error handling rather
than on the work, each time a variant of the same thing:

```bash
VAR="$(some_check)"      # some_check exits 1 -> `set -e` kills the script
check | formatter        # first command exits 1 -> pipefail -> `set -e`
```

A command substitution in a plain assignment counts. So does any pipeline
under `pipefail`. And commands that report findings with a non-zero exit
(`findmnt --verify`, `grep`, `diff`) hit this constantly — a diagnostic
line, of all things, becomes the thing that stops the script.

`bash -n` catches none of it: the syntax is valid. The only reliable check
is running the control flow. `scripts/dry-run.sh` does that with `sudo`,
`grub-mkconfig` and `mkinitcpio` stubbed:

```bash
./scripts/dry-run.sh scripts/13-boot-resilience.sh
```

Run it against any deploy script before running it for real.


### Two traps in regenerating GRUB

**Do not stage the new `grub.cfg` in `/tmp`.** On this machine `/tmp` is a
tmpfs mounted with `usrquota`. `grub-mkconfig` running under `sudo` writes
into the staging file, and quota is charged against the *file owner* — so a
file created by the unprivileged user fails with a misleading
`Permission denied` even though the writer is root. Stage beside the
destination instead (`/boot/grub/grub.cfg.new.$$`), which is root-owned and
on the same filesystem as the target.

**In `/etc/grub.d/` scripts, `grub-probe` is the `${grub_probe}` variable,
not a command on `PATH`.** Calling it bare fails silently, which made a
custom entry skip itself with "could not determine partition UUIDs" while
`grub-mkconfig` otherwise reported success.

### The fallback initramfs may be disabled

Arch normally ships `PRESETS=('default' 'fallback')`, but this install had
the fallback commented out in `/etc/mkinitcpio.d/linux.preset`, so there was
no second image to boot when the first one fails. The fallback is built with
`-S autodetect` — every module rather than only those detected on the
running system — which is exactly what makes it work when the default does
not. Check with `ls /boot/initramfs-*fallback*`.

<!-- nav:start -->

---

[← Self-healing](self-healing.md) · [Home](../index.md) · [Agent instructions →](../AGENTS.md)

<!-- nav:end -->
