#!/usr/bin/env bash
# Build Audiobookshelf from source. See docs/known-issues-and-decisions.md
# for why - the Arch package had a Node 26 incompatibility (removed
# SlowBuffer API) and shipped without a compiled SQLite native binding.
# Re-check on new hardware whether this is still necessary: if the packaged
# version starts working cleanly, prefer it over maintaining a source build.
set -euo pipefail

echo "==> Cloning source"
sudo git clone https://github.com/advplyr/audiobookshelf.git /opt/audiobookshelf

echo "==> Building client + installing server deps"
cd /opt/audiobookshelf
sudo /usr/bin/npm run client
# Use install, not ci - the lockfile can be slightly out of sync (e.g.
# missing optional platform-specific entries like fsevents) and ci refuses
# to proceed on any mismatch. install reconciles it automatically.
sudo /usr/bin/npm install

echo "==> Checking the SQLite native binding actually compiled"
if ! find /opt/audiobookshelf/node_modules/sqlite3 -iname "*.node" | grep -q .; then
    echo "WARNING: sqlite3 native binding didn't compile automatically."
    echo "Building it explicitly with node-gyp..."
    cd /opt/audiobookshelf/node_modules/sqlite3
    sudo /opt/audiobookshelf/node_modules/.bin/node-gyp rebuild
    cd /opt/audiobookshelf
fi

echo "==> Patching known Node 26 compatibility issue (SlowBuffer removed)"
# buffer-equal-constant-time (via jsonwebtoken -> jwa) references the old
# SlowBuffer API at module load time, unguarded. Node 26 removed it
# entirely, crashing the whole app on startup. There are TWO copies of this
# file bundled - patch both, or you'll get a working `npm install` that
# still crashes.
for f in \
    /opt/audiobookshelf/node_modules/buffer-equal-constant-time/index.js \
    /opt/audiobookshelf/server/libs/jwa/buffer-equal-constant-time/index.js
do
    if [ -f "$f" ] && grep -q "^var origSlowBufEqual = SlowBuffer.prototype.equal;$" "$f"; then
        sed -i '37s#.*#var origSlowBufEqual = SlowBuffer \&\& SlowBuffer.prototype ? SlowBuffer.prototype.equal : null;#' "$f"
        echo "    patched: $f"
    else
        echo "    already patched or not present (may be fixed upstream): $f"
    fi
done

echo "==> Audiobookshelf source build complete."
echo "    Ownership (chown to the audiobookshelf service account) happens in"
echo "    scripts/05-systemd-services.sh, which also creates that account -"
echo "    it doesn't exist yet on a fresh machine."
