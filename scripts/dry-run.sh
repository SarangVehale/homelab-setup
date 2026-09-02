#!/usr/bin/env bash
# Runs a deploy script with sudo/grub-mkconfig/mkinitcpio stubbed out, under
# the same `set -euo pipefail` the real script uses.
#
# Exists because three consecutive runs of 13-boot-resilience.sh aborted on
# error-handling bugs rather than on the work itself - `sudo tee` truncating,
# pipefail killing a diagnostic pipeline, and a command substitution whose
# non-zero exit tripped `set -e`. `bash -n` catches none of those; only
# actually executing the control flow does.
#
# Usage: ./scripts/dry-run.sh scripts/13-boot-resilience.sh
set -euo pipefail

TARGET="${1:?usage: dry-run.sh <script>}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp)

{
    echo '#!/usr/bin/env bash'
    echo "REPO_OVERRIDE=$REPO"
    cat <<'SHIM'
sudo()          { echo "      [dry] sudo $*"; return 0; }
grub-mkconfig() { echo "      [dry] grub-mkconfig $*"; return 0; }
mkinitcpio()    { echo "      [dry] mkinitcpio $*"; return 0; }
SHIM
    tail -n +2 "$REPO/$TARGET" \
      | sed 's|^REPO=.*|REPO="$REPO_OVERRIDE"|' \
      | sed 's|^GRUB_TMP=$(mktemp)|GRUB_TMP=$(mktemp); cp /boot/grub/grub.cfg "$GRUB_TMP"|'
} > "$TMP"

bash -n "$TMP" || { echo "SYNTAX ERROR" >&2; rm -f "$TMP"; exit 1; }
echo "=== dry run: $TARGET ==="
if bash "$TMP"; then
    echo "=== completed without aborting ==="
    rc=0
else
    rc=$?
    echo "=== ABORTED with exit $rc - fix before running for real ===" >&2
fi
rm -f "$TMP"
exit "$rc"
