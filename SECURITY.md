# Security

labvpn runs a root helper, because creating a tunnel and changing routes need root.

## Trust model

- The helper accepts XPC connections only from the signed app (Team ID
  `BRW9TTP8R5`) running as the user who installed it.
- Its commands are a closed set. It checks every value, so nothing can act as an
  openconnect flag.
- Everything root runs is copied to root-owned
  `/Library/PrivilegedHelperTools/labvpn/` at install. Root never runs files from the
  app bundle or from Homebrew.
- openconnect and GnuTLS are built without p11-kit, so nothing loads plugins or
  configuration from user-writable paths.
- Logins run unprivileged in the app. The helper never sees your password. Session
  cookies stay in memory and reach openconnect through stdin.
- Passwords are stored in your login Keychain.

## Known limits

- A process running as you can edit `profiles.json` and point the app at another
  gateway. That gateway still needs a certificate your Mac trusts.
- There's no kill switch. Traffic goes direct while the VPN is reconnecting.

## Reporting

Please report vulnerabilities privately through GitHub's security advisories for
this repository.
