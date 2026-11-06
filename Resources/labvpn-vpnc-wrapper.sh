#!/bin/sh
# openconnect --script target. Runs as root from the root-owned install tree.
# Forces a full tunnel, then hands over to the stock vpnc-script (SPEC 5.2).
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

REAL_SCRIPT=/Library/PrivilegedHelperTools/labvpn/scripts/vpnc-script
ROUTE=/sbin/route
SCUTIL=/usr/sbin/scutil
IFCONFIG=/sbin/ifconfig
STATE_DIR=/var/run/labvpn
VPNC_DIR=/var/run/vpnc
RESOLV_CONF=/etc/resolv.conf
IPV6_MARKER="$STATE_DIR/ipv6-rejected"

mkdir -p "$STATE_DIR"

ipv6_reject_add() {
  # Not needed if the tunnel carries IPv6. The gateway must be reached over
  # IPv4: these routes would otherwise block new connections to it, because
  # vpnc-script fails to add a host route to an IPv6 gateway on macOS.
  [ -z "$INTERNAL_IP6_ADDRESS" ] && [ -z "$INTERNAL_IP6_NETMASK" ] || return 0
  "$ROUTE" -n add -inet6 ::/1 ::1 -reject >/dev/null 2>&1 || echo "labvpn: could not add ::/1 reject route" >&2
  "$ROUTE" -n add -inet6 8000::/1 ::1 -reject >/dev/null 2>&1 || echo "labvpn: could not add 8000::/1 reject route" >&2
  : > "$IPV6_MARKER"
}

ipv6_reject_remove() {
  [ -e "$IPV6_MARKER" ] || return 0
  "$ROUTE" -n delete -inet6 ::/1 >/dev/null 2>&1
  "$ROUTE" -n delete -inet6 8000::/1 >/dev/null 2>&1
  rm -f "$IPV6_MARKER"
}

# Undoes what vpnc-script's disconnect would have done, for a tunnel that died
# without running it. vpnc-script deletes the default route on connect, so
# without this a killed openconnect leaves the Mac offline (SPEC risk R5).
restore_after_crash() {
  ls "$VPNC_DIR"/defaultroute.* >/dev/null 2>&1 || return 0
  tundev=$(sed -n 's/^TUNDEV=//p' "$STATE_DIR/connect-env.txt" 2>/dev/null)
  gateway=$(sed -n 's/^VPNGATEWAY=//p' "$STATE_DIR/connect-env.txt" 2>/dev/null)

  if ! "$ROUTE" -n get default >/dev/null 2>&1; then
    for file in "$VPNC_DIR"/defaultroute.*; do
      saved=$(cat "$file" 2>/dev/null)
      [ -n "$saved" ] && "$ROUTE" -n add default $saved >/dev/null 2>&1 && break
    done
  fi
  [ -n "$gateway" ] && "$ROUTE" -n delete -host "$gateway" >/dev/null 2>&1

  if [ -n "$tundev" ] && ! "$IFCONFIG" "$tundev" >/dev/null 2>&1; then
    printf 'open\nremove State:/Network/Service/%s/IPv4\nremove State:/Network/Service/%s/DNS\nclose\n' \
      "$tundev" "$tundev" | "$SCUTIL" >/dev/null 2>&1
  fi

  if grep -q '^#@VPNC_GENERATED@' "$RESOLV_CONF" 2>/dev/null; then
    for file in "$VPNC_DIR"/resolv.conf-backup.*; do
      [ -f "$file" ] && cat "$file" > "$RESOLV_CONF" && break
    done
  fi
  rm -f "$VPNC_DIR"/defaultroute.* "$VPNC_DIR"/defaultroute_ipv6.* "$VPNC_DIR"/resolv.conf-backup.*
}

# Called by the helper at startup and after openconnect is killed.
if [ "$reason" = "labvpn-cleanup" ]; then
  ipv6_reject_remove
  restore_after_crash
  exit 0
fi

# Record what the gateway pushed, before anything is unset (M0 spike b).
if [ "$reason" = "connect" ]; then
  env | grep -E '^(CISCO_|INTERNAL_|VPNGATEWAY=|TUNDEV=)' | sort > "$STATE_DIR/connect-env.txt"
  chmod 644 "$STATE_DIR/connect-env.txt"
fi

if [ "${LABVPN_FORCE_FULL_TUNNEL:-1}" != "0" ]; then
  # Unset, never set to 0: vpnc-script only tests for a non-empty value, and
  # CISCO_SPLIT_INC=0 would install no default route.
  for name in $(env | sed -n 's/^\(CISCO_SPLIT_INC[A-Z0-9_]*\)=.*/\1/p; s/^\(CISCO_IPV6_SPLIT_INC[A-Z0-9_]*\)=.*/\1/p'); do
    unset "$name"
  done
  unset CISCO_SPLIT_DNS
fi

case "$reason" in
  disconnect) ipv6_reject_remove ;;
esac

/bin/sh "$REAL_SCRIPT"
status=$?

case "$reason" in
  connect) [ "$status" -eq 0 ] && ipv6_reject_add ;;
esac

exit "$status"
