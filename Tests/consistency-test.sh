#!/bin/bash
# Catches values that must match across files, and private details in tracked files.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }

team="$(sed -n 's/.*subject.OU\] = "\([A-Z0-9]*\)".*/\1/p' Resources/install-helper.sh | head -1)"
[[ -n "$team" ]] || fail "no Team ID in install-helper.sh"
grep -q "$team" Sources/LabVPNCore/HelperProtocol.swift || fail "Team ID differs in HelperProtocol.swift"
grep -q "$team" scripts/release.sh || fail "Team ID differs in release.sh"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
grep -q "^## $version" CHANGELOG.md || fail "CHANGELOG.md has no entry for $version"

label=de.mariusrueve.labvpn.helper
grep -q "$label" Sources/LabVPNCore/HelperProtocol.swift || fail "helper label differs in HelperProtocol.swift"
/usr/libexec/PlistBuddy -c 'Print :Label' "Resources/$label.plist" | grep -qx "$label" || fail "helper label differs in plist"

if git ls-files | grep -v '^Tests/consistency-test.sh$' | xargs grep -lIE 'bari\.zbh|:7373|hessen|mrueve@' 2>/dev/null; then
  fail "the files above contain private host or account details"
fi
echo "consistency tests passed"
