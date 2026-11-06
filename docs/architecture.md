# Architecture

```
labvpn CLI ──Unix socket──► labvpn.app (your user)
                             │  logins, recovery, Keychain, menu, Settings
                             │  XPC, signed clients only
                             ▼
                            labvpn-helper (root LaunchDaemon)
                             │  starts and signals
                             ▼
                            openconnect ──► labvpn-vpnc-wrapper.sh ──► vpnc-script
                                            forces full tunnel         routes and DNS
```

## Connecting

1. `Authenticator` runs `openconnect --authenticate` **unprivileged**. It gets the
   password from the Keychain, or opens the browser for SSO. It returns a cookie.
2. The app sends the cookie to the helper in a `ConnectRequest`, which validates it.
3. The helper starts openconnect as root, with the cookie on stdin.
4. The wrapper removes split-tunnel settings, runs `vpnc-script`, and blocks direct IPv6.

Root never sees passwords, browsers or login forms.

## Staying connected

`TunnelController` runs one session on a worker thread and reports `ConnectionState`.
Every 5 seconds `TunnelSupervisor` runs `TunnelProbe`: a DNS query to a gateway-pushed
server, on a socket bound to the tunnel. Recovery always starts a **new** openconnect
process with the saved cookie:

| Trigger | Response |
|---|---|
| Physical network changed (`NetworkWatcher`) | Recover now |
| Woke from sleep | Check now; recover on one failure |
| 3 failed checks | Recover |
| openconnect exited | Recover; log in again if the cookie looks rejected |

While offline, traffic goes direct and retries back off: 5, 10, 30, then every 60 s.

## Install and update

The helper payload ships in `labvpn.app/Contents/Library/Helper`. Through an admin prompt,
`install-helper.sh` checks the signature and copies it to
`/Library/PrivilegedHelperTools/labvpn`. The app compares `HelperConstants.version` with the
running helper and offers an update when they differ.

If openconnect is killed outright, the helper runs the wrapper's `labvpn-cleanup`, which
restores the default route and DNS.

## Files on a user's Mac

| Path | Holds |
|---|---|
| `~/Library/Application Support/labvpn/profiles.json` | Profiles and settings, no secrets |
| `~/Library/Application Support/labvpn/labvpn.sock` | CLI to app socket |
| `~/Library/Logs/labvpn/labvpn.log` | Redacted log |
| Login Keychain, service `de.mariusrueve.labvpn` | Passwords |
| `/var/run/labvpn/` | Tunnel details and openconnect pid |
