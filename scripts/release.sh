#!/bin/bash
# Builds, notarizes and staples a release. Needs the Developer ID certificate and
# the notarytool keychain profile `labvpn`.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
app=dist/labvpn.app
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
zip="dist/labvpn-$version.zip"

signature="$(codesign -dv "$app" 2>&1)"
[[ "$signature" == *TeamIdentifier=BRW9TTP8R5* ]] || { echo "Not signed with the Developer ID" >&2; exit 1; }
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile labvpn --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl -a -vv "$app"
ditto -c -k --keepParent "$app" "$zip.stapled"
mv -f "$zip.stapled" "$zip"
shasum -a 256 "$zip"
