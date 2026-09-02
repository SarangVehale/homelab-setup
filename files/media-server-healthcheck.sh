#!/usr/bin/env bash
# Self-healing health check.
#
# For each check: verify -> if broken, ATTEMPT REPAIR -> re-verify -> only
# then decide what to tell the human. Email is sent on state change only, so
# a problem that self-heals produces one "HEALED" note rather than a
# PROBLEM/RECOVERED pair, and a stable system stays silent.
#
# Repair attempts are capped (MAX_HEAL_ATTEMPTS consecutive failures) so a
# fundamentally broken service is not restarted every 5 minutes forever - it
# escalates to a plain alert instead.
set -uo pipefail

STATE_DIR="/var/lib/media-server-healthcheck"
STATE_FILE="$STATE_DIR/state"
MAILTO="__ALERT_EMAIL__"
TS_IP="__TAILSCALE_IP__"
MEDIA="__HOME__/Media"
DISK_WARN_PCT=85
MAX_HEAL_ATTEMPTS=3
TAG="healthcheck"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

log() { logger -t "$TAG" "$*"; }

get()  { grep "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }
set_() {
    grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
    echo "$1=$2" >> "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

send_mail() {
    printf 'Subject: %s\nTo: %s\n\n%s\n' "$1" "$MAILTO" "$2" | msmtp "$MAILTO" 2>/dev/null
}

# check <name> <probe_fn> <repair_fn|-> <detail>
#   probe_fn  : returns 0 when healthy
#   repair_fn : attempts a fix; "-" means not auto-repairable
check() {
    local name="$1" probe="$2" repair="$3" detail="$4"
    local prev healed_count now

    prev=$(get "$name")
    healed_count=$(get "${name}.attempts"); healed_count=${healed_count:-0}

    if $probe; then
        now="ok"
        set_ "${name}.attempts" 0
    else
        # Broken. Try to repair, unless we've already tried too many times.
        if [ "$repair" != "-" ] && [ "$healed_count" -lt "$MAX_HEAL_ATTEMPTS" ]; then
            log "$name FAILED - attempting repair (attempt $((healed_count + 1)))"
            $repair >/dev/null 2>&1
            sleep 8
            if $probe; then
                log "$name repaired successfully"
                set_ "${name}.attempts" $((healed_count + 1))
                # Report a self-heal only if it was previously healthy, so a
                # flapping service doesn't spam.
                if [ "$prev" != "healed" ]; then
                    send_mail "[media-server] SELF-HEALED: $name" \
"$name failed a health check and was automatically repaired.

$detail

No action needed - this is informational. If it recurs it will
escalate to a PROBLEM alert after ${MAX_HEAL_ATTEMPTS} attempts.

Host: ${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo unknown)}"
                fi
                set_ "$name" "healed"
                return
            fi
            log "$name repair FAILED"
            set_ "${name}.attempts" $((healed_count + 1))
        fi
        now="bad"
    fi

    if [ "$prev" != "$now" ]; then
        if [ "$now" = "bad" ]; then
            send_mail "[media-server] PROBLEM: $name" \
"$name is failing and could not be automatically repaired.

$detail

Host: ${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo unknown)}"
        else
            send_mail "[media-server] RECOVERED: $name" \
"$name is back to normal.

$detail

Host: ${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo unknown)}"
        fi
    fi
    set_ "$name" "$now"
}

# ---------------------------------------------------------------- probes --

svc_probe() {
    [ "$(systemctl is-active "$1" 2>/dev/null)" = "active" ] || return 1
    [ "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://${TS_IP}:$2/" 2>/dev/null)" != "000" ]
}
svc_repair() { timeout 90 systemctl restart "$1"; }

compose_probe() {
    local dir="$1" port="$2" running total
    [ -f "$dir/docker-compose.yml" ] || return 0
    running=$( (cd "$dir" && timeout 20 docker compose ps --status running --format '{{.Name}}' 2>/dev/null) | wc -l)
    total=$(   (cd "$dir" && timeout 20 docker compose ps --all     --format '{{.Name}}' 2>/dev/null) | wc -l)
    [ "$total" -gt 0 ] && [ "$running" -eq "$total" ] || return 1
    [ "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://${TS_IP}:${port}/" 2>/dev/null)" != "000" ]
}
# Full recreate, not just restart: Docker networking breaks in ways a
# restart does not fix (see known-issues-and-decisions.md).
compose_repair() { (cd "$1" && timeout 60 docker compose down && timeout 120 docker compose up -d); }

# A stale mount passes mountpoint(1) but every read fails - test liveness.
mount_probe()  { mountpoint -q "$MEDIA" && timeout 8 ls "$MEDIA" >/dev/null 2>&1; }
mount_repair() { timeout 120 systemctl start media-hdd-recover.service; }

# The firewall table was once found silently absent from the live kernel
# ruleset while the service reported success. Verify the loaded state.
fw_probe()  { nft list table inet jellyfin_restrict >/dev/null 2>&1; }
fw_repair() { timeout 60 systemctl restart nftables.service; }

ts_probe()  { tailscale status >/dev/null 2>&1; }
ts_repair() { timeout 60 systemctl restart tailscaled.service; }

disk_probe() {
    local pct
    pct=$(df --output=pcent "$1" 2>/dev/null | tail -1 | tr -dc '0-9')
    [ -n "$pct" ] && [ "$pct" -lt "$DISK_WARN_PCT" ]
}

# df on an unmounted mountpoint silently reports the filesystem UNDERNEATH
# it. Checking the media disk that way returned "ok" while actually
# measuring /home - a healthy-looking result about the wrong disk. Only
# report on it when it is genuinely mounted.
media_disk_probe() {
    mountpoint -q "$MEDIA" || return 0   # absent, not unhealthy - mount check covers that
    disk_probe "$MEDIA"
}

# Services whose storage lives on the removable disk must not be "repaired"
# while it is absent: the bind mount would resolve to the empty directory
# under the mountpoint, so writes would silently land on the root
# filesystem instead of the HDD.
media_dependent_probe() {
    if ! mountpoint -q "$MEDIA"; then
        return 0    # storage absent - not this check's problem to fix
    fi
    compose_probe "$@"
}
# Reclaim the safely-reclaimable things before crying about disk space.
# Ordered cheapest/safest first. Everything here is regenerable by
# definition - no service state or media is touched.
disk_repair() {
    # Jellyfin's transcode/trickplay cache. This reached 17GB on a 46GB
    # root once - by far the largest growth source on this machine, and it
    # does not bound itself. Only prune files old enough not to be part of
    # an in-progress stream.
    find /var/cache/jellyfin -type f -mmin +120 -delete 2>/dev/null
    find /var/cache/jellyfin -type d -empty -delete 2>/dev/null

    # Truncated downloads left behind by a previous disk-full event.
    # These must go FIRST: pacman tries to parse every file in the cache as
    # an archive, chokes on the corrupt ones ("Unrecognized archive
    # format"), and then cleans nothing - so it cannot recover from exactly
    # the situation where cleanup matters most. Note these are directories,
    # not files.
    find /var/cache/pacman/pkg -maxdepth 1 \
         \( -name 'download-*' -o -name '*.part' \) -exec rm -rf {} + 2>/dev/null

    # Downloaded package archives. pacman never cleans these; 2566 files
    # totalling 8.2GB had accumulated. Keeps installed versions.
    paccache -rk1 2>/dev/null || pacman -Sc --noconfirm 2>/dev/null

    journalctl --vacuum-size=500M
    # find, not a glob: globs are expanded by the calling shell, so they
    # silently no-op when that shell cannot read the directory.
    find /var/lib/systemd/coredump -mindepth 1 -delete 2>/dev/null
    timeout 120 docker system prune -af --filter "until=168h" 2>/dev/null
    find "__HOME__/.cache" -type f -atime +30 -delete 2>/dev/null
}

# ----------------------------------------------------------------- checks --

check "disk-root"  "disk_probe /"      disk_repair "Root filesystem at $(df --output=pcent / | tail -1 | tr -d ' ')"
check "disk-home"  "disk_probe __HOME__" disk_repair "/home at $(df --output=pcent __HOME__ | tail -1 | tr -d ' ')"
check "disk-media" media_disk_probe -  "Media disk (only checked when mounted)"

check "jellyfin"       "svc_probe jellyfin.service 8096"       "svc_repair jellyfin.service"       "Jellyfin (:8096)"
check "audiobookshelf" "svc_probe audiobookshelf.service 3333" "svc_repair audiobookshelf.service" "Audiobookshelf (:3333)"
check "calibre-web"    "svc_probe calibre-web.service 8083"    "svc_repair calibre-web.service"    "Calibre-Web (:8083)"

# Immich's UPLOAD_LOCATION is on the media HDD, so it is media-dependent.
check "immich" "media_dependent_probe /opt/immich 2283" "compose_repair /opt/immich" "Immich stack (:2283)"

check "media-hdd"  mount_probe mount_repair "Media HDD at $MEDIA"
check "firewall"   fw_probe    fw_repair    "nftables jellyfin_restrict table (Tailscale-only enforcement)"
check "tailscale"  ts_probe    ts_repair    "Tailscale connectivity"

log "run complete"
