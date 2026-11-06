#!/bin/bash
# Installs the root helper from inside labvpn.app. Runs as root, from the app's
# admin prompt or scripts/install-helper.sh. Root only ever runs the copies made
# here: the app in /Applications is writable by its user, these files aren't.
# Usage: install-helper.sh <uid of the user who may use the helper>
set -euo pipefail

ROOT=/Library/PrivilegedHelperTools/labvpn
DAEMON_DIR=/Library/LaunchDaemons
LAUNCHCTL=/bin/launchctl
CODESIGN=/usr/bin/codesign
OWNER=(-o root -g wheel)
REQUIRED_USER=root
REQUIREMENT='anchor apple generic and certificate leaf[subject.OU] = "BRW9TTP8R5"'
LABEL=de.mariusrueve.labvpn.helper

uid="${1:-}"
[[ "$uid" =~ ^[0-9]+$ && "$uid" != 0 ]] || { echo "Usage: install-helper.sh <uid>" >&2; exit 1; }
[[ "$(id -un)" == "$REQUIRED_USER" ]] || { echo "Run as root" >&2; exit 1; }

payload="$(cd "$(dirname "$0")/.." && pwd -P)"
app="$(cd "$payload/../../.." && pwd -P)"

# Seals everything in the bundle, including this script and the wrapper.
"$CODESIGN" --verify --deep --strict -R="$REQUIREMENT" "$app" \
  || { echo "$app isn't a validly signed labvpn; not installing" >&2; exit 1; }

"$LAUNCHCTL" bootout "system/$LABEL" 2>/dev/null || true
rm -rf "${ROOT:?}"
install -d ${OWNER[@]+"${OWNER[@]}"} -m 755 "$(dirname "$ROOT")" "$ROOT" "$ROOT/bin" "$ROOT/lib" "$ROOT/scripts" "$ROOT/etc"
install ${OWNER[@]+"${OWNER[@]}"} -m 755 "$payload/labvpn-helper" "$ROOT/labvpn-helper"
install ${OWNER[@]+"${OWNER[@]}"} -m 755 "$payload/bin/openconnect" "$ROOT/bin/"
install ${OWNER[@]+"${OWNER[@]}"} -m 755 "$payload"/lib/*.dylib "$ROOT/lib/"
install ${OWNER[@]+"${OWNER[@]}"} -m 755 "$payload/scripts/vpnc-script" "$payload/scripts/labvpn-vpnc-wrapper.sh" "$ROOT/scripts/"
install ${OWNER[@]+"${OWNER[@]}"} -m 644 "$payload/MANIFEST.txt" "$ROOT/MANIFEST.txt"
printf '{"allowedUID":%d}\n' "$uid" > "$ROOT/helper.conf"
chmod 644 "$ROOT/helper.conf"
chown "$REQUIRED_USER" "$ROOT/helper.conf"
install ${OWNER[@]+"${OWNER[@]}"} -m 644 "$payload/$LABEL.plist" "$DAEMON_DIR/$LABEL.plist"

if find "$ROOT" \( -perm -g+w -o -perm -o+w -o ! -user "$REQUIRED_USER" \) | grep .; then
  echo "Refusing to start: the files above are writable by other users" >&2
  exit 1
fi

# launchd may need a moment after bootout.
for attempt in 1 2 3 4 5; do
  "$LAUNCHCTL" bootstrap system "$DAEMON_DIR/$LABEL.plist" && break
  [[ "$attempt" == 5 ]] && exit 1
  sleep 1
done
echo "Helper installed."
