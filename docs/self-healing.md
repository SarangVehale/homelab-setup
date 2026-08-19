# Self-healing

The goal: **add media, ignore everything else.** Failures that have a known
remedy should fix themselves and report afterwards, rather than waiting for
someone to notice.

## What repairs itself

| Failure | Detected by | Automatic response |
|---|---|---|
| Service down or hung | Health check (unit state **and** HTTP) | `systemctl restart` |
| Immich containers down / Docker DNS broken | Health check | `docker compose down && up` (a restart does **not** fix Docker networking) |
| HDD disconnected | udev remove event | Stop dependent services immediately |
| HDD reconnected | udev add event | Clear stale mount → `e2fsck -p` → mount → restart services |
| HDD mounted but dead (stale mount) | Health check liveness probe | Trigger the recovery unit |
| Firewall table missing from the kernel | Health check | Reload `nftables` |
| Docker networking broken by an `nftables` reload | `ExecStartPost` on `nftables.service` | Recreate every compose project |
| Tailscale down | Health check | `systemctl restart tailscaled` |
| Disk filling up | Health check (≥ 90 %) | Vacuum journal, prune old Docker layers, drop 30-day-old cache files |
| Service crash | systemd | `Restart=always`, 10 s backoff |
| Journal growing unbounded | — | Capped at 500 MB / 1 month by config |

## Design rules

**Repair first, then report.** Each check runs a probe; if it fails, a repair
function runs and the probe repeats. Only the outcome is reported. A problem
that healed sends one `SELF-HEALED` note; a problem that did not sends
`PROBLEM`.

**Repairs are capped.** Three consecutive failed repairs and the check stops
trying and just alerts. Without this, a fundamentally broken service gets
restarted every five minutes forever, which turns one fault into a much
noisier one.

**Probes test the real thing.** A service is healthy when its unit is active
**and** its port answers. A mount is healthy when it is mounted **and** a
read succeeds. Both of these were originally weaker and both produced false
"healthy" during real outages — see
[`known-issues-and-decisions.md`](known-issues-and-decisions.md).

**Silence means healthy.** Mail is sent only on state change, so a stable
system is quiet and any mail that arrives is worth reading.

## Backups

Nightly, to `~/Media/backups/<date>/`, 14 days retained:

- Jellyfin — watch history, users, library metadata
- Audiobookshelf — listening progress, users
- Calibre-Web — `app.db` (users/settings) and the Calibre library index
- Immich — `pg_dumpall` of the Postgres database, plus its `.env`
- qBittorrent — torrent state (losing this means re-adding every torrent and
  losing private-tracker seeding history)
- System config not tracked in git — `fstab`, `nftables.conf`, unit files,
  udev/modprobe/tlp/network drop-ins

**Media itself is deliberately not backed up.** It is ~180 GB of
re-downloadable content that already lives on the HDD. What is *not*
re-creatable is the state above, all of which is small.

**Direction matters**: service state lives on the internal SSD and is backed
up to the external HDD, so either drive can fail without data loss.

Jellyfin and Audiobookshelf are briefly stopped during their backup — SQLite
databases copied while running can be inconsistent. Immich uses `pg_dump`
inside the container, which is the supported online method and needs no
downtime. The Postgres dump is size-checked afterwards, since a failed dump
otherwise writes a small valid-looking gzip.

The backup refuses to run at all if the HDD is not mounted **and
responsive**, rather than silently writing into an empty mount point.

## Restoring

```bash
# Jellyfin
sudo systemctl stop jellyfin
sudo tar xzf ~/Media/backups/<date>/jellyfin.tar.gz -C /var/lib
sudo systemctl start jellyfin

# Immich Postgres
gunzip -c ~/Media/backups/<date>/immich-postgres.sql.gz \
  | docker exec -i immich_postgres psql -U immich -d immich

# qBittorrent (must be fully quit first - it overwrites config on exit)
tar xzf ~/Media/backups/<date>/qbittorrent.tar.gz -C ~/.local/share
```

## What still needs a human

Being honest about the boundaries — these are **not** self-healing:

- **Physical faults.** A dead USB cable, an unplugged drive, a failed disk.
  Recovery handles the drive *coming back*; it cannot plug it in.
- **The Wi-Fi bandwidth ceiling.** A hardware limit of the 2.4 GHz-only
  card. See
  [`storage-hardware-reliability.md`](storage-hardware-reliability.md).
- **A filesystem with real corruption.** Recovery deliberately refuses to
  mount when `e2fsck` reports unresolved errors, and escalates instead.
- **Credentials and accounts.** Never scripted, by design.
- **Disk genuinely full of media.** Cleanup reclaims caches and logs, not
  the library. That decision stays human.
