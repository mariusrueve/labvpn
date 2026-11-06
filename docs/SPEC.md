# labvpn — Specification

> Working name: **labvpn**. A small native macOS menu-bar app and CLI that wraps
> `openconnect` to connect to the University of Hamburg (UHH / ZBH) Cisco
> AnyConnect VPN as a **full tunnel**, and stays connected across sleep and
> network changes.
>
> Status: v3 · Author: Marius Rüve · 2026-11-06
>
> This is the original design document, kept up to date with what was built. It
> records the University of Hamburg setup labvpn was first written for; the app
> itself works with any AnyConnect gateway. Comments in the code cite its sections,
> such as "SPEC 6". For the current shape of the code, start with
> [architecture.md](architecture.md).

---

## 1. Background & motivation

[labroute](https://github.com/mariusrueve/labroute) sends selected domains
through an SSH SOCKS proxy using a PAC file. This works in browsers but **not
in Zotero**. Adding an item by DOI (magic wand) or running *Find Full Text*
doesn't fetch the PDF, even though the same publisher page works in
Safari/Chrome with labroute connected. This was first blamed on Zotero's network
stack ignoring labroute's routing. M0 showed a second cause that no VPN can fix:
ACS, Wiley, Elsevier, Science and RSC answer non-browser requests with a
Cloudflare challenge, even from a UHH address. PDFs from those publishers must
be saved through a browser, with the Zotero Connector.

Instead of making each app proxy-aware, labvpn routes **all traffic at the IP
level** through the official UHH VPN gateways using `openconnect`. Every app
then works with no per-app configuration: Zotero, ssh without a jump
host, git, curl, pip, and others.

The official Cisco Secure Client works but is heavy. labvpn aims to be
lighter, scriptable, and better at recovering after sleep and network changes.

### Decision record

| Option | Outcome |
|---|---|
| Fix labroute (Zotero proxy prefs, SSH tab UX) | Rejected for this project. labroute stays as is as a separate tool. |
| openconnect + ocproxy as a second labroute backend (userspace SOCKS) | Rejected. It still misses apps that ignore proxies. |
| **Standalone openconnect wrapper, full tunnel, root helper** | **Chosen.** |

### Verified by the author

- `sudo openconnect --protocol=anyconnect -u <kennung> vpn2-aux2.rrz.uni-hamburg.de/VPNZBH`
  → connects with **password only** (terminal prompt).
- `sudo openconnect --protocol=anyconnect -u <kennung> vpn.rrz.uni-hamburg.de`
  → hands off to the **browser for SSO**, then connects.

---

## 2. Goals

1. One-click connect/disconnect from the menu bar. Also scriptable via CLI.
2. **Full tunnel:** all IPv4 traffic goes through the VPN while connected.
3. **Seamless recovery** after sleep/wake and network changes. No prompts
   when the session can be resumed or (for ZBH) re-authenticated silently.
4. Any Cisco AnyConnect gateway, as profiles. ZBH and UHH ship as a setup file,
   not built in.
5. Credentials in the macOS Keychain. ZBH re-auth is fully automatic.
6. After a one-time admin approval, no password or sudo prompts for routine
   use.
7. Easy for ZBH colleagues to install (Homebrew cask) and set up (shareable
   profile file).

## 3. Non-goals (v1)

- Split tunnelling or per-domain routing. Use labroute for that.
- iOS/iPadOS, Linux, Windows.
- Detecting or coordinating with Cisco Secure Client or labroute. The user
  runs one at a time.
- Auto-disconnecting on the campus network or eduroam.
- Kill switch / traffic blocking while disconnected.
- Protocols other than Cisco AnyConnect (GlobalProtect, Fortinet, etc.).
- Tunnelling IPv6 beyond what openconnect and the gateway provide by default.

---

## 4. Users & environment

- **Primary user:** the author, on a MacBook Pro (Apple Silicon, macOS 15+).
- **Secondary users:** ZBH colleagues with ZBH VPN activation (access level ≥ 2)
  and/or a UHH account.
- Gateways:
  - **ZBH:** `vpn2-aux2.rrz.uni-hamburg.de/VPNZBH`. Password auth.
  - **UHH:** `vpn.rrz.uni-hamburg.de`. Browser SSO, possibly with 2FA
    depending on the account.

---

## 5. Architecture

```
┌──────────────────────────── labvpn.app (user) ────────────────────────────┐
│ LabVPNApp (SwiftUI menu bar)      LabVPNCLI (`labvpn`)                     │
│        │                                │  (talks to the app via a socket)  │
│        └──────────► LabVPNCore ◄────────┘  (CLI → app only, never helper)  │
│                     • profiles, state machine, Keychain                     │
│                     • AuthRunner: bundled openconnect --authenticate        │
│                       (unprivileged) → cookie + server cert fingerprint      │
│                     • Sleep/wake (NSWorkspace) + NWPathMonitor               │
│                                │  XPC (code-signing-checked)                 │
└────────────────────────────────┼───────────────────────────────────────────┘
                                 ▼
┌──────────────── labvpn-helper (root LaunchDaemon) ────────────────────────┐
│ • Starts root-owned openconnect --cookie-on-stdin --servercert <fp>       │
│   with the root-owned vpnc-script wrapper (forces full tunnel)            │
│ • Sends signals: SIGHUP (drop, keep session),                             │
│   SIGTERM (log off session)                                                │
│ • Reports process state/exit codes back to the app                        │
└───────────────────────────────────────────────────────────────────────────┘
```

### 5.1 Authentication and tunnel run in separate processes

- **Auth runs unprivileged in the app** using
  `openconnect --protocol=anyconnect --authenticate …`. It prints `COOKIE`,
  `HOST`, `CONNECT_URL`, `FINGERPRINT` and `RESOLVE` and **does not need
  root**.
  - ZBH: `--user <kennung> --passwd-on-stdin`, with the password piped from
    the Keychain.
  - UHH: `--user <kennung> --external-browser /usr/bin/open` (the flag takes
    an executable; `open` means the user's default browser).
- **The tunnel runs as root in the helper** using
  `openconnect --protocol=anyconnect --cookie-on-stdin --servercert <fp> --resolve <RESOLVE> --reconnect-timeout <n> --script <wrapper> <CONNECT_URL>`.
  Use `CONNECT_URL`, not the profile host: it keeps the `/VPNZBH` path and may
  name a different load-balanced node. `--reconnect-timeout` matches
  `fallbackToDirectAfterSeconds`, so openconnect's retry loop ends when the
  fallback starts.
- Benefits: the root helper never sees passwords, never opens browsers, and
  never parses auth forms. The cookie is the only secret it receives, and it
  is passed over XPC and stdin, never on argv or disk.

### 5.2 Full tunnel enforcement

- Ship `vpnc-script` plus a small wrapper script. The wrapper **unsets**
  `CISCO_SPLIT_INC`, every `CISCO_SPLIT_INC_*`, the matching
  `CISCO_IPV6_SPLIT_INC*` variables and `CISCO_SPLIT_DNS` before running
  `vpnc-script`. Do not set `CISCO_SPLIT_INC=0`: vpnc-script only tests that
  the variable is non-empty, so `0` installs **no** default route.
- DNS: use the VPN-pushed DNS servers and search domains, applied through
  vpnc-script's macOS `scutil` path, and restored on disconnect. Unsetting
  `CISCO_SPLIT_DNS` keeps DNS global rather than per-domain.
- **IPv6:** if the gateway assigns no IPv6 address, the wrapper adds `-reject`
  routes for `::/1` and `8000::/1` on connect and removes them on disconnect.
  Otherwise dual-stack publisher sites would be reached directly from the home
  IP. `-reject` rather than `-blackhole`, so apps fail at once and use IPv4.
  This applies only while the tunnel is up, so it isn't a kill switch.
- **IPv4 gateway:** the app resolves the gateway's A record and passes
  `--resolve=<host>:<ipv4>` to `--authenticate`, so `RESOLVE` carries it into the
  tunnel. A redirect escapes that pin (`vpn.rrz` sends UHH logins to `vpn-asa*`,
  reached over IPv6), so after login a non-IPv4 `RESOLVE` is replaced with the A
  record of the `CONNECT_URL` host. vpnc-script can't add a host route to an IPv6 gateway on macOS (found
  live: it passes every IPv6 default route at once), and without that route the
  reject routes would block reconnects. Both gateways have A records.
- Each profile has a **"Force full tunnel"** setting (default **on**). Turning
  it off uses the gateway-pushed routes unchanged (debug/escape hatch).
- **Optional MTU setting per profile** (default: openconnect auto). The ZBH
  wiki documents a Cisco bug fixed by MTU **1347**. Offer it as a preset, but
  only apply it if needed.

### 5.3 Privileged helper

- The app carries the helper in `Contents/Library/Helper`, signed and notarized
  with it. Settings → Helper, or the first connect, runs the bundled
  `install-helper.sh` through the macOS admin prompt. The script checks the bundle's
  signature against the Team ID, then copies everything to
  `/Library/PrivilegedHelperTools/labvpn/` (root-owned, not user-writable) and loads a
  LaunchDaemon. Nothing root runs may be user-writable, so root never runs from the
  app bundle or `/opt/homebrew`. `HelperConstants.version` triggers an update.
- `SMAppService.daemon` was rejected: root would run from a bundle its user can
  write to.
- The XPC listener accepts only the signed app, through
  `setCodeSigningRequirement` (Apple-anchored, identifier `de.mariusrueve.labvpn`,
  Team ID `BRW9TTP8R5`), and only from the UID recorded at install time.
- The helper runs **only the root-owned openconnect and scripts**.
- Commands accepted (closed set, validated arguments):
  - `connect(connectURL, cookie, fingerprint, resolve?, mtu?, reconnectTimeout, forceFullTunnel)`
  - `disconnectKeepSession()`
  - `disconnectLogoff()`
  - `status()`
- `connectURL` must be https with a valid hostname, and every value is checked so
  it can't act as an openconnect flag. Arbitrary flags are not accepted. Any
  gateway is allowed: limiting hosts doesn't fit a general AnyConnect client, and
  only the signed app reaches the helper.
- One tunnel at a time. Connecting to another profile logs off the current one.
- If the client quits or crashes, the helper sees the XPC connection drop and
  tears the tunnel down (log off).
- The helper records openconnect's pid. On start it stops an orphan from a
  previous helper. On start, and if openconnect is killed outright, it runs the
  wrapper's cleanup, which restores the saved default route and DNS. vpnc-script
  deletes the default route on connect, so a killed tunnel would otherwise leave
  the Mac offline.

### 5.4 Bundled openconnect

- Ship a pinned `openconnect` (≥ 9.12) and its dylibs, relinked relative to the
  executable, plus `vpnc-script`.
- **Build from source; don't copy Homebrew's bottle.** M0 testing showed the
  bottle loads `p11-kit-trust.dylib` from `/opt/homebrew` even on the tunnel
  path, and GnuTLS and p11-kit read config from there. As root, that would let
  any process running as the user gain root. GnuTLS is therefore built without
  p11-kit, with its priority file in the root-owned directory.
- `scripts/build-openconnect.sh` pins the source tarball hashes and fails if
  anything still links outside the staged tree. It also strips vpnc-script's
  `networksetup -setdnsservers` calls: on disconnect they clear hand-set DNS, and
  on connect they always fail. `scutil` does the real work.
- **Licensing:** openconnect is LGPL-2.1, and vpnc-scripts is GPL. Ship them
  as separate dynamically linked binaries and scripts. Include their licenses
  and a source link or offer under `Contents/Resources/ThirdParty/`.
  labvpn's own code is Apache-2.0, matching labroute. GnuTLS (LGPL-2.1+), nettle
  and gmp (LGPL-3+ / GPL-2+) need the same treatment.

---

## 6. Connection state machine

States: `disconnected` → `authenticating` → `connecting` → `connected` →
(`reconnecting` ↔ `connected`) → `disconnecting` → `disconnected`, plus
`fallbackDirect` (tunnel dropped, session kept, retrying), `needsUserAction`
(e.g. SSO in browser, wrong password) and `failed(reason)`.

### 6.1 Sleep / wake

| Event | Action |
|---|---|
| `willSleep` | Do nothing. openconnect keeps the session; the cookie is retained in memory. |
| `didWake` | Run the health check at once. If it fails, or openconnect has exited, stop with **SIGHUP** and start a new openconnect process with the cookie. |
| Reconnect succeeds | `connected`, but only once the health check passes. No UI, apart from a brief icon change. |
| Health check fails 3 times while awake | Same recovery as above. |
| Cookie rejected / session expired | Re-authenticate (§6.3), then reconnect with the new cookie. |

**Health check.** A running openconnect doesn't prove the tunnel works. In M0,
it reported a successful reconnect after sleep and then passed no traffic, and
ZBH sets `DPD 0`, so it can't detect this itself. Every 5 s, send a DNS query to
a gateway-pushed server on a socket bound to the tunnel interface. A new process
fixed this case by hand, so recovery starts one rather than signalling the old
one. If the check never passes on a fresh connection, warn and don't use it, so a
broken check can't restart a working tunnel.

### 6.2 Network changes (Wi-Fi ↔ Ethernet ↔ hotspot)

- `NWPathMonitor`: when the primary **physical** network changes, or comes back,
  start a new openconnect process with the cookie at once. Debounce for about
  2 s. Compare the interface name **and its IPv4 address**: an iPhone hotspot
  stays on `en0`. Ignore `utun*` and other tunnel interfaces: the tunnel coming
  up changes the primary path, and reacting to that would cause a reconnect loop.
  The old process is dropped rather than signalled: in M0, waiting for it and
  the health check took 39 s.
- **Fall back to direct (no kill switch):** if the tunnel isn't
  re-established within **15 s** (configurable), tear it down with **SIGHUP**,
  which makes openconnect exit but keeps the session on the gateway.
  vpnc-script restores routes and DNS, so traffic goes out directly. Each retry
  is a **new openconnect process**: the app calls `connect` again with its
  cookie, with backoff (5 s, 10 s, 30 s, 60 s, then every 60 s), while the
  cookie is valid. The menu bar shows `reconnecting (direct)`.

### 6.3 Re-authentication

- A rejected cookie is detected from openconnect's exit status and log output
  (exact signal recorded in M0).
- **ZBH profile:** fully automatic. Read the password from the Keychain and
  run `--authenticate --passwd-on-stdin`, with no prompt. Ask the user only
  if the password is rejected; then update the Keychain item after a
  successful login.
- **UHH profile:** needs SSO. Post a notification ("UHH VPN session expired
  — click to sign in"). The click opens the browser flow. Don't open the
  browser automatically after wake unless the user enables
  "Open SSO automatically" (default off).
- Stop on the first rejected password and go to `needsUserAction`, so retries
  can't lock the account. Network errors during auth keep retrying with backoff,
  including on first connect: at login, Wi-Fi may join after the app starts.
- Log in again only if openconnect exited by itself, which is what a rejected
  cookie looks like. A tunnel that is alive but silent points at the network, and
  logging in again would stack up sessions on the gateway.
- SSO sign-in times out after 5 minutes, because nothing reports a closed browser.

### 6.4 Explicit disconnect

- From the menu or CLI: **SIGTERM** (log off the session on the gateway) and
  drop the cookie.

---

## 7. Profiles & configuration

```jsonc
// ~/Library/Application Support/labvpn/profiles.json  (no secrets)
{
  "defaultProfile": "zbh",
  "profiles": [
    {
      "id": "zbh",
      "name": "ZBH VPN",
      "host": "vpn2-aux2.rrz.uni-hamburg.de/VPNZBH",
      "username": "<kennung>",
      "auth": "password",          // password | browser-sso
      "forceFullTunnel": true,
      "mtu": null                   // e.g. 1347
    },
    {
      "id": "uhh",
      "name": "UHH VPN",
      "host": "vpn.rrz.uni-hamburg.de",
      "username": "<kennung>",
      "auth": "browser-sso",
      "forceFullTunnel": true,
      "mtu": null
    }
  ],
  "settings": {
    "launchAtLogin": true,
    "connectOnLaunch": true,
    "autoReconnect": true,
    "fallbackToDirectAfterSeconds": 15,
    "openSSOAutomatically": false
  }
}
```

- **No built-in profiles.** First run asks for a gateway and login, or takes a
  `.labvpn` setup file, by double-click or from the first-run window.
  `examples/uni-hamburg.labvpn` holds ZBH and UHH. Importing never changes the
  default of an existing setup, so a file can't quietly redirect it.
- **Secrets:** Keychain generic password, service `de.mariusrueve.labvpn`,
  account `<profile id>:<username>`. Cookies stay in memory only and are never
  persisted. labvpn uses the login keychain. The stable Developer ID signature
  means updates don't ask for access again. The data-protection keychain was
  rejected: it needs a provisioning profile, which this SwiftPM build doesn't have.
- **Server certificate:** rely on the system trust store, and refuse a
  certificate that doesn't chain to it. There is no pinning and no way to accept
  one: a changed but trusted certificate is normal (yearly renewal, load-balanced
  nodes). The auth step's `FINGERPRINT` is always passed to the tunnel as
  `--servercert`.
- **Setup file sharing:** export/import a `.labvpn` file (the profiles JSON
  without username, fingerprint or secrets) to hand to colleagues.

---

## 8. User interface

### 8.1 Menu bar

- Icon states: disconnected, connecting/reconnecting (animated), connected,
  needs action (badge), direct-fallback.
- Menu:
  - Status line, e.g. `Connected · ZBH · 12m · 141.xx.xx.xx` (tunnel IP).
  - **Connect / Disconnect** for the default profile.
  - **Connect to ▸** with the profile list.
  - **Sign in…**, shown only in `needsUserAction`.
  - Settings…, View log…, Quit.

### 8.2 Settings window (SwiftUI, tabs)

- **Profiles:** list, add/edit/delete, set default, test connection,
  per-profile MTU and full-tunnel toggles, setup file import/export.
- **General:** launch at login (`SMAppService.mainApp`), connect on launch, auto-reconnect,
  fallback timeout, open SSO automatically.
- **Helper:** installed version, with Install, Update and Uninstall.
- **About/Logs:** version, bundled openconnect version, open log.

### 8.3 Notifications

Send notifications only for: session expired (UHH), auth failure, helper not
approved, fingerprint change, and moving to direct fallback for longer than
60 s. Don't notify for successful silent reconnects.

---

## 9. CLI (`labvpn`)

Talks to the running app over a Unix domain socket
(`~/Library/Application Support/labvpn/labvpn.sock`, mode 0600, JSON lines, peer
UID checked). If the app isn't running, it launches it. `labvpn connect` waits
until connected or failed (`--timeout <s>`, `--no-wait`). The cask installs the
CLI with a `binary` stanza.

`status` never launches the app, so scripts can poll it safely. It prints
`connected` as its first word only while connected, and exits 2 if the app isn't
running. `labvpn setup <username>` updates the username and password of existing
profiles without the app.

```
labvpn status [--json]
labvpn connect [<profile>]
labvpn disconnect
labvpn reconnect
labvpn profiles
labvpn log [--follow]
```

Exit codes: `0` ok, `1` generic error, `2` app/helper not available,
`3` needs user action (SSO / password).

---

## 10. Logging & diagnostics

- `os.Logger`, subsystem `de.mariusrueve.labvpn`, categories `app`, `auth`,
  `helper`, `openconnect`.
- openconnect stdout and stderr are captured by the helper and forwarded to
  the log. Cookies and passwords are always redacted.
- The app also writes a redacted log to `~/Library/Logs/labvpn/labvpn.log`, used by
  "View log…" and `labvpn log`. `log show` returned nothing for the helper in M0.
- **Export diagnostics** in Settings writes a zip containing the redacted log,
  profiles (without usernames), openconnect version, and route/DNS snapshots.

---

## 11. Distribution

- Homebrew: `brew install --cask mariusrueve/tap/labvpn`, matching labroute.
- From source: `scripts/build.sh`, then `scripts/install.sh`. The helper only
  accepts builds signed with the Team ID above.
- Signed with a Developer ID, hardened runtime, notarized and stapled by
  `scripts/release.sh`. Team ID `BRW9TTP8R5`.
- arm64, macOS 15 or later. Every binary is built for 15.0, whatever the build
  Mac runs, and the build fails otherwise.
- README: setup in three steps, a note that ZBH VPN needs access level ≥ 2 and
  admin activation, and the MTU 1347 tip.

---

## 12. Acceptance criteria (v1)

1. On a fresh Mac, installing via the cask, entering username and password,
   and approving the helper leads to a connected ZBH VPN in under 2 minutes.
2. While connected:
   - `curl ifconfig.me` shows a UHH IP.
   - IPv6 sites go through IPv4 (`curl -6 https://ifconfig.me` fails at once,
     unless the gateway provides IPv6).
   - **A paywalled article (e.g. ACS, Elsevier or Wiley) opens in a browser, and
     its PDF can be saved to Zotero.** Zotero's own "Find Full Text" isn't
     required for publishers that use a browser challenge.
   - ssh to a ZBH server works without a jump host.
3. Close the lid for 1 h and wake the Mac: the VPN is back within 15 s of the
   network being available, with no prompt (ZBH).
4. Close the lid overnight and wake the Mac: the VPN is back without a prompt
   (ZBH, through silent Keychain re-auth).
5. Switching Wi-Fi to an iPhone hotspot reconnects within 15 s. If the hotspot
   has no internet, traffic falls back to direct and recovers when internet
   returns.
6. Disconnecting restores the original routes and DNS (`scutil --dns` and
   `netstat -rn` match the pre-connect snapshot).
7. UHH profile: connecting opens the browser SSO and then connects. After the
   session expires, a notification leads to a working re-login.
8. `labvpn status --json` reflects the menu bar state at all times.
9. Quitting the app logs off the session and restores the network.

---

## 13. Milestones

| # | Milestone | Content |
|---|---|---|
| M0 | **Feasibility spike** | (a) `--authenticate` → `--cookie-on-stdin` split works on both gateways, including SSO through `--authenticate --external-browser`; (b) what each gateway pushes (`CISCO_SPLIT_INC`), and whether forcing a full tunnel actually carries publisher traffic; (c) root-owned LaunchDaemon + XPC with a peer UID check; (d) a relocatable openconnect built from source on arm64, with nothing loaded from user-writable paths; (e) SIGUSR2 reconnect after wake, and how long the cookie lives. |
| M1 | Core ZBH | Helper, state machine, Keychain password flow, menu bar connect/disconnect, full tunnel, logging, CLI over the control socket. |
| M2 | Resilience | Sleep/wake, NWPathMonitor, direct fallback + backoff, silent re-auth, launch at login. |
| M3 | UHH SSO | Browser SSO profile, expiry notification, "Sign in…" flow. |
| M4 | Polish | Settings window, setup file import/export, diagnostics export. |
| M5 | Distribution | Build scripts, cask in `mariusrueve/tap`, README, third-party licenses. |

---

## 14. Risks & open questions

| ID | Risk / question | Mitigation |
|---|---|---|
| R1 | A user-level process can edit `profiles.json` to point the app at another gateway. | Accepted: the gateway still needs a trusted certificate, and the same process could already read the user's data. Helper clients are restricted by Team ID. |
| R2 | The gateway enforces split tunnel server-side and drops non-UHH destinations even with a forced default route. | M0 spike (b). If so, document it and fall back to the gateway routes plus a configurable list of extra subnets for publishers. |
| R3 | `--authenticate` with `--external-browser` may behave differently from a normal connect for UHH SSO. | Resolved in M0: it works, including the redirect to `vpn-asa*`. |
| R4 | UHH needs a new browser sign-in at least every 24 h, and also after any quit, restart or profile switch, because the cookie is never stored and quitting logs off. ZBH sessions last 14 days, and ZBH logs in again silently. | Accepted: ZBH is the default, and a UHH sign-in took about 4 s. Sleep and network changes reuse the cookie. Storing it was considered and rejected. |
| R5 | A killed tunnel leaves no default route and stale DNS. | The helper restores them through the wrapper's cleanup (§5.3). |
| R6 | RRZ/ZBH policy on third-party VPN clients. | Ask the ZBH admins (ticket.zbh@uni-hamburg.de) before sharing with colleagues. Personal use doesn't depend on this. |
| R7 | Bundling openconnect and its dependencies adds build and security-update burden. | Pin versions, use a scripted build, and check upstream releases on each labvpn release. |

---

## 15. Testing

- Unit tests (`swift test`): `--authenticate` output parser, helper argument
  validation, log redaction, and later the state machine with a fake helper and
  clock, plus profile import/export.
- `Tests/wrapper-test.sh` runs the wrapper against a fake vpnc-script and `route`.
- Live checks need credentials, `sudo` and real network changes, so they follow
  [testing.md](testing.md).
