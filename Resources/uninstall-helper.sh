#!/bin/bash
# Removes the root helper. Logs a running tunnel off first, which restores routes.
set -uo pipefail

ROOT=/Library/PrivilegedHelperTools/labvpn
DAEMON_DIR=/Library/LaunchDaemons
STATE_DIR=/var/run/labvpn
LAUNCHCTL=/bin/launchctl
REQUIRED_USER=root
LABEL=de.mariusrueve.labvpn.helper

[[ "$(id -un)" == "$REQUIRED_USER" ]] || { echo "Run as root" >&2; exit 1; }

"$LAUNCHCTL" bootout "system/$LABEL" 2>/dev/null

pid="$(cat "$STATE_DIR/openconnect.pid" 2>/dev/null)"
if [[ "$pid" =~ ^[0-9]+$ ]] && ps -p "$pid" -o comm= 2>/dev/null | grep -q "$ROOT/bin/openconnect"; then
  kill -TERM "$pid"
  for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
fi

rm -f "${DAEMON_DIR:?}/${LABEL:?}.plist"
rm -rf "${ROOT:?}" "${STATE_DIR:?}"
echo "Helper removed."
