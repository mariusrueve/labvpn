#!/bin/bash
# Releases the version in Resources/Info.plist: checks, build, notarize, staple,
# tag, GitHub release with the CHANGELOG.md notes, and the Homebrew tap.
# Needs the Developer ID certificate, the notarytool keychain profile `labvpn`,
# gh signed in, and the tap checked out by Homebrew (brew tap mariusrueve/tap).
#
# Usage: scripts/release.sh [--dry-run]
#   --dry-run checks and builds, then prints what it would publish.
set -euo pipefail
cd "$(dirname "$0")/.."

dry_run=0
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=1 ;;
  *) echo "Usage: scripts/release.sh [--dry-run]" >&2; exit 1 ;;
esac

fail() { echo "release: $1" >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
tag="v$version"
zip="dist/labvpn-$version.zip"
tap_repo=mariusrueve/tap
cask=Casks/labvpn.rb

# Everything that can stop a release is checked before anything is built.
[[ "$(git branch --show-current)" == master ]] || fail "not on master"
if ! git diff --quiet || ! git diff --cached --quiet; then fail "uncommitted changes"; fi
git fetch --quiet origin
git merge-base --is-ancestor origin/master HEAD || fail "behind origin/master; pull first"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "tag $tag exists; run scripts/bump-version.sh"
[[ -z "$(git ls-remote --tags origin "refs/tags/$tag")" ]] || fail "tag $tag exists on GitHub"
notes="$(awk -v heading="## $version" '$0 == heading { found = 1; next } found && /^## / { exit } found' CHANGELOG.md | sed '/./,$!d')"
[[ -n "${notes//[[:space:]]/}" ]] || fail "CHANGELOG.md has no notes under '## $version'"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in: gh auth login"
tap="$(brew --repository "$tap_repo")"
[[ -f "$tap/$cask" ]] || fail "Homebrew tap not found: brew tap $tap_repo"
[[ -z "$(git -C "$tap" status --porcelain)" ]] || fail "the tap at $tap has uncommitted changes"

scripts/test.sh
scripts/build.sh
app=dist/labvpn.app
signature="$(codesign -dv "$app" 2>&1)"
[[ "$signature" == *TeamIdentifier=BRW9TTP8R5* ]] || fail "not signed with the Developer ID"

if (( dry_run )); then
  echo
  echo "Dry run: checks and build passed. A release would:"
  echo "  notarize and staple $app, zip it to $zip"
  echo "  tag $tag at $(git rev-parse --short HEAD) and push master and the tag"
  echo "  publish 'labvpn $version' on GitHub with these notes:"
  printf '%s\n' "$notes" | sed 's/^/    /'
  echo "  set version $version and the zip's sha256 in $tap/$cask, commit and push"
  exit 0
fi

ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile labvpn --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl -a -vv "$app"
ditto -c -k --keepParent "$app" "$zip.stapled"
mv -f "$zip.stapled" "$zip"
sha="$(shasum -a 256 "$zip" | awk '{print $1}')"

git tag -a "$tag" -m "labvpn $version"
git push origin master "$tag"
printf '%s\n' "$notes" | gh release create "$tag" "$zip" --title "labvpn $version" --notes-file -

git -C "$tap" pull --quiet --ff-only
/usr/bin/perl -pi -e "s/^(\s*version )\"[^\"]*\"/\${1}\"$version\"/; s/^(\s*sha256 )\"[0-9a-f]*\"/\${1}\"$sha\"/" "$tap/$cask"
grep -q "\"$sha\"" "$tap/$cask" || fail "could not update $cask; set version $version and sha256 $sha by hand"
git -C "$tap" commit --quiet -am "labvpn $version"
git -C "$tap" push --quiet
brew fetch --cask --force "$tap_repo/labvpn" >/dev/null

echo
echo "Released labvpn $version"
echo "  https://github.com/mariusrueve/labvpn/releases/tag/$tag"
echo "  sha256 $sha"
