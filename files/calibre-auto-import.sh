#!/usr/bin/env bash
set -euo pipefail

INCOMING="$HOME/Media/ebooks-inbox"
LIBRARY="$HOME/Media/ebooks"

inotifywait -m -r -e close_write -e moved_to --format '%w%f' "$INCOMING" |
while read -r file; do
    case "$file" in
        *.epub|*.mobi|*.azw3|*.pdf|*.cbz|*.cbr|*.fb2|*.txt|*.djvu)
            sleep 2
            calibredb add "$file" --with-library "$LIBRARY" || true
            ;;
    esac
done
