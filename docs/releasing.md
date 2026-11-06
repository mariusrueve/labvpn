# Releasing

Needs the Developer ID certificate and the notarytool keychain profile `labvpn`.

1. Set the version in `Resources/Info.plist` and add it to `CHANGELOG.md`.
2. If the helper, its scripts or `HelperProtocol` changed, bump `HelperConstants.version`.
3. `scripts/test.sh`, and the live checks that apply.
4. Commit, and tag `vX.Y.Z`.
5. `scripts/release.sh`. It prints the sha256 of `dist/labvpn-X.Y.Z.zip`.
6. `gh release create vX.Y.Z dist/labvpn-X.Y.Z.zip --notes-file <notes>`
7. In [homebrew-tap](https://github.com/mariusrueve/homebrew-tap), update `version` and `sha256`
   in `Casks/labvpn.rb`, then test with `brew upgrade --cask labvpn`.

## Updating OpenConnect or its libraries

Change the versions and hashes at the top of `scripts/build-openconnect.sh`. Check upstream
security notices for GnuTLS and OpenConnect at every release. If `vpnc-script` needs updating,
copy the new version to `Resources/vpnc-script` and remove its `networksetup -setdnsservers`
lines again.
