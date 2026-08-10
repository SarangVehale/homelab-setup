# Per-service notes

## qBittorrent

- Installed via pacman (`qbittorrent`), runs as `sarang` (desktop app, not a
  system service) — starts via `~/.config/autostart/qbittorrent.desktop`
  (XDG autostart, picked up by `dex` in this i3 config).
- Private-tracker settings: **DHT, PEX, and LSD all disabled** — mandatory
  for MyAnonamouse and most private trackers; leaving them on risks a ban.
- Categories route downloads by type — see `architecture.md` for the data
  flow diagram. Config: `config-templates/qbittorrent-categories.json`.
- Default save path and temp path both point into `~/Media` — no
  category selected still lands somewhere the pipeline picks up (see
  `storage-and-permissions.md` for why this matters).
- WebUI enabled, bound to the Tailscale IP, port 8080. Credentials
  deliberately not scripted — see `security-model.md`.
- **Gotcha**: qBittorrent holds its config in memory while running and
  overwrites the file on exit/save. Always check `pgrep -x qbittorrent`
  before editing `qBittorrent.conf` or `categories.json` directly — editing
  while it's running risks the app silently clobbering your changes.
- Behavior settings: `CloseToTray`, `MinimizeToTray`, `StartMinimized` all
  enabled — seeds continuously in the background, toggle via the tray
  icon's Pause All/Resume All rather than closing the app.

## Audiobookshelf

- **Built from source**, not the Arch package — see
  `known-issues-and-decisions.md` for why (Node 26 compatibility + a
  never-compiled SQLite binding in the packaged version).
- Source lives in `/opt/audiobookshelf`, built with `npm run client && npm
  install` (Node's own package manager, matched to the *system* Node
  version, not any user-level nvm install — the systemd service uses
  `/usr/bin/node` specifically).
- Config/metadata/backups persist in `/var/lib/audiobookshelf/` — this
  survived the package→source migration untouched, reused directly.
- Library must be pointed at `~/Media/audiobooks` through its own web UI
  (Settings → Libraries) — **known past bug**: it was once misconfigured to
  scan `/home/sarang` directly (the whole home dir), which just spammed
  `EACCES` errors since the ACL only grants traverse there. If audiobooks
  aren't showing up, check this first.
- Systemd service: `config-templates/systemd/audiobookshelf.service`.

## Calibre-Web

- **Built from source in a dedicated Python venv**, not the AUR package —
  see `known-issues-and-decisions.md` (system `python-flask-limiter` was
  incompatible with the AUR package's pinned version range; a venv gives it
  fully isolated dependencies, sidestepping the whole class of problem).
- Source + venv both live in `/opt/calibre-web`.
- Library path: `~/Media/ebooks` (the real, organized library — not
  `ebooks-inbox`). Set via Admin → Basic Configuration on first login.
- Default login is the well-known `admin`/`admin123` — change immediately.
- Useful once set up: enable OPDS (`http://<tailscale-ip>:8083/opds`) for
  e-reader apps (KOReader, Moon+ Reader) to browse/download directly.
- Systemd service: `config-templates/systemd/calibre-web.service`.

## Jellyfin

- Installed via pacman (`jellyfin-server`, `jellyfin-web`,
  `jellyfin-ffmpeg`) — officially packaged, no source build needed.
- Libraries: `~/Media/movies` (type: Movies), `~/Media/tv` (type: Shows) —
  set through its own setup wizard / Dashboard → Libraries.
- Binds to `0.0.0.0:8096` by default (its own address-restriction setting
  is unreliable — see `security-model.md`); actual access control is the
  `nftables` rule, not the app config.
- **Hardware transcoding**: currently configured for VAAPI on this
  Haswell's iGPU, but with a critical caveat — see
  `known-issues-and-decisions.md` before touching this on new hardware.
  Short version: hardware encode works for H.264 sources, but crashes with
  a driver bug (`SIGABRT`, i965 driver assertion failure) specifically on
  HEVC-source → H.264-output transcodes. Only H.264 hardware decode is
  enabled; HEVC decode is deliberately left off.

## AdGuard Home

- Installed via pacman (`adguardhome`), officially packaged.
- Config: `/etc/adguardhome.yaml` — persistent config isn't written until
  the setup wizard is completed once through the browser (first launch is
  unconfigured, listens on `0.0.0.0:3000` for the wizard itself).
- DNS (port 53) bound to `192.168.1.101` + `100.100.208.10` in config —
  **but this setting is not actually respected by the DNS listener in
  practice** (observed binding `0.0.0.0`/`[::]` regardless). The `nftables`
  rule is what actually restricts it. See `security-model.md`.
- Admin UI (port 80) has the same theoretical-vs-actual binding gap;
  same firewall-is-the-real-control caveat applies.
- Blocklists configured: AdGuard DNS filter, AdAway, OISD Big, Steven
  Black's Unified Hosts, Peter Lowe's list — five layered lists, chosen to
  avoid excessive redundant overlap while covering ads/trackers/malware
  broadly. See `config-templates/` for the exact filter URLs.
- **Port 53 conflicts with `systemd-resolved`'s stub listener** on a
  default Arch install — fixed by setting `DNSStubListener=no` in
  `/etc/systemd/resolved.conf`, not by moving AdGuard Home to a different
  port. `nss-resolve` in `/etc/nsswitch.conf` means most local programs
  don't even touch the stub port directly, so this is safe.
- This machine's own DNS resolution is pointed at AdGuard Home too, via
  `DNS=192.168.1.101` in `resolved.conf` — the host gets ad-blocking
  benefits, not just other network devices.
- **Router configuration required** (not scriptable — ISP-specific web UI):
  point the router's DHCP-assigned DNS server at `192.168.1.101` for
  network-wide coverage of non-Tailscale devices. Also register AdGuard
  Home as the tailnet's global nameserver
  (`login.tailscale.com/admin/dns` → Add Nameserver →
  `100.100.208.10` → Override local DNS) for automatic coverage on every
  Tailscale-connected device with zero per-device config.

## Dashboard

- Not a real app — a single static HTML file
  (`config-templates/dashboard/index.html`) served by
  `python3 -m http.server`, deliberately, instead of installing something
  like Homarr/Homepage. Reasoning: those are Docker-first or Node-based
  stacks for something that's fundamentally just link cards to services
  already running — not worth the extra dependency surface.
- Runs as a `systemd --user` service (`dashboard.service`), bound to the
  Tailscale IP, port 9000.

## Ebook auto-import watcher

- `files/calibre-auto-import.sh` — watches `~/Media/ebooks-inbox` with
  `inotifywait`, runs `calibredb add` on any new ebook file, which copies
  an organized version into `~/Media/ebooks` while leaving the original
  in place for continued seeding.
- Runs as a `systemd --user` service
  (`config-templates/systemd/calibre-auto-import.service`).
- Requires the `calibre` package (for `calibredb`) and `inotify-tools`.

## Everything persists across reboots

All system services are `enable`d (not just started); the two
`systemd --user` services rely on `loginctl enable-linger sarang` being set
(check with `loginctl show-user sarang -p Linger` — should say `yes`) so
they run even without an active login session.
