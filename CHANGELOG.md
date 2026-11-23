# Changelog

## 0.3.3

- labvpn has an app icon.
- `labvpn --version` shows the installed version.
- Fixes helper installation failing with “Bootstrap failed: 5” after downloading the app.
  The helper updates itself; macOS may ask for your admin password.

## 0.3.2

- Fixes a gateway becoming unreachable ("Can't assign requested address") after a
  reconnect during a Wi-Fi change, until restart. A route to the gateway was left
  behind; the helper now removes it whenever no tunnel runs. The helper updates itself.

## 0.3.1

- Fixes a crash in the app, CLI and helper when the other end of a socket or pipe
  went away during a write. Found by CI. The helper updates itself on first launch.

## 0.3.0

First public release.

- Menu-bar app and `labvpn` CLI for Cisco AnyConnect gateways, built on OpenConnect.
- Full tunnel, with direct IPv6 blocked while connected.
- Automatic recovery after sleep and network changes, using a tunnel health check.
- Password sign-in from the Keychain, and browser (SSO) sign-in.
- Settings window, `.labvpn` setup files and diagnostics export.
- Signed with a Developer ID and notarized. The app installs its own root helper.
