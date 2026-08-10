# Known issues and decisions — read this before migrating to new hardware

This is the most important file in the repo for a future hardware migration.
Several things here were worked around specifically because of *this*
machine's limitations (2013/2014 Intel Haswell) and should be **revisited,
not blindly copied**, on better hardware.

## Hardware-specific: revisit these on new hardware

### Haswell iGPU cannot hardware-transcode HEVC — likely fixed on newer hardware

**The problem**: Jellyfin transcoding 4K HEVC/HDR content pegged the CPU at
200%+ using software `libx264`, made playback of large files essentially
unusable. Attempting to fix this with VAAPI hardware acceleration hit a
**real driver bug**: the legacy Intel `i965` VAAPI driver crashes with
`SIGABRT` (`Assertion 'obj_surface->fourcc == VA_FOURCC_NV12' failed`)
specifically when hardware-encoding H.264 output from an HEVC source. This
is a documented, unresolved issue in the driver itself (matching reports
from other projects hitting the identical bug on the same hardware
generation), not a configuration mistake — no combination of Jellyfin
settings fixes it.

**Why**: Haswell's Quick Sync generation predates Intel's HEVC hardware
support entirely (HEVC hardware decode/encode arrived with Skylake, 2015+).
H.264 hardware decode/encode both work fine on this hardware; HEVC does not,
in either direction.

**Current workaround**: Jellyfin's Transcoding settings have hardware
decoding enabled *only* for H.264 (not HEVC, not any 10-bit/HDR variant),
and hardware encoding enabled generally. For files that are HEVC source,
this still doesn't help — decode stays on CPU regardless. See the next
section for how the *library itself* was worked around instead.

**On new hardware**: if it's Skylake-generation Intel or newer (or an
NVIDIA/AMD GPU with modern NVENC/VCE), full hardware HEVC decode+encode
should just work. Re-test with:
```
vainfo   # or nvidia-smi / rocm-smi depending on GPU vendor
```
and check for HEVC profiles in the output before assuming the same
VAAPI-driver bug applies — it may well not exist on newer driver/hardware
combinations. If it doesn't, you can likely re-enable HEVC hardware
decode/encode in Jellyfin's Transcoding settings and stop needing the
workaround below entirely.

### The remote-GPU re-encode workflow (temporary, hardware-specific patch)

Because of the above, specific 4K HEVC/HDR movies were re-encoded once,
manually, using a second machine's NVIDIA GPU (accessed over SSH, `ssh rog`)
to produce H.264 versions that direct-play cleanly on any client. This was a
**one-time, per-file operation**, not an ongoing pipeline — the second
machine has zero standing role in this setup.

The actual working ffmpeg pipeline (documented here in case it's needed
again before hardware upgrade, e.g. for other HEVC files in the library):

```bash
# On the remote machine with a capable GPU:
ffmpeg -y -init_hw_device opencl=ocl -filter_hw_device ocl \
  -i source.mkv \
  -vf "hwupload,tonemap_opencl=tonemap=hable:desat=0:format=nv12,hwdownload,format=nv12" \
  -c:v h264_nvenc -preset p5 -rc vbr -cq 23 -maxrate 12M -bufsize 24M \
  -colorspace bt709 -color_trc bt709 -color_primaries bt709 \
  -c:a copy \
  output.mp4
```

Key lessons baked into this command, worth knowing if reusing it:
- **CPU-based `zscale` tonemap is too slow even on a good GPU machine** —
  it bottlenecked at 0.85x realtime (slower than just watching it). Using
  `tonemap_opencl` (GPU-accelerated tonemap) instead got this to ~1.9-2.5x
  realtime. If a filter chain runs slower than expected, check what's
  actually on the CPU critical path before assuming the GPU is the
  bottleneck — decode was never the problem here, the *filter* was.
- **`-colorspace/-color_trc/-color_primaries` output flags don't reliably
  override all three tags** — observed `color_primaries` staying at the
  source's `bt2020` value despite the explicit flag, while `color_space`
  and `color_transfer` did get corrected. If this matters, verify with
  `ffprobe -show_entries stream=color_space,color_transfer,color_primaries`
  after encoding, and if needed, fix with a **second, near-instant
  stream-copy remux** (`-c copy` + the same three flags) rather than
  re-running the expensive encode — the tags are container metadata, they
  don't need the video re-decoded to fix.
- Never delete/rename a file qBittorrent is actively tracking with a raw
  `mv`/`rm` — always check `pgrep -x qbittorrent` and use qBittorrent's own
  "Set location"/"Rename" features, which update its internal state safely.

## Non-hardware-specific: apply these regardless of hardware

### Arch package version drift breaks things — build from source when it does

Both Audiobookshelf and Calibre-Web hit real bugs from Arch's rolling-release
model shipping a dependency ahead of what the app itself supports:

- **Audiobookshelf** (`extra/audiobookshelf`): bundled `node_modules`
  referenced Node's `SlowBuffer` API, removed in Node 26 (which Arch had
  already shipped) — crashed on startup. Also shipped without a compiled
  SQLite native binding for the current Node ABI at all.
- **Calibre-Web** (AUR `calibre-web`): pinned `Flask-Limiter<3.13.0` in its
  packaging, but Arch's system `python-flask-limiter` was already at 4.1.1
  — crashed on startup with a `TypeError` on an unsupported constructor
  argument.

**Fix in both cases: build from source** rather than patch the packaged
version. Building from GitHub `master` picks up whatever dependency
versions the *current* code actually declares support for — for Calibre-Web
specifically, `master`'s `requirements.txt` had already been updated to
allow `Flask-Limiter<4.2.0`, so a fresh venv install just worked with no
patching needed. This is a generally reliable escape hatch for "packaged
version broken by dependency drift" — check if it's already fixed upstream
before hand-patching.

### `nftables.service` boot-ordering race (real outage, not hypothetical)

`nftables.service` starts early in boot, before `tailscaled` has connected
and created the `tailscale0` interface. A firewall rule written as
`iif "tailscale0"` fails nftables' strict interface-existence validation at
that point, and **the entire ruleset fails to load — not just that one
rule**. This left both Jellyfin and AdGuard Home's firewall protection
silently absent for ~4 hours after a reboot before being caught in an audit.

**Fix**: match by Tailscale's stable IP range (`100.64.0.0/10`) instead of
interface name. This has no interface-existence dependency and can never
fail this way. See `config-templates/nftables.conf` and
`security-model.md`.

Services that bind to the literal Tailscale IP (not just filtered by
firewall) have a *different* version of the same race — they need
`After=`/`Wants=tailscale-online.target` in their systemd units so they wait
for the IP to actually be assigned before trying to bind to it. This is
`scripts/05-systemd-services.sh`.

### AdGuard Home's `dns.bind_hosts` config doesn't restrict its actual listener

Set explicitly to `[192.168.1.101, 100.100.208.10]` in
`/etc/adguardhome.yaml`, confirmed correct in the file — but the running
process logs `creating udp server socket addr=0.0.0.0:53` regardless.
Same category of issue as Jellyfin's `LocalNetworkAddresses` (see
`security-model.md`) — don't trust this setting, rely on the firewall.

### qBittorrent config gets clobbered if edited while running

qBittorrent holds its config in memory and rewrites the file on
exit/periodic save. Any file edit made while it's running risks being
silently overwritten. Always `pgrep -x qbittorrent` first; if it's running,
either fully quit it (tray → Exit, not just closing the window, since
"close to tray" means the window close doesn't actually quit it) before
editing, or make the change through the app's own UI instead.
