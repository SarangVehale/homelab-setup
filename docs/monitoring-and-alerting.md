# Monitoring & alerting

A single health-check script on a systemd timer, emailing **only on state
change**. No Prometheus/Grafana — the goal is knowing when something breaks,
not dashboards nobody reads.

## What it checks

`media-server-healthcheck.sh`, every 5 minutes:

| Check | Passes when |
|---|---|
| Disk space (`/home`, `~/Media`) | Below 90 % |
| Jellyfin, Audiobookshelf, Calibre-Web, Navidrome | `systemctl is-active` **and** the port answers HTTP |
| Immich (Docker) | Every container running **and** the port answers HTTP |
| Media HDD mount | Mounted **and** responsive to a real read |
| Tailscale | `tailscale status` succeeds |

Two deliberate design points, both learned the hard way:

**Never trust `systemctl is-active` alone.** Multiple services in this stack
have reported `active` while completely failing to serve. Every service
check therefore pairs the unit state with a real HTTP request.

**Never trust `mountpoint -q` alone.** A disconnected drive leaves a stale
mount that passes that test while every read fails — see
[`storage-hardware-reliability.md`](storage-hardware-reliability.md). The
mount check does a real `ls` behind a `timeout`.

## State-change-only alerting

State lives in `/var/lib/media-server-healthcheck/state` as `name=ok|bad`.
Mail is sent **only when a check's state differs from last run**, so a
service that stays down produces exactly one PROBLEM mail, then silence,
then one RECOVERED mail. A 5-minute timer would otherwise generate 288
mails/day per broken check and get filtered as noise.

## Mail transport

`msmtp` with Gmail SMTP. Requires a Google **App Password** (regular
passwords are rejected for SMTP).

```
# /etc/msmtprc  — chmod 600, root-owned
account gmail
host smtp.gmail.com
port 587
from <address>
auth on
user <address>
password <app-password>
tls on
tls_starttls on

account default : gmail
```

This is the **only** file in the setup holding a real plaintext credential.
`600 root:root` is mandatory, and it must never be committed.

## Dashboard live stats

Separately, `dashboard-stats.sh` runs on a **1-minute** user timer and
writes `/srv/dashboard/stats.json`, which the dashboard page fetches for its
system panel (disk, load, CPU temp, network link type/speed, uptime, HDD
health). Written atomically via temp-file + `mv` so the page never reads a
half-written file.

The network tile reports Ethernet vs Wi-Fi **including link rate** — on this
hardware that is the single most useful number for diagnosing playback
problems, since the Wi-Fi card is the binding constraint.

## Adding a check

Append to the relevant section of the script using the existing `check`
helper:

```bash
check "<name>" <1-if-ok-else-0> "<detail shown in the mail>"
```

State handling and alert deduplication are automatic.
