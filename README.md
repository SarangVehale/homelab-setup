# Home media/self-hosting setup

This repo documents and scripts the personal media/self-hosting stack running on
`media-server` (Arch Linux, Intel Haswell laptop). Built up incrementally; this repo
exists so the whole thing can be **reproduced on new hardware** without
re-deriving every decision from scratch.

## Why this exists

The current laptop's hardware (2013/2014-era Intel Haswell) has real limits —
most notably it cannot properly hardware-transcode HEVC video (see
[`docs/known-issues-and-decisions.md`](docs/known-issues-and-decisions.md)).
A hardware upgrade is expected in roughly 2-3 years. When that happens, this
repo should let the whole stack be rebuilt on the new machine in an afternoon
instead of a week.

**Using an AI coding agent to do the rebuild?** Point it at
[`AGENTS.md`](AGENTS.md) first — it's an operating manual for exactly that,
covering what the agent should never do on its own (credentials, account
creation), and the verification habits this repo was built the hard way to
require.

## What's actually running

| Service | Purpose | Port | Install method |
|---|---|---|---|
| Jellyfin | Movies/TV streaming | 8096 | pacman |
| Audiobookshelf | Audiobook streaming | 3333 | built from source |
| Calibre-Web | Ebook library/reader | 8083 | built from source (Python venv) |
| Immich | Photo/video backup & timeline | 2283 | Docker Compose (the only container in the stack) |
| qBittorrent | Torrent client (MyAnonamouse) | 8080 (WebUI) | pacman |
| Dashboard | Links page + live system stats | 9000 | custom, `python -m http.server` |
| AdGuard Home | Network-wide DNS ad/tracker blocking | — | pacman — **removed from live deploy**, kept as reference |

All reachable over Tailscale only. Background units: ebook auto-import
watcher, health check + email alerting, dashboard stats generator, and
external-HDD auto-recovery.

Full details on each in [`docs/services.md`](docs/services.md).

## Storage

The media library lives on an **external 2 TB USB HDD**, mounted at
`~/Media` — the same path it occupied on internal storage, so no service
config referenced the move. Getting that drive to stay connected required
three separate fixes; see
[`docs/storage-hardware-reliability.md`](docs/storage-hardware-reliability.md)
before attaching external storage anywhere.

## Read these in order

1. [`docs/architecture.md`](docs/architecture.md) — the big picture: how everything fits together
2. [`docs/storage-and-permissions.md`](docs/storage-and-permissions.md) — the `~/Media` layout and why ACLs, not group perms
3. [`docs/security-model.md`](docs/security-model.md) — why Tailscale-only, the firewall, and its gotchas
4. [`docs/services.md`](docs/services.md) — per-service setup notes, ports, config locations
5. [`docs/known-issues-and-decisions.md`](docs/known-issues-and-decisions.md) — hardware limitations, bugs hit, and what changes on new hardware
6. [`docs/storage-hardware-reliability.md`](docs/storage-hardware-reliability.md) — external HDD, the USB disconnect saga, Wi-Fi ceiling
7. [`docs/transcoding.md`](docs/transcoding.md) — the remote-GPU re-encode pipeline **and why not to repeat it on better hardware**
8. [`docs/monitoring-and-alerting.md`](docs/monitoring-and-alerting.md) — health checks and email alerts
9. [`docs/self-healing.md`](docs/self-healing.md) — automatic repair, backups, restore procedures

## Migrating to new hardware

Short version: install Arch, clone this repo, read
`docs/known-issues-and-decisions.md` first (some scripted decisions were
specifically worked around Haswell's limitations and should be revisited on
better hardware — most importantly, hardware video transcoding), then run:

```
./scripts/00-bootstrap.sh
```

It runs each numbered script in order and pauses at manual steps (account
creation, MAM invite, credentials — see below). Read
[`docs/architecture.md`](docs/architecture.md) for what's automated vs. not
before running anything.

### What is NOT scripted, on purpose

Some things are inherently manual, one-time, or tied to accounts only you can
authenticate as. The bootstrap script stops and tells you when to do these:

- MyAnonamouse account creation (needs to be *you*, live interview process)
- Every admin account/password (Jellyfin, Audiobookshelf, Calibre-Web, AdGuard
  Home, qBittorrent WebUI) — each app's own first-run setup, deliberately
  never scripted or hardcoded
- Router DNS configuration (ISP-specific, no CLI access)
- Tailscale login and device registration
- Actually populating the media libraries (that's what the rest of the stack
  is for)

## Repo layout

```
docs/                   architecture + decisions, read these first
scripts/                numbered, idempotent setup scripts
config-templates/       the actual config files in use, as templates
files/                  standalone scripts deployed as-is (e.g. the watcher)
```
