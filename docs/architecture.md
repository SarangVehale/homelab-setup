# Architecture

## Design principles (why things are built this way)

These came out of a lot of back-and-forth, worth preserving so future-you
doesn't re-litigate them:

1. **No Docker where avoidable.** Every service here runs as a native package
   or a from-source build with its own systemd service, not a container.
   This was a deliberate choice — Docker adds a root-owned daemon (its own
   privilege footprint) for services that don't need isolation from each
   other, and native packages integrate better with systemd, ACLs, and
   Arch's own update cycle. AdGuard Home, Jellyfin, qBittorrent are all
   official Arch packages; Audiobookshelf and Calibre-Web are built from
   source because their packaged/AUR versions had dependency-version bugs
   (see `known-issues-and-decisions.md`).

2. **Tailscale-only access, even on the LAN.** This is the one that surprises
   people: every admin UI and every media service is reachable *only* via
   Tailscale (`100.x.x.x` addresses), not the LAN IP — even when you're
   standing right next to the machine on the same WiFi. One consistent
   access boundary regardless of physical location, rather than "LAN is
   trusted, remote needs a VPN." The tradeoff (Tailscale itself becomes a
   dependency for local access) was considered and accepted — see
   `security-model.md`.
   - **Exception**: AdGuard Home's actual DNS port (53) is deliberately LAN +
     Tailscale reachable, because it needs to serve every device on the
     network, including ones that will never run Tailscale (smart TVs, IoT).
     Its *admin UI* (port 80) stays Tailscale-only like everything else.

3. **Firewall as the real enforcement layer, not app-level bind settings.**
   Multiple apps (Jellyfin, AdGuard Home) turned out to have unreliable
   "bind to this specific address" settings — historically flaky in
   Jellyfin's case, and outright ignored by AdGuard Home's DNS listener in
   practice. Rather than trust each app's own binding logic, `nftables`
   rules are the actual access control, matching on Tailscale's stable
   CGNAT IP range (`100.64.0.0/10`) rather than the `tailscale0` interface
   name (see the boot-ordering bug in `known-issues-and-decisions.md` for
   why interface-name matching specifically caused a real outage).

4. **Least-privilege via ACLs, not group permissions, not loosened `700` home
   dir.** Service accounts (jellyfin, audiobookshelf, calibre-web) need to
   reach specific folders under `~/Media` without the home directory itself
   (`700`, dotfiles, SSH keys) becoming reachable. Solved with POSIX ACLs:
   each service user gets bare traverse (`--x`) on `~` itself,
   and scoped read (or read-write, for Calibre-Web specifically) on just its
   own subfolder. See `storage-and-permissions.md`.

5. **Prefer fixing the root cause over working around it**, even when the
   workaround is faster. Concrete example: when qBittorrent's WebUI
   conflicted with `systemd-resolved`'s stub listener on port 53, the fix
   was disabling `DNSStubListener` (root cause), not moving AdGuard Home to
   a different port (workaround). When a Haswell VAAPI driver bug corrupted
   hardware-transcoded video, the fix was offloading to different hardware
   entirely (a second machine's GPU) rather than accepting broken video or
   permanently burning CPU on every playback.

## Network topology

```
                    ┌─────────────────────────────┐
                    │   Tailscale tailnet          │
                    │   100.64.0.0/10              │
                    └───────────────┬───────────────┘
                                    │
        ┌───────────────────────────────────────────────────┐
        │         this machine (Tailscale IP: <TAILSCALE_IP>)│
        │  ┌─────────────────────────────────────────────┐  │
        │  │ nftables: Tailscale-only enforcement          │  │
        │  │  - Jellyfin :8096  (app binds 0.0.0.0,        │  │
        │  │    firewall restricts)                        │  │
        │  │  - AdGuard Home :80 admin (same pattern)      │  │
        │  │  - AdGuard Home :53 DNS (LAN + Tailscale)     │  │
        │  └─────────────────────────────────────────────┘  │
        │                                                     │
        │  Audiobookshelf :3333 ─┐                            │
        │  Calibre-Web    :8083  ├─ bind directly to          │
        │  Dashboard      :9000  ┘  <TAILSCALE_IP>            │
        │                                                     │
        │  qBittorrent WebUI :8080 ─ bind to <TAILSCALE_IP>   │
        │  qBittorrent BT port :11718 ─ local only, no        │
        │                                port forward         │
        └─────────────────────────────────────────────────────┘
                                    │
                         LAN <LAN_SUBNET>
                    (only AdGuard Home DNS :53 reachable here)
```

No port forwarding anywhere — everything remote goes through Tailscale, by
deliberate choice (see `security-model.md` for the port-forwarding
discussion).

## Data flow: how a download becomes a watchable/readable/listenable thing

```
qBittorrent category picked on add            →  routes to the right subfolder
  mam-audio  → ~/Media/audiobooks              →  Audiobookshelf scans directly
  mam-ebook  → ~/Media/ebooks-inbox            →  watcher script → calibredb add
                                                    → ~/Media/ebooks (real library)
  mam-video  → ~/Media/movies                  →  Jellyfin scans directly
  mam-tv     → ~/Media/tv                      →  Jellyfin scans directly
  (no category) → falls back to ebooks-inbox   →  same as mam-ebook (no dead zone)
```

The ebook path is the only one with an extra hop: `calibredb add` **copies**
into an organized library structure rather than moving, so the raw torrent
file stays in `ebooks-inbox` for continued seeding while Calibre-Web serves
the organized copy from `~/Media/ebooks`. See `services.md` for the watcher
script details.

## Service account map

| Service | Runs as | Config location |
|---|---|---|
| qBittorrent | `$USER` (desktop app) | `~/.config/qBittorrent/` |
| Audiobookshelf | `audiobookshelf` (system user) | `/etc/audiobookshelf.env`, `/var/lib/audiobookshelf/` |
| Calibre-Web | `calibre-web` (system user) | in `/opt/calibre-web/` itself (app.db) |
| Jellyfin | `jellyfin` (system user) | `/var/lib/jellyfin/` |
| AdGuard Home | `adguardhome` (system user) | `/etc/adguardhome.yaml` |
| Dashboard | `$USER` (systemd --user) | `/srv/dashboard/` |
| Ebook watcher | `$USER` (systemd --user) | `~/.local/bin/calibre-auto-import.sh` |

All the system-user services were installed via native packages (Jellyfin,
AdGuard Home) or custom systemd units (Audiobookshelf, Calibre-Web) that
create the account via `sysusers.d` — you don't create these accounts
manually, the package/unit does it.

<!-- nav:start -->

---

[← Home](../index.md) · [Storage & permissions →](storage-and-permissions.md)

<!-- nav:end -->
