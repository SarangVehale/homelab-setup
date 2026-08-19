# Transcoding: offloading the library to a remote GPU

Documents the batch re-encode of the movie library from HEVC to H.264 using
a second machine's GPU, why it was done, the bugs hit, and — importantly —
**the cost it carried that was not obvious up front**.

## Why re-encode at all

This machine's Haswell iGPU cannot hardware-transcode HEVC (see
[`known-issues-and-decisions.md`](known-issues-and-decisions.md)). Any
client that could not direct-play HEVC forced Jellyfin into **software**
transcoding — `ffmpeg` sustained at ~300 % CPU on a 4-thread machine,
which made the whole system sluggish and was the actual cause of several
"why is the network slow" and "why is Jellyfin slow" investigations.

H.264 direct-plays essentially everywhere, so converting the library
removes the transcode trigger entirely rather than trying to make a slow
transcode faster.

## Deciding what actually needed converting

Not every file needed touching. Two `ffprobe` passes classified the library:

```bash
# codec
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$f"

# HDR or SDR
ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=p=0 "$f"
```

- `codec_name=h264` → **skip entirely**, nothing to gain
- `color_transfer=smpte2084` → genuine HDR10, needs tonemapping
- `color_transfer=bt709` → SDR, straight codec swap

Files reporting `color_transfer=unknown` are ambiguous. Check for HDR
mastering-display side data on the **first frame only** before deciding:

```bash
ffprobe -v error -select_streams v:0 -read_intervals "%+#1" -show_frames \
        -show_entries frame=color_transfer,side_data_list "$f"
```

Genuine HDR always carries mastering-display/light-level side data; its
total absence means an untagged SDR rip. (Do not run `-show_frames` without
`-read_intervals` — it scans the entire file and takes minutes per movie.)

## The pipeline

Transfer, transcode, and pull-back are independent resources, but the GPU is
strictly serial. So the pipeline overlaps them: while file N transcodes,
file N+1 transfers in parallel; when N finishes, its pull-back starts
alongside N+1's transcode. The GPU never waits on the network.

```
HP  ──transfer N+1──▶  rog
                       rog ──transcode N (GPU)
HP  ◀──pull back N───  rog
```

`scripts/11-transcode-pipeline.sh` implements this. Sources are deleted from
the remote only after a pull-back is confirmed successful.

## ffmpeg invocations

**SDR** (hardware decode + hardware encode, ~3-4× realtime):
```
ffmpeg -y -hwaccel cuda -i in.mkv -vf format=nv12 \
  -c:v h264_nvenc -preset p5 -b:v 6M -maxrate 8M -bufsize 12M \
  -c:a copy out.mp4
```

**HDR → SDR tonemap** (~1× realtime — the tonemap runs on CPU):
```
ffmpeg -y -i in.mkv \
  -vf 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,\
tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p' \
  -c:v h264_nvenc -preset p5 -b:v 8M -maxrate 10M -bufsize 16M \
  -c:a copy out.mp4
```

Audio is **stream-copied** in both cases — only video is re-encoded.

## Bugs hit (all real, all cost time)

### `10 bit encode not supported`

H.264 is 8-bit only. Most HEVC rips are 10-bit **even when SDR**, so an
explicit downconversion is mandatory — `-pix_fmt yuv420p` or
`-vf format=nv12`. Without it `h264_nvenc` refuses to open and produces a
zero-byte output.

### `Impossible to convert between the formats supported by the filter`

Caused by including `hwdownload` in the tonemap chain **without**
`-hwaccel_output_format cuda`. Without that flag frames were never on the
GPU, so there is nothing to download and the filter graph fails
instantly. Either set the output format and keep `hwdownload`, or drop
`hwaccel` entirely for the HDR path (what this setup does).

### Silent success on a corrupt source

A transfer interrupted by the HDD dropping produced a truncated source.
ffmpeg "completed" it in ~30 seconds and the pipeline moved on. **A
transcode that finishes far faster than realtime has failed** — check
`rsync` exit codes, and sanity-check output duration against the source:

```bash
ffprobe -v error -show_entries format=duration -of csv=p=0 "$f"
```

### `/tmp` is a tmpfs

Staging multi-gigabyte output in `/tmp` fails with `Disk quota exceeded` —
it is RAM-backed and small. Stage on real disk.

## The cost: bitrate went up, substantially

**This is the part worth understanding before repeating this.** HEVC is far
more space- and bandwidth-efficient than H.264. Converting inflated files
roughly 3×:

| | HEVC source | H.264 output |
|---|---|---|
| Sam Bahadur (4K) | 1.9 GB | 6.7 GB |
| Library total | ~77 GB | ~190 GB |

So the trade is explicitly: **CPU load down, storage and network load up.**
That is a good trade on a machine that cannot transcode HEVC and has plenty
of disk — but it is actively counterproductive over a constrained network
link, and this setup's Wi-Fi is exactly that (2.4 GHz-only, ~25-30 Mbit/s
usable — see
[`storage-hardware-reliability.md`](storage-hardware-reliability.md)).
Streaming an 8 Mbps H.264 file over that link is harder than streaming the
2.5 Mbps HEVC original was.

**On new hardware that can hardware-decode HEVC, do not do this at all** —
keep the HEVC originals, direct-play them, and get smaller files *and*
lower bandwidth *and* no CPU cost. This whole exercise is a workaround for
one specific hardware limitation, not an improvement in its own right.

Original HEVC files are preserved in `~/Media/movies-hevc-backup/` rather
than deleted, precisely so the decision can be reversed on better hardware.

## Quality settings

`-b:v 6M` (SDR) / `8M` (HDR) with a `maxrate`/`bufsize` cap. An earlier
uncapped `-cq 20` run was on track to produce a **15 GB** file from a 1.9 GB
source — quality-targeted encoding without a cap balloons badly on 4K.
Cap the bitrate.
