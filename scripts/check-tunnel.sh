#!/bin/bash
# M0 spike (b). Run while connected. Reads only; needs no sudo.
echo "IPv4 exit address: $(curl -4 -s -m 8 https://ifconfig.me || echo FAILED)"
echo "VPN gateway: $(awk -F= '/^VPNGATEWAY=/ {print $2}' /var/run/labvpn/connect-env.txt) (should be IPv4)"
echo "IPv6 reject routes: $(netstat -rn -f inet6 | grep -cE '^(::/1|8000::/1)[[:space:]]') of 2"
# A literal address, because curl -6 with a hostname can fall back to a mapped IPv4 address.
ipv6="$(curl -g -6 -s -m 8 -o /dev/null -w '%{remote_ip}' 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null)"
echo "Direct IPv6: ${ipv6:+LEAKING to $ipv6}${ipv6:-blocked}"
echo "Default IPv4 route: $(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')"
for host in www.sciencedirect.com onlinelibrary.wiley.com; do
  address="$(dig +time=2 +tries=1 +short "$host" A | grep -E '^[0-9.]+$' | tail -1)"
  echo "$host -> $address via $(route -n get "$address" 2>/dev/null | awk '/interface:/ {print $2}')"
done
echo "Primary DNS: $(scutil --dns | awk '/nameserver\[0\]/ {print $3; exit}')"
echo "--- Pushed by the gateway"
grep -E '^(CISCO_SPLIT|CISCO_IPV6_SPLIT|CISCO_DEF_DOMAIN|INTERNAL_IP4_(ADDRESS|DNS|MTU)|INTERNAL_IP6|VPNGATEWAY)' /var/run/labvpn/connect-env.txt 2>/dev/null \
  || echo "No record at /var/run/labvpn/connect-env.txt"
