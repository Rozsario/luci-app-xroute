#!/bin/sh
# nftables table and policy routing for xroute.
#   fw.sh up        create (or update) the table, sets, policy routing and enable the redirect
#   fw.sh down      remove everything
#   fw.sh redirect on|off   only toggle the TPROXY rules (sets keep their contents)
# Only traffic that enters from the LAN and goes to an address in dst_dns/dst_net is sent to Xray.
# Traffic to the VPN servers themselves is never redirected and is kept away from zapret.

. /lib/functions.sh

config_load xroute
config_get port main tproxy_port 12701
config_get mark main fwmark 0x2000
config_get table main route_table 127

PRIVATE="0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4"

lan_devices() {
	local d
	d=$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@.l3_device')
	echo "${d:-br-lan}"
}

# "ip, ip" of the VPN servers: unique, IPv4 only, without private addresses
server_ips() {
	local h
	[ -s /var/etc/xroute/servers ] || return 0
	while read h; do
		[ -n "$h" ] || continue
		case "$h" in
			*[!0-9.]*) nslookup "$h" 127.0.0.1 2>/dev/null | awk '/^Address/ && $2 !~ /:53$/ && $2 ~ /^[0-9.]+$/ { print $2 }' ;;
			*) echo "$h" ;;
		esac
	done < /var/etc/xroute/servers | sort -u \
		| grep -vE '^(0|10|127)\.|^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|^169\.254\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^192\.168\.|^(22[4-9]|2[3-5][0-9])\.' \
		| awk '{ printf "%s%s", (n++ ? ", " : ""), $1 }'
}

# zapret (bol-van/zapret and zapret2) leaves alone packets that carry its DESYNC_MARK. Putting it on all
# traffic to and from the VPN servers keeps zapret off the tunnel, whether the router's Xray or a VPN
# client on a PC in the LAN connects to them. Empty when zapret is not installed.
zapret_mark() {
	uci -q get zapret2.config.DESYNC_MARK || uci -q get zapret.config.DESYNC_MARK
}

redirect_on() {
	nft -f - <<-EOF
		flush chain inet xroute divert
		add rule inet xroute divert meta l4proto { tcp, udp } ip daddr @dst_dns counter meta mark set $mark tproxy ip to 127.0.0.1:$port accept
		add rule inet xroute divert meta l4proto { tcp, udp } ip daddr @dst_net counter meta mark set $mark tproxy ip to 127.0.0.1:$port accept
	EOF
}

redirect_off() {
	nft flush chain inet xroute divert 2>/dev/null
}

# Creates the table or brings an existing one up to date. The sets are kept: dst_dns holds the addresses
# dnsmasq resolved before a restart, and clients will not ask for them again until their DNS cache expires.
# The servers set holds the VPN servers' addresses: resolved here and added by dnsmasq whenever anyone
# resolves a server name (lists.sh). Traffic to them is never redirected to Xray and never touched by zapret.
table_nft() { # <lan devices> <server addresses> <zapret mark>
	cat <<-EOF
		add table inet xroute
		add set inet xroute dst_dns { type ipv4_addr; flags timeout; timeout 1d; size 65536; }
		add set inet xroute dst_net { type ipv4_addr; flags interval; auto-merge; size 65536; }
		add set inet xroute bypass { type ipv4_addr; flags interval; auto-merge; }
		flush set inet xroute bypass
		add element inet xroute bypass { $PRIVATE }
		add set inet xroute servers { type ipv4_addr; }
		flush set inet xroute servers
		add chain inet xroute divert
		add chain inet xroute prerouting { type filter hook prerouting priority mangle; policy accept; }
		flush chain inet xroute prerouting
		add chain inet xroute output { type filter hook output priority mangle; policy accept; }
		flush chain inet xroute output
	EOF
	[ -n "$2" ] && echo "add element inet xroute servers { $2 }"
	if [ -n "$3" ]; then
		echo "add rule inet xroute prerouting ip daddr @servers meta mark set meta mark | $3"
		echo "add rule inet xroute prerouting ip saddr @servers meta mark set meta mark | $3"
		echo "add rule inet xroute output ip daddr @servers meta mark set meta mark | $3"
	fi
	cat <<-EOF
		add rule inet xroute prerouting iifname != { $1 } return
		add rule inet xroute prerouting ip daddr @bypass return
		add rule inet xroute prerouting ip daddr @servers return
		add rule inet xroute prerouting jump divert
	EOF
}

up() {
	local devs servers zmark
	devs=$(lan_devices | awk '{ for (i = 1; i <= NF; i++) printf "%s\"%s\"", (n++ ? ", " : ""), $i }')
	servers=$(server_ips)
	zmark=$(zapret_mark)
	# a table left by an older version with other set flags cannot be updated in place: recreate it
	if ! table_nft "$devs" "$servers" "$zmark" | nft -f - 2>/dev/null; then
		nft delete table inet xroute 2>/dev/null
		table_nft "$devs" "$servers" "$zmark" | nft -f -
	fi
	redirect_on

	ip rule del fwmark "$mark" lookup "$table" 2>/dev/null
	ip rule add fwmark "$mark" lookup "$table" priority 1270
	ip route replace local 0.0.0.0/0 dev lo table "$table"
}

down() {
	nft delete table inet xroute 2>/dev/null
	ip rule del fwmark "$mark" lookup "$table" 2>/dev/null
	ip route flush table "$table" 2>/dev/null
}

case "$1" in
	up) up ;;
	down) down ;;
	redirect)
		case "$2" in
			on) redirect_on ;;
			off) redirect_off ;;
		esac
		;;
	*) echo "usage: $0 up|down|redirect on|off" >&2; exit 1 ;;
esac
