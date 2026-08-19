#!/usr/bin/env bash
# Checks disk space, service health, the HDD mount, Docker compose stacks, and
# Tailscale — emails only on state CHANGE (bad->good or good->bad), never
# repeats the same alert every run.
set -uo pipefail

STATE_DIR="/var/lib/media-server-healthcheck"
STATE_FILE="$STATE_DIR/state"
MAILTO="__ALERT_EMAIL__"
DISK_WARN_PCT=90

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

get_prev() {
    grep "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2
}

set_state() {
    grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
    echo "$1=$2" >> "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

send_mail() {
    local subject="$1"
    local body="$2"
    printf 'Subject: %s\nTo: %s\n\n%s\n' "$subject" "$MAILTO" "$body" | msmtp "$MAILTO"
}

# check <name> <ok:0/1> <detail>
check() {
    local name="$1" ok="$2" detail="$3"
    local prev
    prev=$(get_prev "$name")
    local now
    if [ "$ok" -eq 1 ]; then now="ok"; else now="bad"; fi

    if [ "$prev" != "$now" ]; then
        if [ "$now" = "bad" ]; then
            send_mail "[media-server] PROBLEM: $name" "$name is failing.

$detail

Host: sarang-hp"
        else
            send_mail "[media-server] RECOVERED: $name" "$name is back to normal.

$detail

Host: sarang-hp"
        fi
    fi
    set_state "$name" "$now"
}

# --- disk space ---
for target in /home __HOME__/Media; do
    pct=$(df --output=pcent "$target" 2>/dev/null | tail -1 | tr -dc '0-9')
    label="disk-$(echo "$target" | tr '/' '_')"
    if [ -z "$pct" ]; then
        check "$label" 0 "Could not read disk usage for $target"
    elif [ "$pct" -ge "$DISK_WARN_PCT" ]; then
        check "$label" 0 "$target is ${pct}% full (warn threshold ${DISK_WARN_PCT}%)"
    else
        check "$label" 1 "$target is ${pct}% full"
    fi
done

# --- systemd services: systemd state AND actual HTTP response ---
declare -A SERVICE_PORTS=(
    [jellyfin.service]=8096
    [audiobookshelf.service]=3333
    [calibre-web.service]=8083
)
for svc in "${!SERVICE_PORTS[@]}"; do
    port="${SERVICE_PORTS[$svc]}"
    active=$(systemctl is-active "$svc" 2>/dev/null)
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "http://__TAILSCALE_IP__:${port}/" 2>/dev/null)
    if [ "$active" = "active" ] && [ "$http_code" != "000" ]; then
        check "$svc" 1 "systemd: $active, http: $http_code"
    else
        check "$svc" 0 "systemd: $active, http: $http_code"
    fi
done

# --- docker compose stacks: every container running AND actual HTTP response ---
declare -A COMPOSE_CHECKS=(
    [immich]="/opt/immich:2283"
)
for name in "${!COMPOSE_CHECKS[@]}"; do
    dir="${COMPOSE_CHECKS[$name]%%:*}"
    port="${COMPOSE_CHECKS[$name]##*:}"
    if [ -f "$dir/docker-compose.yml" ]; then
        running=$( (cd "$dir" && docker compose ps --status running --format '{{.Name}}' 2>/dev/null) | wc -l)
        total=$( (cd "$dir" && docker compose ps --all --format '{{.Name}}' 2>/dev/null) | wc -l)
        http_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "http://__TAILSCALE_IP__:${port}/" 2>/dev/null)
        if [ "$total" -gt 0 ] && [ "$running" -eq "$total" ] && [ "$http_code" != "000" ]; then
            check "docker-$name" 1 "containers: $running/$total running, http: $http_code"
        else
            check "docker-$name" 0 "containers: $running/$total running, http: $http_code"
        fi
    fi
done

# --- HDD mount ---
# mountpoint -q alone isn't enough: a dead/disconnected device can leave a
# stale mount behind (still "present" per the mount table) that reads fail
# on. Verify it's actually alive by touching it.
if mountpoint -q __HOME__/Media && timeout 5 ls __HOME__/Media >/dev/null 2>&1; then
    check "media-hdd-mount" 1 "Mounted and responsive"
else
    check "media-hdd-mount" 0 "__HOME__/Media is NOT mounted or is unresponsive (stale/dead mount)"
fi

# --- tailscale ---
if tailscale status >/dev/null 2>&1; then
    check "tailscale" 1 "Up"
else
    check "tailscale" 0 "tailscale status failed"
fi
