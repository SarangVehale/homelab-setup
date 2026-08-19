#!/usr/bin/env bash
set -uo pipefail

MOVIES_DIR="__HOME__/Media/movies"
OUT_DIR="__HOME__/Media/movies-transcoded-staging"
LOG="__WORK_DIR__/pipeline.log"
mkdir -p "$OUT_DIR"
: > "$LOG"

log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }

# name|source filename|hdr(0/1)
QUEUE=(
  "dunkirk|Dunkirk.2017.1080p.10bit.BluRay.6CH.x265.HEVC-PSA.mkv|0"
  "backrooms|Backrooms.2026.2160p.iT.WEB-DL.English.DDP5.1.Atmos.H.265-4k.mkv|0"
  "flow|Flow.2024.2160p.AMZN.WEB-DL.DDP5.1.H.265-FLUX.mkv|0"
  "inception|Inception.2010.4K-2160p.SDR.10Bit.mkv|0"
  "oppenheimer|Oppenheimer.2023.IMAX.1080p.BluRay.x265.mkv|0"
  "devil-wears-prada-2|The.Devil.Wears.Prada.2.2026.1080p.BluRay.HIN-ENG.x265.ESub.mkv|0"
  "lifehack|LifeHack.2025.2160p.NOW.WEB-DL.DDP5.1.H.265-DUDU.mkv|0"
  "disclosure-day|Disclosure.Day.2026.1080p.10bit.WEB-DL.HIN-ENG.x265.mkv|0"
  "la-la-land|La La Land 2016 1080p BluRay x265 10bit.mkv|0"
  "project-hail-mary|Project.Hail.Mary.2026.2160p.WEBrip.h265.Dual YG.mkv|1"
  "obsession|Obsession (2026) 2160p 10Bit HDR DV MA WEBRip HEVC x265 [Hindi AMZN DDP 5.1 + English DDP Atmos 5.1].mkv|1"
)

SDR_VF="format=nv12"
HDR_VF="hwdownload,format=p010le,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

transfer_to_rog() {
    local src="$1" dest="$2"
    rsync -a "$MOVIES_DIR/$src" "rog:~/transcode-work/$dest" >> "$LOG" 2>&1
}

pull_from_rog() {
    local src="$1" dest="$2"
    rsync -a "rog:~/transcode-work/$src" "$OUT_DIR/$dest" >> "$LOG" 2>&1
}

start_transcode() {
    local slug="$1" hdr="$2"
    local vf="$SDR_VF"
    local bitrate_args="-b:v 6M -maxrate 8M -bufsize 12M"
    if [ "$hdr" = "1" ]; then
        vf="$HDR_VF"
        bitrate_args="-b:v 8M -maxrate 10M -bufsize 16M"
    fi
    ssh rog "cd ~/transcode-work && nohup ffmpeg -y -hwaccel cuda -i ${slug}-src.mkv -vf '$vf' -c:v h264_nvenc -preset p5 $bitrate_args -c:a copy ${slug}-h264.mp4 > ${slug}-encode.log 2>&1 < /dev/null & disown; echo STARTED" >> "$LOG" 2>&1
}

wait_for_transcode() {
    local slug="$1"
    while true; do
        sleep 30
        if ! ssh rog "pgrep -f ${slug}-src.mkv" >/dev/null 2>&1; then
            break
        fi
    done
}

# --- Prelude: fold in the two files already in flight from before this
# script existed, so nothing gets duplicated or conflicts with them. ---

log "=== Prelude: pulling back already-finished sam-bahadur (fire and forget) ==="
( pull_from_rog "sam-bahadur-h264.mp4" "sam-bahadur-h264.mp4" \
  && ssh rog "rm -f ~/transcode-work/sam-bahadur-src.mkv ~/transcode-work/sam-bahadur-h264.mp4" >> "$LOG" 2>&1 \
  && log "=== Prelude: sam-bahadur pulled back and cleaned up on rog ===" ) &

log "=== Prelude: waiting for already-running maa-inti-bangaram transfer to finish ==="
while ssh rog "test -f ~/transcode-work/.maa-inti-bangaram-src.mkv.*" 2>/dev/null; do
    sleep 15
done
log "=== Prelude: maa-inti-bangaram transfer confirmed complete ==="

log "=== Prelude: starting maa-inti-bangaram transcode (SDR) ==="
start_transcode "maa-inti-bangaram" "0"

# While that transcodes, start transferring the first file of the main queue
first_slug="${QUEUE[0]%%|*}"
first_rest="${QUEUE[0]#*|}"
first_src="${first_rest%%|*}"
log "--- In parallel: transferring first queue file $first_src ---"
( transfer_to_rog "$first_src" "${first_slug}-src.mkv"; log "--- Transfer of $first_src complete ---" ) &
FIRST_TRANSFER_PID=$!

wait_for_transcode "maa-inti-bangaram"
log "=== Prelude: maa-inti-bangaram transcode complete ==="
( pull_from_rog "maa-inti-bangaram-h264.mp4" "maa-inti-bangaram-h264.mp4" \
  && ssh rog "rm -f ~/transcode-work/maa-inti-bangaram-src.mkv" >> "$LOG" 2>&1 \
  && log "=== Prelude: maa-inti-bangaram pulled back and cleaned up ===" ) &

wait "$FIRST_TRANSFER_PID" 2>/dev/null || true
log "=== Prelude complete, entering main queue ==="

for i in "${!QUEUE[@]}"; do
    entry="${QUEUE[$i]}"
    slug="${entry%%|*}"
    rest="${entry#*|}"
    src="${rest%%|*}"
    hdr="${rest##*|}"

    log "=== Starting transcode: $src (slug=$slug hdr=$hdr) ==="
    start_transcode "$slug" "$hdr"

    # While this transcodes, start transferring the NEXT file in parallel
    next_idx=$((i + 1))
    if [ "$next_idx" -lt "${#QUEUE[@]}" ]; then
        next_entry="${QUEUE[$next_idx]}"
        next_slug="${next_entry%%|*}"
        next_rest="${next_entry#*|}"
        next_src="${next_rest%%|*}"
        log "--- In parallel: transferring next file $next_src ---"
        ( transfer_to_rog "$next_src" "${next_slug}-src.mkv"; log "--- Transfer of $next_src complete ---" ) &
        TRANSFER_PID=$!
    fi

    wait_for_transcode "$slug"
    log "=== Transcode complete: $src ==="

    # Pull the finished file back while the next transfer (if any) continues
    ( pull_from_rog "${slug}-h264.mp4" "${slug}-h264.mp4"; log "=== Pulled back: $src ===" ) &
    PULLBACK_PID=$!

    # Make sure this iteration's parallel transfer finishes before the loop
    # moves on to needing that file for its own transcode
    if [ -n "${TRANSFER_PID:-}" ]; then
        wait "$TRANSFER_PID" 2>/dev/null || true
    fi
    wait "$PULLBACK_PID" 2>/dev/null || true

    # cleanup source on rog to save space, keep the encoded output there
    # until confirmed pulled back successfully
    if [ -f "$OUT_DIR/${slug}-h264.mp4" ]; then
        ssh rog "rm -f ~/transcode-work/${slug}-src.mkv" >> "$LOG" 2>&1
    fi
done

log "=== PIPELINE COMPLETE - all files processed, outputs in $OUT_DIR ==="
