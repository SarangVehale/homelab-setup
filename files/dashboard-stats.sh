#!/usr/bin/env bash
# Generates /srv/dashboard/stats.json for the dashboard's live status panel.
# Runs on a systemd --user timer. Writes atomically (temp + mv) so the
# dashboard never reads a half-written file.
set -uo pipefail

OUT="/srv/dashboard/stats.json"
TMP="${OUT}.tmp"

# --- disk ---
root_pct=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
home_pct=$(df --output=pcent /home 2>/dev/null | tail -1 | tr -dc '0-9')
media_pct=$(df --output=pcent __HOME__/Media 2>/dev/null | tail -1 | tr -dc '0-9')
media_free=$(df -h --output=avail __HOME__/Media 2>/dev/null | tail -1 | tr -d ' ')
media_used=$(df -h --output=used __HOME__/Media 2>/dev/null | tail -1 | tr -d ' ')

# --- media HDD health: mounted AND actually responsive, not just present ---
if mountpoint -q __HOME__/Media && timeout 5 ls __HOME__/Media >/dev/null 2>&1; then
    hdd_state="ok"
else
    hdd_state="fault"
fi

# --- uptime / load ---
uptime_str=$(uptime -p 2>/dev/null | sed 's/^up //')
load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
cores=$(nproc 2>/dev/null)

# --- cpu temp ---
temp=$(sensors 2>/dev/null | grep -m1 "Package id 0" | grep -oE '\+[0-9]+\.[0-9]+' | head -1 | tr -d '+')
[ -z "$temp" ] && temp="null"

# --- network: link type + speed, since this drives streaming quality ---
if [ "$(cat /sys/class/net/enp0s25/operstate 2>/dev/null)" = "up" ]; then
    net_type="ethernet"
    net_detail=$(cat /sys/class/net/enp0s25/speed 2>/dev/null)
    [ -n "$net_detail" ] && net_detail="${net_detail} Mbit/s" || net_detail="connected"
else
    net_type="wifi"
    rate=$(iw dev wlan0 link 2>/dev/null | grep "rx bitrate" | grep -oE '[0-9.]+ MBit/s' | head -1)
    sig=$(iw dev wlan0 link 2>/dev/null | grep signal | grep -oE '\-[0-9]+ dBm' | head -1)
    net_detail="${rate:-?} @ ${sig:-?}"
fi

# --- media library counts ---
movies=$(find __HOME__/Media/movies -maxdepth 1 \( -iname '*.mkv' -o -iname '*.mp4' \) 2>/dev/null | wc -l)
music=$(find __HOME__/Media/music -type f 2>/dev/null | wc -l)
books=$(find __HOME__/Media/ebooks -maxdepth 2 -type d 2>/dev/null | wc -l)

cat > "$TMP" <<EOF
{
  "generated": "$(date '+%Y-%m-%d %H:%M:%S')",
  "disk": {
    "root_pct": ${root_pct:-0},
    "home_pct": ${home_pct:-0},
    "media_pct": ${media_pct:-0},
    "media_free": "${media_free:-?}",
    "media_used": "${media_used:-?}"
  },
  "hdd_state": "${hdd_state}",
  "uptime": "${uptime_str:-unknown}",
  "load": "${load:-?}",
  "cores": ${cores:-1},
  "temp": ${temp},
  "net": { "type": "${net_type}", "detail": "${net_detail}" },
  "library": { "movies": ${movies:-0}, "music_tracks": ${music:-0} }
}
EOF

mv "$TMP" "$OUT"
