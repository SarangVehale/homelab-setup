#!/usr/bin/env bash
# nftables (re)starting can wipe Docker's dynamically-inserted iptables rules
# for already-existing bridge networks (embedded DNS, NAT) without Docker
# noticing - restarting docker.service alone does NOT fix this, only fully
# recreating each compose network does (docker compose down && up).
# Runs automatically after every nftables (re)start.
#
# Robustness notes:
# - Discovers ALL compose projects under /opt/*/docker-compose.yml rather
#   than hardcoding one path, so this keeps working as more services are added.
# - Waits for the Docker daemon's API to actually respond (not just
#   "systemctl is-active", which can be true before the socket is ready)
#   before attempting anything, with a bounded retry instead of racing it.
# - Verifies every container is actually "running" after recreation and
#   logs a clear failure if not, rather than assuming down+up succeeded.
set -uo pipefail
TAG="docker-network-fix"

# Bounded wait for the Docker API itself, not just the systemd unit state.
for i in $(seq 1 15); do
    if docker info >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
if ! docker info >/dev/null 2>&1; then
    logger -t "$TAG" "docker not ready after 30s wait, skipping (nothing to fix if it's not running)"
    exit 0
fi

FOUND_ANY=0
for compose_file in /opt/*/docker-compose.yml; do
    [ -f "$compose_file" ] || continue
    FOUND_ANY=1
    dir=$(dirname "$compose_file")
    name=$(basename "$dir")

    logger -t "$TAG" "recreating network for $name ($compose_file)"
    ( cd "$dir" && docker compose down ) 2>&1 | logger -t "$TAG"
    ( cd "$dir" && docker compose up -d ) 2>&1 | logger -t "$TAG"

    sleep 5
    NOT_RUNNING=$( (cd "$dir" && docker compose ps --status running --format '{{.Name}}') | wc -l)
    TOTAL=$( (cd "$dir" && docker compose ps --all --format '{{.Name}}') | wc -l)
    if [ "$NOT_RUNNING" -lt "$TOTAL" ]; then
        logger -t "$TAG" "WARNING: $name has $((TOTAL - NOT_RUNNING)) container(s) not running after recreate - needs manual check"
    else
        logger -t "$TAG" "$name recreated successfully ($TOTAL/$TOTAL containers running)"
    fi
done

if [ "$FOUND_ANY" -eq 0 ]; then
    logger -t "$TAG" "no compose projects found under /opt/*/docker-compose.yml, nothing to do"
fi
