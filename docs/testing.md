# Testing

`scripts/test.sh` runs unit tests, shell tests of the root scripts, and consistency checks.
CI runs it on every push. None of it touches a real VPN.

## Live checks

These need a real gateway and account. Run the ones your change touches, and
`labvpn log` shows what happened.

**Tunnel**
- [ ] Connect, then `scripts/check-tunnel.sh`: exit address is the VPN's, gateway is IPv4, 2 of 2 reject routes, direct IPv6 blocked
- [ ] Before connecting `scripts/net-snapshot.sh save before`, after quitting `save after`, then `diff before after`: routes and DNS match, apart from neighbour-cache noise
- [ ] Quit the app: session logs off

**Recovery** (target: under 15 s, no prompt)
- [ ] Wi-Fi to a phone hotspot, and back
- [ ] Lid closed for 10 minutes; overnight
- [ ] `sudo pkill -9 -x openconnect`: default route and DNS return, tunnel restarts
- [ ] Wi-Fi off, launch the app, Wi-Fi on: connects by itself
- [ ] Hotspot with no internet: traffic goes direct, then recovers

**Sign-in**
- [ ] Wrong password: stops at once, no repeated attempts
- [ ] Browser sign-in; closing the browser: Cancel works, or it times out after 5 minutes
- [ ] Session expiry: notification appears and leads to sign-in

**Install**
- [ ] Fresh install: first-run window, setup file, helper install
- [ ] Update: helper updates, with no Keychain prompt
- [ ] Settings → Helper: Uninstall, then Install
- [ ] Launch at Login after a reboot
