#!/bin/bash
# Installs the app for this user. Nothing here runs as root.
set -euo pipefail
cd "$(dirname "$0")/.."
source=dist/labvpn.app
target=/Applications/labvpn.app
[[ -d "$source" ]] || { echo "Run scripts/build.sh first" >&2; exit 1; }

if [[ -d "$target" ]]; then
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$id" == de.mariusrueve.labvpn ]] || { echo "$target isn't labvpn; not replacing it" >&2; exit 1; }
  # Quitting logs the tunnel off and restores the network.
  osascript -e 'tell application id "de.mariusrueve.labvpn" to quit' 2>/dev/null || true
  for _ in {1..40}; do pgrep -x LabVPNApp >/dev/null || break; sleep 0.25; done
  rm -rf "$target"
fi
ditto "$source" "$target"
open "$target"
echo "Installed $target"
if [[ "$(readlink /usr/local/bin/labvpn 2>/dev/null)" != "$target/Contents/MacOS/labvpn" ]]; then
  echo "For the labvpn command, run: sudo ln -sf $target/Contents/MacOS/labvpn /usr/local/bin/labvpn"
fi
