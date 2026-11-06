#!/bin/bash
# For source builds. Normally the app installs its own helper (Settings → Helper).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(id -u)" == 0 && -n "${SUDO_UID:-}" && "$SUDO_UID" != 0 ]] || { echo "Run with sudo from your own account" >&2; exit 1; }
script=dist/labvpn.app/Contents/Library/Helper/scripts/install-helper.sh
[[ -x "$script" ]] || { echo "Run scripts/build.sh first, without sudo" >&2; exit 1; }
"$script" "$SUDO_UID"
