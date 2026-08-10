#!/usr/bin/env bash
# Build Calibre-Web from source into a dedicated Python venv. See
# docs/known-issues-and-decisions.md for why - the AUR package pinned
# Flask-Limiter<3.13.0 but Arch's system python-flask-limiter had already
# moved to 4.1.1, crashing on startup. Building from GitHub master picks up
# master's requirements.txt, which had already been updated to allow
# Flask-Limiter<4.2.0 - a venv gives it fully isolated deps either way, so
# this class of problem can't recur even if Arch's system packages drift
# further.
#
# Check on new hardware whether this is still necessary before assuming
# it is - if the AUR/official package works cleanly, prefer it.
set -euo pipefail

echo "==> Cloning source"
sudo git clone https://github.com/janeczku/calibre-web.git /opt/calibre-web

echo "==> Building a dedicated venv (isolates deps from system Python entirely)"
sudo python3 -m venv /opt/calibre-web/venv
sudo /opt/calibre-web/venv/bin/pip install --upgrade pip
sudo /opt/calibre-web/venv/bin/pip install -r /opt/calibre-web/requirements.txt

echo "==> Calibre-Web source build complete."
echo "    Ownership + service account creation happens in"
echo "    scripts/05-systemd-services.sh."
