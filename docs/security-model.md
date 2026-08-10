# Security model

## No port forwarding, ever

Considered early on (for qBittorrent connectability) and explicitly rejected.
Reasoning: forwarding a port genuinely increases attack surface — it exposes
whatever's listening to arbitrary internet hosts, not just peers you choose
to talk to. Torrent clients have had real vulnerabilities in peer-wire
protocol parsing exploited this way.

Practical cost of not forwarding: worse peer connectivity on some torrents
(you can only reach out to already-connectable peers), possibly slower
downloads on rare/small swarms. Judged an acceptable tradeoff for personal
use. If a specific torrent is struggling to meet its seed-time requirement,
that's the trigger to reconsider — narrowly, one port, TCP+UDP, to one
specific IP, not a blanket policy change.

## Tailscale-only, not "LAN is trusted"

Every service here requires Tailscale to reach, even from the same WiFi
network as the server. This was a deliberate, discussed tradeoff:

**Why not just trust the LAN**: a LAN-direct fallback means any device on
the home WiFi — a compromised IoT device, a guest, anyone who has the WiFi
password — can reach these services without being authenticated into the
tailnet at all. That's a real, standing increase in attack surface for a
convenience that's rarely needed (Tailscale's local behavior degrades
gracefully; it doesn't require live contact with its coordination servers
once devices are already connected).

**The one deliberate exception**: AdGuard Home's DNS port (53) is reachable
from the LAN subnet too, because it needs to serve every device on the
network for it to function as a network-wide ad blocker — including devices
that will never run Tailscale (smart TVs, IoT). Its *admin UI* stays
Tailscale-only like everything else; only the DNS resolution port itself is
LAN-reachable.

## The firewall is the actual enforcement layer

Don't trust individual apps' own "bind to this address" settings — verified
empirically that both Jellyfin's `LocalNetworkAddresses` and AdGuard Home's
`dns.bind_hosts` are unreliable in practice (Jellyfin has a documented
history of silently ignoring it across versions; AdGuard Home's DNS listener
was observed explicitly logging a bind to `0.0.0.0` despite a specific
`bind_hosts` config). Both are firewalled with `nftables` instead, matching
Tailscale's stable IP range rather than trusting app-level config.

**Important, hard-learned detail**: match by IP range (`100.64.0.0/10`, the
CGNAT block Tailscale always uses), not by interface name (`iif
"tailscale0"`). Interface-name matching requires the interface to already
exist when `nftables.service` loads the ruleset at boot — but `tailscaled`
connects *after* boot starts, so referencing `tailscale0` by name caused the
**entire ruleset to fail validation and never load at all**, silently
leaving zero firewall protection for hours after every reboot. IP-range
matching has no such dependency. See `known-issues-and-decisions.md` for the
full incident.

Services that bind to the actual Tailscale IP (not just get firewalled)
still need `After=tailscale-online.target` / `Wants=tailscale-online.target`
in their systemd units, since binding to an IP that doesn't exist yet is a
different failure mode than the firewall's interface-name problem. See
`scripts/05-systemd-services.sh`.

## Credentials — never scripted, never hardcoded

Every account (Jellyfin, Audiobookshelf, Calibre-Web, AdGuard Home,
qBittorrent WebUI) is created through that app's own first-run UI, by the
human, not generated or stored by any script here. This is deliberate and
non-negotiable for a repo that might get committed somewhere or shared.

One exception worth knowing about: **Calibre-Web ships a well-known factory
default** (`admin` / `admin123`) if no admin account exists yet — not
something this repo sets, but something to immediately change on first
login, since it's public knowledge, not a secret.

qBittorrent's WebUI is configured (bind address, port) by script, but its
username/password are deliberately left unset in `config-templates/` —
qBittorrent auto-generates a temporary password on first launch (shown once
in its log); go set a real one via Tools → Options → Web UI immediately
after.

## Known-acceptable residual risk

- AdGuard Home's rate-limit protection on Kobo-sync and Basic-Auth/OPDS
  login paths was disabled to fix a Flask-Limiter version incompatibility
  in the AUR package (since resolved by switching to a from-source build —
  see `known-issues-and-decisions.md`). Low practical risk given
  Tailscale-only exposure, but worth knowing if that AUR package is ever
  reintroduced.
- DNS resolution for this machine itself flows through AdGuard Home
  (`systemd-resolved`'s `DNS=` set to `192.168.1.101`), meaning if AdGuard
  Home is ever down, this machine's own DNS resolution breaks too, not just
  other devices'. Accepted tradeoff for "the host benefits from ad-blocking
  too."
