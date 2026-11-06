# Decisions and lessons

Each of these cost real debugging. Read this before changing the area, and add to it
when you learn something the code can't show.

## Routing and DNS

- **Unset `CISCO_SPLIT_INC`; never set it to 0.** `vpnc-script` only tests that it's
  non-empty, so `0` installs no default route.
- **Always reach the gateway over IPv4.** `vpnc-script` can't add a host route to an IPv6
  gateway on macOS, because it passes every IPv6 default route at once. Without that route,
  the IPv6 block cuts off reconnects. A redirect escapes `--resolve`, so
  `AuthResult.preferringIPv4()` re-resolves after login.
- **Block direct IPv6 with `-reject`, not `-blackhole`,** so apps fail at once and use IPv4.
  Otherwise dual-stack sites see your real address.
- **`vpnc-script`'s `networksetup` calls are removed.** They wipe hand-set DNS on disconnect
  and always fail on connect. `scutil` does the real work. A PATH shim can't work, because the
  script puts `/usr/sbin` first.
- `vpnc-script` deletes the default route on connect, so a killed tunnel leaves the Mac
  offline unless cleanup runs.

## Recovery

- **A running openconnect proves nothing.** After sleep it can report a reconnect and pass no
  traffic, and with `DPD 0` it can't tell. Hence the health check.
- **Recovery starts a new process.** Waiting for openconnect's own retries took 39 s against
  under 5 s now.
- **SIGHUP makes openconnect exit,** keeping the session on the gateway. SIGTERM logs off.
- **Compare interface name and IPv4 address.** An iPhone hotspot stays on `en0`.
- **Ignore `utun*`,** or the tunnel coming up triggers a reconnect loop.
- **Log in again only if openconnect exited.** A silent tunnel means the network is the
  problem, and more logins stack up sessions on the gateway.
- If the probe never works on a fresh connection, it's disabled for the session, so a broken
  check can't restart a good tunnel.
- ssh sessions survive sleep and switches when the gateway returns the same address, because
  idle TCP sends nothing.

## Security and signing

- **Never run Homebrew's openconnect as root.** It loads `p11-kit-trust.dylib` from
  `/opt/homebrew`, and GnuTLS reads config there. Anyone running as the user could gain root.
  So GnuTLS is built from source without p11-kit.
- **`SMAppService.daemon` rejected:** root would run from a user-writable bundle.
- **Login keychain, not data-protection:** that needs a provisioning profile. A stable Developer
  ID signature stops prompts after updates anyway.
- **No certificate pinning.** Yearly renewals and load-balanced nodes cause false alarms.
  Untrusted certificates are refused.
- **Cookies aren't stored,** so browser sign-in repeats after any restart. It takes seconds.
- Importing a setup file never changes an existing default profile.

## Build

- Build the whole openconnect stack from source with a deployment target. Homebrew's bottles
  and a plain build target the build Mac's macOS only.
- Find the signing identity by hash: non-ASCII names don't survive `security find-identity`.
- With `pipefail`, `… | grep -q` can fail when `grep` exits early. Capture output first.
- `#expect` can't call a mutating method; wrap it in a class.
- In `ssh_config`, the first value wins, `%h` is still the short alias in an early `Match`,
  and an `Include` after a `Match` belongs to that block.

## Publishers

- ACS, Wiley, Elsevier, Science and RSC answer non-browser requests with a Cloudflare
  challenge, whatever the IP address. No VPN makes Zotero's own downloads work there.
  Use the Zotero Connector in a browser.
