#!/bin/sh
# Downloads 3x-ui (or compatible) subscriptions.
#   sub.sh           update the subscriptions whose interval has passed (run hourly from cron)
#   sub.sh --force   update all enabled subscriptions now
#   sub.sh --boot    at start: update when due, retrying for ~10 minutes while the network comes up
# Links are kept in /etc/xroute/subs/<section>.links and rewritten only when they change, so the
# router has working servers right after a reboot. Traffic/expiry info lives in RAM (/tmp/xroute/subs).
# If any subscription changed and xroute is enabled, the service is restarted.

. /lib/functions.sh

STORE=/etc/xroute/subs
RUN=/tmp/xroute/subs
mkdir -p "$STORE" "$RUN"

hwid() {
	local mac
	mac=$(cat /sys/class/net/eth0/address /sys/class/net/eth1/address 2>/dev/null | head -n 1)
	echo "openwrt-$(echo "$mac$(cat /proc/sys/kernel/hostname)" | md5sum | cut -c1-16)"
}

json_str() { # escape for a JSON string; control characters are not allowed there at all
	printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

header() { # <file> <name>  (case-insensitive)
	grep -i "^$2:" "$1" 2>/dev/null | tail -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
}

userinfo_val() { # <userinfo> <key>
	echo "$1" | tr ';' '\n' | sed 's/[[:space:]]//g' | sed -n "s/^$2=//p" | head -n 1
}

decode_body() { # <in> <out>: plain list or base64 (standard or URL-safe, any padding)
	ucode /usr/share/xroute/b64.uc "$1" | tr -d '\r' | grep -E '^(vless|hy2|hysteria2)://' > "$2"
}

significant() { # <links file> <ignored params, e.g. sid|spx>: what matters for the connection (no name), sorted
	sed -E "s/#.*//; s/([?&])($2)=[^&]*/\\1/g; s/[?&]+\$//" "$1" 2>/dev/null | sort
}

decode_title() { # 3x-ui sends "base64:<...>" for non-ASCII titles
	case "$1" in
		base64:*)
			printf '%s' "${1#base64:}" > "$RUN/title.b64"
			ucode /usr/share/xroute/b64.uc "$RUN/title.b64"
			rm -f "$RUN/title.b64"
			;;
		*) printf '%s' "$1" ;;
	esac
}

download() { # <section> <url> [extra curl options]: body and headers into $RUN, the error into $RUN/<section>.err
	local sec="$1" url="$2"
	shift 2
	curl -fsS --connect-timeout 8 --max-time 40 "$@" -D "$RUN/$sec.hdr" -o "$RUN/$sec.body" \
		-A "luci-app-xroute (OpenWrt)" -H "X-HWID: $(hwid)" -H "X-Device-OS: OpenWrt" \
		-H "X-Device-Model: $(cat /tmp/sysinfo/model 2>/dev/null || echo router)" "$url" 2>"$RUN/$sec.err"
}

update_one() { # <section>
	local sec="$1" enabled url interval now last due body hdr links title ui ivl ign port err="" changed=0

	config_get_bool enabled "$sec" enabled 1
	[ "$enabled" = 1 ] || return 0
	config_get url "$sec" url
	[ -n "$url" ] || return 0
	config_get interval "$sec" interval 0

	now=$(date +%s)
	last=$(cat "$RUN/$sec.last" 2>/dev/null || echo 0)
	ivl=$(cat "$RUN/$sec.ivl" 2>/dev/null)
	[ "$interval" -gt 0 ] 2>/dev/null && ivl=$interval
	[ -n "$ivl" ] || ivl=12
	due=$(( last + ivl * 3600 ))
	[ "$force" = 1 ] || [ "$now" -ge "$due" ] || return 0

	body="$RUN/$sec.body"; hdr="$RUN/$sec.hdr"; links="$RUN/$sec.links"
	# the ISP may drop TLS to the panel's foreign server while Xray (with a cut ClientHello) gets through:
	# one quick direct try, then through Xray's local SOCKS port, then direct with retries
	port=$(jsonfilter -i /var/etc/xroute/tests.json -e '@.auto_port' 2>/dev/null)
	if ! download "$sec" "$url" --max-time 20 &&
	   ! { [ -n "$port" ] && pidof xray >/dev/null && download "$sec" "$url" --retry 2 --retry-delay 5 --socks5-hostname "127.0.0.1:$port"; } &&
	   ! download "$sec" "$url" --retry 2 --retry-delay 5; then
		err=$(tail -n 1 "$RUN/$sec.err")
	else
		decode_body "$body" "$links"
		if [ ! -s "$links" ]; then
			err="в ответе нет ссылок vless:// или hy2://"
		else
			echo "$now" > "$RUN/$sec.last"
			# 3x-ui picks a random Reality shortId (and spiderX) per request and may put traffic into
			# the server name: those differences alone must not rewrite flash or restart Xray. The LuCI
			# button (--force) does take the new shortId, in case the shortIds were changed in the panel.
			ign="sid|spx"
			[ "$force" = 1 ] && ign="spx"
			if [ "$(significant "$links" "$ign")" != "$(significant "$STORE/$sec.links" "$ign")" ]; then
				cp -f "$links" "$STORE/$sec.links"
				changed=1
			fi
			ivl=$(header "$hdr" profile-update-interval | tr -cd '0-9')
			[ -n "$ivl" ] && [ "$ivl" -gt 0 ] && echo "$ivl" > "$RUN/$sec.ivl"
			decode_title "$(header "$hdr" profile-title)" > "$RUN/$sec.title"
			header "$hdr" subscription-userinfo > "$RUN/$sec.ui"
		fi
	fi

	# title and traffic come from the last successful download
	title=$(cat "$RUN/$sec.title" 2>/dev/null)
	ui=$(cat "$RUN/$sec.ui" 2>/dev/null)
	{
		printf '{ "attempt": %s, "fetched": %s, "servers": %s, "title": "%s", "error": "%s"' "$now" \
			"$(cat "$RUN/$sec.last" 2>/dev/null || echo 0)" "$(grep -c . "$STORE/$sec.links" 2>/dev/null || echo 0)" \
			"$(json_str "$title")" "$(json_str "$err")"
		for k in upload download total expire; do
			v=$(userinfo_val "$ui" "$k" | tr -cd '0-9')
			printf ', "%s": %s' "$k" "${v:-0}"
		done
		echo ' }'
	} > "$RUN/$sec.json"
	rm -f "$body" "$hdr" "$links" "$RUN/$sec.err"

	[ -z "$err" ] || { logger -t xroute "subscription $sec: $err"; failed=1; }
	[ "$changed" = 1 ] && any_changed=1
	return 0
}

# cron, the LuCI button and service starts may overlap; runs are serialised (not the retry pauses)
run_all() {
	lock /var/lock/xroute-sub.lock
	failed=0
	config_load xroute
	config_foreach update_one subscription
	lock -u /var/lock/xroute-sub.lock
}

force=0
any_changed=0
case "$1" in
	--force) force=1; run_all ;;
	--boot)
		run_all
		n=0
		while [ "$failed" = 1 ] && [ $n -lt 20 ]; do
			sleep 30
			n=$((n + 1))
			run_all
		done
		;;
	*) run_all ;;
esac

# drop stored links of subscriptions that no longer exist
for f in "$STORE"/*.links; do
	[ -f "$f" ] || continue
	s=$(basename "$f" .links)
	[ "$(uci -q get xroute."$s")" = subscription ] || { rm -f "$f" "$RUN/$s".*; any_changed=1; }
done

if [ "$any_changed" = 1 ] && [ "$(uci -q get xroute.main.enabled)" = 1 ]; then
	logger -t xroute "subscription changed, restarting"
	/etc/init.d/xroute restart
fi
