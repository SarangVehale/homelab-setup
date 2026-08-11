# Storage layout and permissions

## Why `~/Media`, not `/srv/media`

Media storage went through two iterations:

1. **First**: `/srv/media`, owned by a shared `media` group that
   `audiobookshelf` and `calibre-web` were added to. Standard, simple, works.
2. **Then moved to `~/Media`** at the user's explicit request — wanted
   everything under the home directory where it's naturally browsable, not
   tucked away in `/srv`.

The move required solving a real problem: `~` is `700` (locked to
the owner only), and moving service data under it would normally mean either
loosening that (bad — exposes dotfiles, SSH keys, everything else in the home
directory) or the service accounts simply can't reach it.

**Solution: POSIX ACLs, scoped precisely.**

```
setfacl -m u:jellyfin:--x ~              # traverse-only, nothing else
setfacl -R -m u:jellyfin:r-X ~/Media/movies          # read-only, this subfolder only
setfacl -R -d -m u:jellyfin:r-X ~/Media/movies       # same, applies to future files too
```

The `--x` grant on the home directory itself is the key trick: it lets the
service account *pass through* `~` to reach a specific known
subpath, without being able to list or read anything else in the directory.
`ls -la ~` from the `jellyfin` account would show nothing;
`cat ~/Media/movies/whatever.mkv` works fine.

Verify this is still true after any change with:

```
getfacl ~
```

You want to see `group::---` (the real, unaffected traditional group
permission) — **not** just the `stat`/`ls -l` summary, which repurposes that
same display column to show the ACL *mask* once any ACL exists. A `710`
reading from `stat` is not automatically a problem; check the full `getfacl`
output before concluding anything changed.

## The layout

```
~/Media/
├── movies/              Jellyfin library (type: Movies)
├── tv/                  Jellyfin library (type: Shows)
├── audiobooks/           Audiobookshelf library
├── ebooks/               Calibre-Web library (the real, organized one)
│   └── .calnotes/        Calibre's own metadata, don't touch
├── ebooks-inbox/         qBittorrent lands ebook downloads here;
│                         watcher imports into ebooks/ automatically
└── incomplete/           qBittorrent's in-progress download staging
```

## Per-service ACL grants

| Path | Grantee | Permission | Why |
|---|---|---|---|
| `~` | `jellyfin`, `audiobookshelf`, `calibre-web` | `--x` (traverse only) | pass-through, nothing else |
| `~/Media/movies`, `~/Media/tv` | `jellyfin` | `r-X` (read-only) | scans/streams, never writes to source |
| `~/Media/audiobooks` | `audiobookshelf` | `r-X` (read-only) | same |
| `~/Media/ebooks` | `calibre-web` | `rwX` (read-write) | actively manages the library — edits metadata, converts formats, deletes |
| `~/Media/ebooks-inbox` | *(none needed)* | — | only `$USER` (qBittorrent, the watcher) ever touches this |

Note Calibre-Web is the only one with write access — it's the only app that
actively modifies its library contents (metadata edits, format conversion)
rather than just reading media to stream it.

## Why the ebook pipeline has a separate `ebooks-inbox`

`calibredb add` (used by the watcher script) **copies** the source file into
an organized `Author/Title/` structure inside the library — it does not
move it. If the watch folder and the library were the same directory, every
new download would end up duplicated: once as the raw flat file, once as the
organized copy.

Keeping `ebooks-inbox` as a genuinely separate folder means:
- qBittorrent keeps seeding the original file from a stable, untouched path
  (never move a file qBittorrent is actively tracking without using its own
  "Set location" feature — a raw `mv`/`rm` will desync its internal state
  and can break seeding compliance)
- The organized copy lives cleanly in `~/Media/ebooks` with no duplication

## Setup script

See `scripts/02-storage.sh` — creates the directory tree and applies all the
ACL grants above. Idempotent; safe to re-run.
