#!/bin/bash
# Sets the version for the next release: Info.plist, and the CHANGELOG.md heading.
# Usage: scripts/bump-version.sh X.Y.Z
set -euo pipefail
cd "$(dirname "$0")/.."
new="${1:-}"
[[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: scripts/bump-version.sh X.Y.Z" >&2; exit 1; }
plist=Resources/Info.plist

# Read with PlistBuddy, but edit as text: PlistBuddy rewrites the whole file.
old="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
highest="$(printf '%s\n%s\n' "$old" "$new" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
[[ "$new" != "$old" && "$highest" == "$new" ]] || { echo "$new is not higher than $old" >&2; exit 1; }
grep -qx '## Unreleased' CHANGELOG.md || { echo "CHANGELOG.md has no '## Unreleased' section to release" >&2; exit 1; }

/usr/bin/perl -0pi -e "s|(<key>CFBundleShortVersionString</key>\s*<string>)\Q$old\E(</string>)|\${1}$new\${2}|; s|(<key>CFBundleVersion</key>\s*<string>)$build(</string>)|\${1}$((build + 1))\${2}|" "$plist"
plutil -lint "$plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$new" ]] || { echo "Could not set the version" >&2; exit 1; }
/usr/bin/perl -pi -e "s/^## Unreleased\$/## $new/" CHANGELOG.md
echo "Version $old → $new (build $((build + 1))). Review CHANGELOG.md, then commit."
