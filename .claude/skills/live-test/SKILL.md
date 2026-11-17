---
name: live-test
description: Turn the current changes into a short live-test checklist for the owner, taken from docs/testing.md. Use after changing tunnel, routing, recovery, sign-in, helper or install code, or when the owner asks what to test.
---

# Live-test checklist

Unit and shell tests can't prove a VPN change works. The owner tests on real hardware.

1. See what changed: `git diff` and `git log` since the last tag or the start of the work.
2. Pick only the checks in `docs/testing.md` those changes could break:
   - `Resources/*.sh`, `labvpn-helper`, routes: **Tunnel** checks, plus `sudo pkill -9 -x openconnect`.
   - `TunnelController`, `TunnelSupervisor`, `TunnelProbe`, `NetworkWatcher`: **Recovery**.
   - `Authenticator`, `Keychain`, `AuthResult`: **Sign-in**.
   - `HelperInstaller`, install scripts, `HelperConstants.version`: **Install**, including Update.
3. If the app must be rebuilt, say so first: `scripts/build.sh && scripts/install.sh`, and that
   a helper update asks for the admin password once.
4. Give the owner a numbered list: each step what to do, what should happen, roughly how long.
   Five steps or fewer where possible. Ask them to send `labvpn log` if anything differs.
