#!/bin/bash
# Runs scripts/bump-version.sh on a copy of the repo's version files.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/Resources"
cp scripts/bump-version.sh "$tmp/scripts/"
cp Resources/Info.plist "$tmp/Resources/"
fail() { echo "FAIL: $1" >&2; exit 1; }
version() { /usr/libexec/PlistBuddy -c "Print :$1" "$tmp/Resources/Info.plist"; }

old="$(version CFBundleShortVersionString)"
build="$(version CFBundleVersion)"
printf '# Changelog\n\n## %s\n\n- Old.\n' "$old" > "$tmp/CHANGELOG.md"
"$tmp/scripts/bump-version.sh" 99.0.0 >/dev/null 2>&1 && fail "bumped without an Unreleased section"

printf '# Changelog\n\n## Unreleased\n\n- New.\n\n## %s\n' "$old" > "$tmp/CHANGELOG.md"
"$tmp/scripts/bump-version.sh" "$old" >/dev/null 2>&1 && fail "accepted the same version"
"$tmp/scripts/bump-version.sh" 0.0.1 >/dev/null 2>&1 && fail "accepted a lower version"
"$tmp/scripts/bump-version.sh" 99.0.10 >/dev/null
[[ "$(version CFBundleShortVersionString)" == 99.0.10 ]] || fail "version not set"
[[ "$(version CFBundleVersion)" == "$((build + 1))" ]] || fail "build number not raised"
grep -qx '## 99.0.10' "$tmp/CHANGELOG.md" || fail "changelog heading not set"
[[ "$(diff Resources/Info.plist "$tmp/Resources/Info.plist" | grep -c '^[<>]')" == 4 ]] || fail "more than the two version lines changed"
echo "bump-version tests passed"
