#!/bin/sh
# Fail-open guard, run from cron every minute while xroute is enabled.
# If Xray is not running, the TPROXY redirect is removed so listed sites go direct (and through zapret);
# once Xray is back, the redirect is restored.

[ "$(uci -q get xroute.main.enabled)" = 1 ] || exit 0
nft list table inet xroute >/dev/null 2>&1 || exit 0

running=$(ubus call service list '{"name":"xroute"}' 2>/dev/null | jsonfilter -e '@.xroute.instances.xray.running')
active=$(nft list chain inet xroute divert 2>/dev/null | grep -c tproxy)

if [ "$running" = true ]; then
	[ "$active" -gt 0 ] && exit 0
	/usr/share/xroute/fw.sh redirect on && logger -t xroute "xray is running again, redirect restored"
else
	[ "$active" -eq 0 ] && exit 0
	/usr/share/xroute/fw.sh redirect off && logger -t xroute "xray is not running, redirect disabled (fail-open)"
fi
