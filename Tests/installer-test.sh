#!/bin/bash
# Runs the helper install and uninstall scripts against a fake root, without root.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT
me="$(id -un)"

payload="$tmp/labvpn.app/Contents/Library/Helper"
mkdir -p "$payload/bin" "$payload/lib" "$payload/scripts" "$tmp/daemons" "$tmp/state" "$tmp/fake"
touch "$payload/labvpn-helper" "$payload/bin/openconnect" "$payload/lib/libfake.dylib" \
  "$payload/scripts/vpnc-script" "$payload/scripts/labvpn-vpnc-wrapper.sh" \
  "$payload/MANIFEST.txt" "$payload/de.mariusrueve.labvpn.helper.plist"

cat > "$tmp/fake/codesign" <<FAKE
#!/bin/sh
echo "\$*" >> "$tmp/codesign.log"
[ -z "\$FAKE_BAD_SIGNATURE" ]
FAKE
cat > "$tmp/fake/launchctl" <<FAKE
#!/bin/sh
echo "\$*" >> "$tmp/launchctl.log"
FAKE
chmod +x "$tmp/fake/codesign" "$tmp/fake/launchctl"

patch_script() {
  sed -e "s#^ROOT=.*#ROOT=$tmp/root/labvpn#" \
      -e "s#^DAEMON_DIR=.*#DAEMON_DIR=$tmp/daemons#" \
      -e "s#^STATE_DIR=.*#STATE_DIR=$tmp/state#" \
      -e "s#^LAUNCHCTL=.*#LAUNCHCTL=$tmp/fake/launchctl#" \
      -e "s#^CODESIGN=.*#CODESIGN=$tmp/fake/codesign#" \
      -e "s#^OWNER=.*#OWNER=()#" \
      -e "s#^REQUIRED_USER=.*#REQUIRED_USER=$me#" "$1" > "$2"
  chmod +x "$2"
}
patch_script Resources/install-helper.sh "$payload/scripts/install-helper.sh"
patch_script Resources/uninstall-helper.sh "$payload/scripts/uninstall-helper.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
install_helper() { env "$@" "$payload/scripts/install-helper.sh" 501 >/dev/null 2>&1; }

"$payload/scripts/install-helper.sh" 0 >/dev/null 2>&1 && fail "uid 0 accepted"
"$payload/scripts/install-helper.sh" 'x;id' >/dev/null 2>&1 && fail "bad uid accepted"

mkdir -p "$tmp/root/labvpn"
touch "$tmp/root/labvpn/keep"
install_helper FAKE_BAD_SIGNATURE=1 && fail "installed a badly signed payload"
[[ -e "$tmp/root/labvpn/keep" ]] || fail "bad signature removed the old install"
[[ ! -e "$tmp/launchctl.log" ]] || fail "bad signature touched launchd"

install_helper X=1 || fail "install failed"
grep -q 'subject.OU\] = "BRW9TTP8R5"' "$tmp/codesign.log" || fail "Team ID not required"
[[ ! -e "$tmp/root/labvpn/keep" ]] || fail "old files left behind"
for file in labvpn-helper bin/openconnect lib/libfake.dylib scripts/vpnc-script scripts/labvpn-vpnc-wrapper.sh MANIFEST.txt; do
  [[ -e "$tmp/root/labvpn/$file" ]] || fail "$file not installed"
done
grep -q '"allowedUID":501' "$tmp/root/labvpn/helper.conf" || fail "uid not recorded"
[[ -e "$tmp/daemons/de.mariusrueve.labvpn.helper.plist" ]] || fail "daemon plist missing"
grep -q bootstrap "$tmp/launchctl.log" || fail "helper not started"
[[ -z "$(find "$tmp/root/labvpn" -perm -o+w)" ]] || fail "installed files are world-writable"

echo 99999 > "$tmp/state/openconnect.pid"
"$payload/scripts/uninstall-helper.sh" >/dev/null || fail "uninstall failed"
[[ ! -e "$tmp/root/labvpn" ]] || fail "helper tree left behind"
[[ ! -e "$tmp/daemons/de.mariusrueve.labvpn.helper.plist" ]] || fail "daemon plist left behind"
grep -q bootout "$tmp/launchctl.log" || fail "helper not stopped"
echo "installer tests passed"
