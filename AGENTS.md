# labvpn agent guide

A macOS menu-bar app and CLI for Cisco AnyConnect VPNs, wrapping OpenConnect. It's a
research tool for its owner, and shared openly.

**The owner doesn't read Swift.** Work end to end: make the change, run the checks,
and report in plain language what changed, what you verified, and what still needs a
person. Don't ask them to review code. Ask them for decisions and for live tests.

## Commands

```bash
scripts/test.sh       # everything automated; run before every commit
scripts/build.sh      # dist/labvpn.app, signed if a Developer ID is present
scripts/install.sh    # install to /Applications and relaunch
scripts/release.sh    # build, notarize, staple; see docs/releasing.md
labvpn log --follow   # live log of the installed app
```

Full Xcode is required. The scripts set `DEVELOPER_DIR` themselves; plain `swift test`
or `swift build` may fail with Command Line Tools selected.

## Map

- `Sources/LabVPNCore`: all logic. `TunnelController` owns the session and states,
  `TunnelSupervisor` decides recovery, `TunnelProbe` is the health check, `Authenticator`
  runs logins, `ConnectRequest` validates what reaches root, `ControlSocket` links
  CLI and app, `Profile` holds profiles and setup files.
- `Sources/LabVPNApp`: SwiftUI menu bar and Settings. Keep logic out of here.
- `Sources/labvpn`: CLI. Talks only to the app.
- `Sources/labvpn-helper`: root daemon. Starts and signals openconnect.
- `Resources`: wrapper and install scripts that run as root, the patched `vpnc-script`.
- `docs/architecture.md`: how it fits together. `docs/decisions.md`: why, and what
  went wrong. **Read decisions.md before changing recovery, routing or signing.**

## Rules that protect users

- **Root never runs a user-writable file.** Not from the app bundle, not from Homebrew.
  Everything root runs is copied to `/Library/PrivilegedHelperTools/labvpn` first.
- Every value sent to the helper goes through `ConnectRequest.validate()`. No new
  helper command without validation. Nothing may reach openconnect as a flag.
- Cookies stay in memory and go to openconnect by stdin, never argv, disk or logs.
  Passwords live only in the Keychain. All logged text passes `LogRedactor`.
- Changing the helper, wrapper or `HelperProtocol` means bumping `HelperConstants.version`,
  so installed copies get updated.
- Stop on the first rejected password, so retries can't lock an account.
- A browser must never open without the user asking, except with `openSSOAutomatically`.
- `labvpn status` must never launch the app. Its first word is `connected` only while
  connected.
- Never commit personal details: real usernames, internal hostnames, home network
  details, log excerpts. `Tests/consistency-test.sh` catches a few of these.

## Testing

Unit tests use fakes: `FakeHelper`, `FakeAuth`, and fake `route`/`scutil` in the shell
tests. Add a test with each behaviour change.

**Passing tests don't prove a VPN change works.** Routing, sleep, network switches,
sign-in and the helper need real hardware and credentials, which an agent doesn't have.
Say exactly what wasn't verified, and give the owner the steps from `docs/testing.md`.
When a bug is reported, ask for `labvpn log`: the log usually shows the cause.

## Conventions

- No third-party Swift dependencies. Run processes by absolute path, with argument arrays.
- Scripts that delete things use `"${VAR:?}"`.
- Keep the app generic: nothing specific to one institution in code. Institution
  settings belong in `.labvpn` setup files in `examples/`.
- macOS 15+, arm64. Don't raise the minimum without asking.
- Commit messages say why. Update `CHANGELOG.md` for anything users notice.
