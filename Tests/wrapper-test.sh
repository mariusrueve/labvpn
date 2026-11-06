#!/bin/bash
# Runs the wrapper with a fake vpnc-script and route, without root.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/vpnc-script" <<FAKE
#!/bin/sh
env | grep -E '^(CISCO_|reason=)' | sort > "$tmp/seen-\$reason"
exit \${FAKE_STATUS:-0}
FAKE
cat > "$tmp/route" <<FAKE
#!/bin/sh
echo "\$*" >> "$tmp/route.log"
case "\$*" in *"get default"*) [ -z "\$FAKE_NO_DEFAULT" ] ;; esac
FAKE
cat > "$tmp/scutil" <<FAKE
#!/bin/sh
cat >> "$tmp/scutil.log"
FAKE
cat > "$tmp/ifconfig" <<FAKE
#!/bin/sh
[ -z "\$FAKE_NO_TUN" ]
FAKE
chmod +x "$tmp/route" "$tmp/scutil" "$tmp/ifconfig"
mkdir -p "$tmp/vpnc"
sed -e "s#^REAL_SCRIPT=.*#REAL_SCRIPT=$tmp/vpnc-script#" \
    -e "s#^ROUTE=.*#ROUTE=$tmp/route#" \
    -e "s#^SCUTIL=.*#SCUTIL=$tmp/scutil#" \
    -e "s#^IFCONFIG=.*#IFCONFIG=$tmp/ifconfig#" \
    -e "s#^VPNC_DIR=.*#VPNC_DIR=$tmp/vpnc#" \
    -e "s#^RESOLV_CONF=.*#RESOLV_CONF=$tmp/resolv.conf#" \
    -e "s#^STATE_DIR=.*#STATE_DIR=$tmp/state#" Resources/labvpn-vpnc-wrapper.sh > "$tmp/wrapper.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
run() { env "$@" /bin/sh "$tmp/wrapper.sh"; }
split=(CISCO_SPLIT_INC=2 CISCO_SPLIT_INC_0_ADDR=10.0.0.0 CISCO_SPLIT_INC_1_ADDR=134.100.0.0
       CISCO_IPV6_SPLIT_INC=1 CISCO_IPV6_SPLIT_INC_0_ADDR=2001:db8:: CISCO_SPLIT_DNS=uni-hamburg.de
       CISCO_DEF_DOMAIN=uni-hamburg.de VPNGATEWAY=134.100.1.1)

run reason=connect "${split[@]}"
grep -q SPLIT "$tmp/seen-connect" && fail "split variables reached vpnc-script"
grep -q CISCO_DEF_DOMAIN "$tmp/seen-connect" || fail "unrelated variable was removed"
grep -q 'CISCO_SPLIT_INC=2' "$tmp/state/connect-env.txt" || fail "pushed values not recorded"
[[ "$(grep -c -- '-reject' "$tmp/route.log")" == 2 ]] || fail "IPv6 reject routes not added"

run reason=disconnect "${split[@]}"
grep -q SPLIT "$tmp/seen-disconnect" && fail "split variables reached disconnect"
[[ "$(grep -c delete "$tmp/route.log")" == 2 ]] || fail "IPv6 reject routes not removed"
[[ ! -e "$tmp/state/ipv6-rejected" ]] || fail "IPv6 marker left behind"

rm -f "$tmp/route.log"
run reason=connect LABVPN_FORCE_FULL_TUNNEL=0 "${split[@]}"
grep -q 'CISCO_SPLIT_INC=2' "$tmp/seen-connect" || fail "force-off should keep gateway routes"
run reason=labvpn-cleanup
[[ "$(grep -c delete "$tmp/route.log")" == 2 ]] || fail "cleanup did not remove routes"

rm -f "$tmp/route.log"
run reason=connect INTERNAL_IP6_ADDRESS=2001:db8::5 VPNGATEWAY=134.100.1.1
[[ ! -e "$tmp/route.log" ]] || fail "tunnel with IPv6 must not reject IPv6"
run reason=connect VPNGATEWAY=2001:db8::1
[[ "$(grep -c -- '-reject' "$tmp/route.log")" == 2 ]] || fail "an IPv6 gateway must still block direct IPv6"
run reason=labvpn-cleanup
rm -f "$tmp/route.log"

status=0; run reason=connect FAKE_STATUS=3 VPNGATEWAY=134.100.1.1 || status=$?
[[ "$status" == 3 ]] || fail "vpnc-script failure not propagated"
[[ ! -e "$tmp/route.log" ]] || fail "reject routes added after a failed connect"

# Crash cleanup: a healthy Mac is left alone.
rm -f "$tmp/route.log"
run reason=labvpn-cleanup
grep -qs add "$tmp/route.log" && fail "cleanup added routes without saved state"

# Crash cleanup: tunnel died with the default route deleted.
printf 'TUNDEV=utun6\nVPNGATEWAY=134.100.57.178\n' > "$tmp/state/connect-env.txt"
echo 192.168.178.1 > "$tmp/vpnc/defaultroute.123"
printf 'nameserver 192.168.178.1\n' > "$tmp/vpnc/resolv.conf-backup.123"
printf '#@VPNC_GENERATED@\nnameserver 134.100.33.240\n' > "$tmp/resolv.conf"
rm -f "$tmp/route.log"
run reason=labvpn-cleanup FAKE_NO_DEFAULT=1 FAKE_NO_TUN=1
grep -q 'add default 192.168.178.1' "$tmp/route.log" || fail "default route not restored"
grep -q 'delete -host 134.100.57.178' "$tmp/route.log" || fail "gateway route not removed"
grep -q 'remove State:/Network/Service/utun6/DNS' "$tmp/scutil.log" || fail "DNS keys not removed"
grep -q '192.168.178.1' "$tmp/resolv.conf" || fail "resolv.conf not restored"
[[ -z "$(ls "$tmp/vpnc")" ]] || fail "stale vpnc files left behind"

# Crash cleanup: an existing default route is not replaced.
echo 192.168.178.1 > "$tmp/vpnc/defaultroute.124"
rm -f "$tmp/route.log"
run reason=labvpn-cleanup
grep -q 'add default' "$tmp/route.log" && fail "working default route was replaced"

# The staged script must not touch the user's DNS settings.
grep -q 'networksetup -setdnsservers' Resources/vpnc-script && fail "vpnc-script still resets DNS"

# The real script must install a default route once the variable is unset.
grep -q 'elif \[ -n "$INTERNAL_IP4_ADDRESS" \]' Resources/vpnc-script \
  || fail "vpnc-script default-route branch changed; recheck the wrapper"
echo "wrapper tests passed"
