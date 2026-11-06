# labvpn

A small macOS menu-bar app and command-line tool for Cisco AnyConnect VPNs, built on
[OpenConnect](https://www.infradead.org/openconnect/).

It's made for the moment your VPN gets in the way: close the lid, change networks, and it
reconnects by itself, usually within seconds and without asking you to sign in. All your
traffic goes through the VPN, so every app works with no configuration: ssh, git, curl,
pip, and anything else.

- Full tunnel, with direct IPv6 blocked while connected
- Automatic recovery after sleep and network changes
- Password sign-in from your Keychain, or browser sign-in (SSO)
- Share a setup with colleagues as a `.labvpn` file
- Scriptable with the `labvpn` command

**labvpn is an unofficial, independent project.** It isn't affiliated with or supported by
Cisco or by any university or company. Check your organisation's rules on VPN clients
before you use it.

Needs an Apple Silicon Mac with macOS 15 or later.

## Install

```bash
brew tap mariusrueve/tap
brew trust --cask mariusrueve/tap/labvpn
brew install --cask mariusrueve/tap/labvpn
```

Homebrew asks you to trust third-party casks once, which is what the second line does.

## Set up

1. Open labvpn, and enter your gateway, such as `vpn.example.org` or `vpn.example.org/GROUP`.
   If someone gave you a `.labvpn` file, double-click it instead.
2. Enter your username and password. The password stays in your Keychain.
3. Enter your admin password when macOS asks, to install the VPN helper.

Then use the shield in the menu bar. Add more gateways in Settings → Profiles.

Ready-made setup files are in [examples](examples).

## Command line

```bash
labvpn connect [<profile>]
labvpn status [--json]
labvpn disconnect
labvpn reconnect
labvpn profiles
labvpn log [--follow]
```

## Good to know

- Quitting the app logs off. There's no kill switch: if the VPN can't reconnect, traffic goes
  direct until it can.
- Browser sign-in has to be repeated after any restart, because session cookies are never
  stored.
- If connections hang, try MTU 1347 in Settings → Profiles.
- Using Zotero? Some publishers block its own PDF downloads, whatever your IP address. Save
  those through a browser with the Zotero Connector.
- Logs are in `~/Library/Logs/labvpn/labvpn.log`. They leave out passwords and cookies.

See [SECURITY.md](SECURITY.md) for how the root helper is protected.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). [docs/architecture.md](docs/architecture.md) explains how
it works, and [docs/decisions.md](docs/decisions.md) explains why.

## License

Apache License 2.0. Third-party components and their licenses are listed in
[Resources/ThirdParty/NOTICE.txt](Resources/ThirdParty/NOTICE.txt).
