---
name: diagnose
description: Find out why labvpn won't connect, drops, or misbehaves, from its log and the Mac's network state, and explain the cause in plain language. Use when the owner reports a VPN problem or asks whether something is labvpn's fault or the gateway's.
---

# Diagnose a labvpn problem

Read only: look, don't change routes, kill processes or reinstall without asking.

1. **Log.** `~/Library/Logs/labvpn/labvpn.log` (or `labvpn log`). Read the last few hundred
   lines, then search back to where the trouble began: the first error, not the last.
   Compare a failing profile with one that works.
2. **Network state**, as needed:
   - `route -n get <gateway IP>` and `netstat -rnl -f inet`: the route to the gateway, and
     the source address it uses.
   - `ipconfig getifaddr en0`: the Mac's current address.
   - `nc -vz -G 5 <gateway IP> 443`: can the Mac reach the gateway at all, without labvpn?
   - `pgrep -lf openconnect`, `ls /var/run/vpnc /var/run/labvpn`, `cat /var/run/labvpn/connect-env.txt`.
3. **Match it against `docs/decisions.md`**, which lists past causes. Known signs:
   - `Can't assign requested address` to one gateway while others work: a leftover host
     route to the gateway with an old source address (`netstat -rnl` shows it). Fix now:
     `sudo route delete -host <gateway IP>`. Fixed in 0.3.2; if it happens again, find out
     why cleanup didn't run.
   - `Server certificate verify failed: signer not found` on its own is usually harmless if
     the connection then succeeds.
   - DTLS `Error in the push function`, then "passing no traffic": the network changed or slept;
     recovery should start a new process within seconds.
4. **Answer the owner's question first** (labvpn, the gateway, or their network), then the
   evidence in two or three log lines, the fix for now, and whether labvpn needs a code fix.
   If it does, offer to make it, and add the lesson to `docs/decisions.md` with the fix.

Never paste usernames, cookies or full logs into anything outside this conversation.
