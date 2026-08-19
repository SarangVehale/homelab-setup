---
title: Home media/self-hosting setup
---

# Home media/self-hosting setup

Documentation and setup scripts for a personal media/self-hosting stack —
Jellyfin, Audiobookshelf, Calibre-Web, Immich, qBittorrent, all
behind Tailscale — built specifically to be **reproducible on new hardware**
without re-deriving every decision from scratch.

Running on a 2013/2014 Intel Haswell laptop with an external USB HDD, which
is why a fair amount of this repo is about working within (and documenting)
real hardware limits rather than pretending they aren't there.

Full narrative overview: [README](README.md). **Using an AI agent to rebuild
this? Start with [AGENTS.md](AGENTS.md)** instead of the docs below — it's
the operating manual, not a reference doc.

## Documentation

- [Architecture](docs/architecture.md) — design principles, network topology, data flow, service account map
- [Storage & permissions](docs/storage-and-permissions.md) — the `~/Media` layout and the ACL trick that avoids loosening `700` on the home directory
- [Security model](docs/security-model.md) — why Tailscale-only even on the LAN, why the firewall (not app config) is the real enforcement layer, the port-forwarding decision
- [Services](docs/services.md) — per-service setup notes, ports, config locations, gotchas
- [Known issues & decisions](docs/known-issues-and-decisions.md) — **read this before migrating to new hardware.** Separates genuinely reusable fixes from hardware-specific workarounds (the old Haswell iGPU's HEVC transcoding limitations especially)
- [Storage & hardware reliability](docs/storage-hardware-reliability.md) — external USB HDD migration, and the three separate root causes behind its disconnects (UAS driver, autosuspend, TLP). Also the Wi-Fi hardware ceiling
- [Transcoding](docs/transcoding.md) — the remote-GPU batch re-encode pipeline, the bugs hit, and **why it's a workaround not to repeat on capable hardware**
- [Monitoring & alerting](docs/monitoring-and-alerting.md) — health checks that don't trust `systemctl is-active`, and state-change-only email alerts
- [Self-healing](docs/self-healing.md) — what repairs itself automatically, nightly state backups, and an honest list of what still needs a human

## Setup scripts

Numbered, idempotent, orchestrated by [`scripts/00-bootstrap.sh`](scripts/00-bootstrap.sh),
which pauses at every step that's inherently manual — account creation,
Tailscale login, router configuration. No credentials are scripted or stored
anywhere in this repo.

| Script | Does |
|---|---|
| [`01-packages.sh`](scripts/01-packages.sh) | Native package installs (qBittorrent, Jellyfin, AdGuard Home, build tools) |
| [`02-storage.sh`](scripts/02-storage.sh) | `~/Media` layout + scoped ACL grants |
| [`03-build-audiobookshelf.sh`](scripts/03-build-audiobookshelf.sh) | Audiobookshelf from source (Arch package has known bugs — see known-issues doc) |
| [`04-build-calibre-web.sh`](scripts/04-build-calibre-web.sh) | Calibre-Web from source, isolated venv |
| [`05-systemd-services.sh`](scripts/05-systemd-services.sh) | Service accounts, unit files, the `tailscale-online.target` boot-ordering fix |
| [`06-firewall.sh`](scripts/06-firewall.sh) | `nftables` — the actual Tailscale-only enforcement layer |
| [`07-qbittorrent.sh`](scripts/07-qbittorrent.sh) | Private-tracker settings, categories, WebUI binding |
| [`08-dns-adguard.sh`](scripts/08-dns-adguard.sh) | `systemd-resolved` port-53 conflict fix, AdGuard Home wiring (kept for reference — removed from the live deployment, see AGENTS.md) |
| [`09-watcher.sh`](scripts/09-watcher.sh) | Ebook auto-import watcher |
| [`10-dashboard.sh`](scripts/10-dashboard.sh) | Links dashboard + live system stats panel |
| [`11-transcode-pipeline.sh`](scripts/11-transcode-pipeline.sh) | Batch HEVC→H.264 re-encode, offloaded to a remote GPU (overlaps transfer/transcode/pull-back) |
| [`12-self-healing.sh`](scripts/12-self-healing.sh) | Auto-remediating health check, nightly state backups, journal cap, restart hardening |

## Config templates

Real, working configs used as templates with placeholder tokens
(`__TAILSCALE_IP__`, `__LAN_SUBNET__`, etc.) substituted at deploy time by
the scripts above — see [`config-templates/`](config-templates/) and
[`files/`](files/).

---

*Private infrastructure details (IP addresses, hostnames) have been replaced
with placeholders throughout — this repo documents the **approach**, not a
live target.*
