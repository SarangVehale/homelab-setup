#!/usr/bin/env bash
TAG="media-hdd-disconnect"
logger -t "$TAG" "Drive disconnected, stopping dependent services"
systemctl stop jellyfin.service audiobookshelf.service calibre-web.service
logger -t "$TAG" "Services stopped"
