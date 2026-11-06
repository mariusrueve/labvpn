# Changelog

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
