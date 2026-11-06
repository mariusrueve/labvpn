#!/bin/bash
# Builds dist/labvpn.app with the helper payload inside it. Run as your normal user.
# Signs with LABVPN_SIGN_IDENTITY, or else this Mac's Developer ID. An ad-hoc build
# compiles and runs, but the installed helper refuses it.
set -euo pipefail
cd "$(dirname "$0")/.."
# SwiftUI macros need full Xcode, not just the Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -x build/stage/bin/openconnect ]] || scripts/build-openconnect.sh
swift build -c release
bin="$(swift build -c release --show-bin-path)"

identity="${LABVPN_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  # By hash: names with non-ASCII letters don't survive this output intact.
  identity="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')"
fi
identity="${identity:--}"

rm -rf dist
app=dist/labvpn.app
payload="$app/Contents/Library/Helper"
licenses="$app/Contents/Resources/ThirdParty"
mkdir -p "$app/Contents/MacOS" "$payload/bin" "$payload/lib" "$payload/scripts" "$licenses"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$bin/LabVPNApp" "$bin/labvpn" "$app/Contents/MacOS/"
cp "$bin/labvpn-helper" build/stage/MANIFEST.txt Resources/de.mariusrueve.labvpn.helper.plist "$payload/"
cp build/stage/bin/openconnect "$payload/bin/"
cp build/stage/lib/*.dylib "$payload/lib/"
cp build/stage/scripts/vpnc-script Resources/labvpn-vpnc-wrapper.sh \
  Resources/install-helper.sh Resources/uninstall-helper.sh "$payload/scripts/"
cp LICENSE "$licenses/labvpn-LICENSE"
cp Resources/ThirdParty/NOTICE.txt "$licenses/"
scripts/copy-licenses.sh "$licenses"

sign() {
  local name="$1"
  shift
  if [[ "$identity" == - ]]; then
    codesign --force --sign - --identifier "$name" "$@"
  else
    codesign --force --sign "$identity" --options runtime --timestamp --identifier "$name" "$@"
  fi
}

# Inside-out: the outer signature seals everything already signed.
for lib in "$payload"/lib/*.dylib; do sign "de.mariusrueve.labvpn.$(basename "$lib" .dylib)" "$lib"; done
sign de.mariusrueve.labvpn.openconnect "$payload/bin/openconnect"
sign de.mariusrueve.labvpn.helper "$payload/labvpn-helper"
sign de.mariusrueve.labvpn.cli "$app/Contents/MacOS/labvpn"
sign de.mariusrueve.labvpn "$app"
codesign --verify --deep --strict "$app"
echo "Built $app (signed by: $identity)"
