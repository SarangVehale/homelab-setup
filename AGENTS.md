# Agent instructions

This file is for an AI coding agent (Claude Code, Codex, or similar) tasked
with reproducing this setup on new hardware. It's the operating manual —
read this first, before touching `docs/` or `scripts/`.

## What you're actually doing

Standing up a personal media/self-hosting stack on a fresh Arch Linux
machine: qBittorrent, Audiobookshelf, Calibre-Web, Jellyfin, all behind
Tailscale, with a specific security model (Tailscale-only access enforced by
firewall, not app config — see `docs/security-model.md`). AdGuard Home was
part of this stack historically and its docs/scripts are kept for reference,
but it was removed from the live setup — see "AdGuard Home" note below
before deciding whether to include it.

Read [`docs/known-issues-and-decisions.md`](docs/known-issues-and-decisions.md)
in full before running anything. It separates genuinely reusable fixes from
workarounds specific to the *old* machine's hardware (a 2013/2014 Intel
Haswell laptop with no HEVC hardware transcode support). Don't carry
hardware-specific workarounds onto different hardware without re-verifying
they're still needed.

## Execution model

1. Run `scripts/00-bootstrap.sh`. It orchestrates every other numbered
   script in order and **pauses at every step that requires a human** —
   account creation, Tailscale login, router configuration.
2. When it pauses: stop and tell the human what's needed. Do not attempt to
   fill in credentials, click through a web wizard on their behalf, or
   guess at values for things like admin passwords. This is a hard rule,
   not a suggestion — see "Never do this" below.
3. After each script, verify the result yourself before moving to the next
   one — see "Verification discipline" below. A script exiting 0 is not
   proof the thing it configured actually works.

## Never do this

- Never create, guess, or fill in a password/credential for any service
  (Jellyfin, Audiobookshelf, Calibre-Web, qBittorrent WebUI). Every account
  is created by the human through that app's own first-run UI.
- Never submit an account application, join an interview, or otherwise act
  *as* the human on any external service (this stack originally paired with
  a private tracker requiring a live identity interview — that process
  cannot be delegated to an agent under any circumstances).
- Never `rm`/`mv` a file a torrent client might be actively tracking
  without first checking `pgrep -x qbittorrent` and preferring the client's
  own file-management features (e.g. "Set location") over a raw filesystem
  operation. Breaking a client's internal state this way can silently harm
  the user's standing on a tracker with seeding requirements.
- Never edit an app's config file while that app is running unless you've
  confirmed the app reads it live rather than overwriting it on its own
  exit/save cycle. qBittorrent specifically clobbers out-of-band edits this
  way — check `pgrep` first, every time.

## Verification discipline (the actual hard-won lesson of this repo)

This setup was built by iterating against a series of things that *looked*
fine and weren't. Don't repeat that. Specifically:

- **"systemctl is-active" is not verification.** Several services in this
  stack reported "active" while silently misbehaving (Jellyfin bound to the
  wrong address, AdGuard Home ignoring its own bind config, a firewall
  ruleset that failed to load at boot with zero indication in `systemctl
  status`). Always additionally check: `ss -tlnp` for what's *actually*
  listening where, and the last 15-20 lines of `journalctl -u <service>`
  for what it *actually* logged on startup, not just its exit code.
- **Don't trust an app's own "bind to this address" setting.** Verified
  empirically in this repo that both Jellyfin's and AdGuard Home's
  address-restriction settings were silently ignored by the running
  process. If a security boundary matters, enforce it at the firewall
  (`nftables`) and verify the *loaded ruleset* (`nft list table ...`), not
  just the config file you wrote.
- **Match firewall rules to Tailscale by IP range, not interface name.**
  `nftables.service` starts before `tailscaled` connects at boot. A rule
  referencing `iif "tailscale0"` fails validation when that interface
  doesn't exist yet — and critically, **the entire ruleset in that file
  fails to load, not just that one rule**, silently leaving zero firewall
  protection until the next manual reload. Use `ip saddr 100.64.0.0/10`
  (Tailscale's fixed CGNAT range) instead — no such dependency.
- **When a rolling-release package is broken by dependency drift, check if
  building from upstream source fixes it before hand-patching.** Both
  Audiobookshelf and Calibre-Web hit exactly this (Arch's system packages
  had moved ahead of what the packaged app's pinned dependencies
  supported); building from each project's own `master` branch picked up
  already-fixed dependency constraints in both cases.
- **Test the actual end-to-end behavior, not just that a process starts.**
  The ebook auto-import pipeline in this repo was verified by literally
  dropping a real file into the watched folder and confirming an organized
  copy appeared in the library — not by trusting that the watcher service
  showed "active."
- **Presence is not liveness.** `mountpoint -q` returns true for a *dead*
  mount left behind by a disconnected drive. Both the auto-recovery script
  and the health check here originally used exactly that test and both
  reported "healthy" during a live outage. Any check for a resource being
  available must actually touch it (`timeout 5 ls "$MP"`), not just confirm
  an entry exists.
- **A job that finishes impossibly fast has failed.** A video transcode
  that "completed" in 30 seconds for a 2-hour film had actually errored out
  on a truncated input and written a zero-byte file, and the surrounding
  script happily continued. Check exit codes on every step of a pipeline,
  and sanity-check output against a known property of the input (duration,
  size, checksum) rather than just existence.
- **When a setting you applied reverts, look for another daemon writing it**
  before assuming your config is wrong. A udev rule here was silently
  overridden by TLP's own USB power rules. Note also that `udevadm test` is
  a **dry run** — it confirms your rule matches and would write a value,
  and proves nothing about who writes last.
- **Don't cry wolf.** Several times during this setup's construction, a
  "problem" was announced before it was verified — a normal `Type=oneshot`
  service showing `inactive (dead)` mistaken for a dead firewall, standard
  file permissions mistaken for a missing ACL. Confirm a fault is real
  before escalating it to the human, and say plainly when a previous
  conclusion was wrong.

## Redaction discipline

If any of this repo's contents are going to leave the local machine (pushed
to a remote, shared, etc.), **do not include real IP addresses, hostnames,
or usernames**. Every config template in this repo uses placeholder tokens
(`__TAILSCALE_IP__`, `__LAN_SUBNET__`, `__HOME__`) precisely so it's safe to
publish — the scripts substitute real values at deploy time via
auto-detection (`tailscale ip -4`, default-route inspection) or explicit
environment variables. If you add new config templates, follow the same
pattern rather than hardcoding real values, even temporarily.

## AdGuard Home — status note

AdGuard Home's docs (`docs/services.md`, sections of `docs/security-model.md`
and `docs/known-issues-and-decisions.md`) and its scripts/config templates
are kept in this repo as a reference for a *working* setup, but it was
**removed from the live deployment** after a debugging session where its
DNS failures were initially (incorrectly) suspected of causing periodic
network drops — the actual root cause turned out to be an unrelated WiFi
reauthentication pattern, unresolved at time of writing. If you reintroduce
AdGuard Home on new hardware: it's a legitimate, working piece of this
stack: nothing about it was actually broken. Follow `scripts/08-dns-adguard.sh`
as before, and additionally remember to clean up two things if it's ever
removed again: the Tailscale tailnet's DNS nameserver entry
(`login.tailscale.com/admin/dns`) and the router's DHCP-assigned DNS server
— both are manual, non-scriptable, external-to-this-machine settings that
silently break for other devices if left pointing at a service that no
longer exists.

## Where to go next

- [`docs/architecture.md`](docs/architecture.md) — the system as a whole
- [`docs/services.md`](docs/services.md) — per-service specifics
- [`scripts/`](scripts/) — the actual automation, numbered and idempotent
- [`docs/known-issues-and-decisions.md`](docs/known-issues-and-decisions.md) — read before you start, not after something breaks
