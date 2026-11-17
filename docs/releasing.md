# Releasing

Needs the Developer ID certificate, the notarytool keychain profile `labvpn`, `gh` signed
in, and the tap checked out by Homebrew (`brew tap mariusrueve/tap`).

While working, add user-visible changes under `## Unreleased` in `CHANGELOG.md`. Then:

1. `scripts/bump-version.sh X.Y.Z`, review `CHANGELOG.md`, and commit ("labvpn X.Y.Z").
   If the helper, its scripts or `HelperProtocol` changed since the last release, check that
   `HelperConstants.version` went up.
2. Run the live checks from `docs/testing.md` that the release touches.
3. `scripts/release.sh --dry-run`, then `scripts/release.sh`.

`release.sh` stops before building if anything is off: not on `master`, uncommitted
changes, behind `origin/master`, the tag already exists, no changelog notes for the
version, `gh` signed out, or the tap has local changes. It then runs `scripts/test.sh`,
builds, notarizes and staples, tags `vX.Y.Z` and pushes, publishes the GitHub release
with the changelog section as notes, and updates `Casks/labvpn.rb` in the tap.

If it fails after tagging, finish the remaining steps by hand: `gh release create`, then
`version` and `sha256` in the cask.

## Updating OpenConnect or its libraries

Change the versions and hashes at the top of `scripts/build-openconnect.sh`. Check upstream
security notices for GnuTLS and OpenConnect at every release. If `vpnc-script` needs updating,
copy the new version to `Resources/vpnc-script` and remove its `networksetup -setdnsservers`
lines again.
