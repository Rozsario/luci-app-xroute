#!/bin/sh
# Builds the xroute routing lists: a dnsmasq nftset config for domains and the nft set of subnets.
# Everything lives in RAM (/tmp/xroute); copies shipped in the package are used until a download succeeds.
#   lists.sh           build from what is already downloaded
#   lists.sh --update  re-download every selected list, then build
#   lists.sh --boot    build now, then keep retrying downloads for ~10 minutes (network may still be down)
#   lists.sh --remove  drop the dnsmasq config (service stop)

. /lib/functions.sh
. /usr/share/xroute/catalog.sh

TMP=/tmp/xroute
DIR=$TMP/lists
BUILTIN=/usr/share/xroute/builtin
NFT_SETS="4#inet#xroute#dst_dns"
LOCK=/var/lock/xroute-lists.lock

dnsmasq_confdir() {
	local d
	d=$(uci -q get dhcp.@dnsmasq[0].confdir)
	[ -n "$d" ] || d=$(sed -n 's/^conf-dir=//p' /var/etc/dnsmasq.conf.* 2>/dev/null | head -n 1 | cut -d, -f1)
	echo "${d:-/tmp/dnsmasq.d}"
}

install_dnsmasq_conf() { # <file or empty to remove>
	local dst="$(dnsmasq_confdir)/xroute.conf"
	if [ -z "$1" ]; then
		[ -f "$dst" ] || return 0
		rm -f "$dst"
	else
		cmp -s "$1" "$dst" && return 0
		mkdir -p "${dst%/*}"
		cp -f "$1" "$dst"
	fi
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
}

add_id() { ids="$ids $1"; }
add_line() { echo "$1" >> "$2"; }

# YouTube's own exclusions (by default YouTube is left to zapret) do not apply while it goes through the VPN
GOOGLE_EXCLUDES=" youtube.com youtu.be googlevideo.com ytimg.com ggpht.com youtubei.googleapis.com gvt1.com "
add_exclude() {
	[ "$google_vpn" = 1 ] && case "$GOOGLE_EXCLUDES" in *" $1 "*) return ;; esac
	echo "$1" >> "$TMP/exclude"
}

fetch() { # <id> <kind> <url>; returns 1 while the list is missing or still the built-in copy
	local f="$DIR/$1.$2"
	if [ "$update" = 1 ] || [ ! -s "$f" ] || [ -f "$f.builtin" ]; then
		if curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 -o "$f.new" "$3" 2>/dev/null && [ -s "$f.new" ]; then
			mv -f "$f.new" "$f"
			rm -f "$f.builtin"
		else
			rm -f "$f.new"
		fi
	fi
	if [ ! -s "$f" ] && [ -s "$BUILTIN/$1.$2" ]; then
		cp -f "$BUILTIN/$1.$2" "$f"
		touch "$f.builtin"
	fi
	[ -s "$f" ] && [ ! -f "$f.builtin" ]
}

# cron, the LuCI button and service starts may overlap; builds are serialised
build() {
	lock "$LOCK"
	do_build
	lock -u "$LOCK"
}

do_build() {
	local id kind url google_vpn
	mkdir -p "$DIR"
	ids=""
	config_load xroute
	config_list_foreach lists community add_id
	# YouTube and Google Play switch together: Google serves Play downloads and YouTube video
	# from the same servers, so one of them alone through the VPN would drag the other along anyway
	config_get_bool google_vpn lists google_vpn 0
	[ "$google_vpn" = 1 ] && ids="$ids youtube google_play"

	: > "$TMP/domains.src"; : > "$TMP/subnets.src"
	# sentinel line: awk's NR == FNR trick breaks when the first file is empty
	echo "-" > "$TMP/exclude"
	config_list_foreach lists domain add_line "$TMP/domains.src"
	config_list_foreach lists subnet add_line "$TMP/subnets.src"
	config_list_foreach lists exclude add_exclude
	rm -f "$TMP/.missing.tmp"

	for id in $ids; do
		catalog_urls "$id" | while read kind url; do
			fetch "$id" "$kind" "$url" || touch "$TMP/.missing.tmp"
			[ -s "$DIR/$id.$kind" ] || continue
			# echo: some lists have no trailing newline, the last entry would glue to the next file
			[ "$kind" = dom ] && { cat "$DIR/$id.$kind"; echo; } >> "$TMP/domains.src"
			[ "$kind" = net ] && { cat "$DIR/$id.$kind"; echo; } >> "$TMP/subnets.src"
		done
	done

	# domains: normalise, drop exclusions (exact or parent domain), one nftset line per domain;
	# a bare top-level domain (ua, xn--j1amh) covers the whole zone
	sed 's/#.*//; s/[[:space:]]//g; s/^\*\.//; s/^\.//; s/\.$//' "$TMP/domains.src" | tr 'A-Z' 'a-z' \
		| grep -E '^([a-z0-9_-]+(\.[a-z0-9_-]+)+|[a-z]{2,}|xn--[a-z0-9-]+)$' | sort -u \
		| awk 'NR == FNR { if ($1 != "") ex[tolower($1)] = 1; next }
			{ d = $0; while (d != "") { if (d in ex) next; i = index(d, "."); if (!i) break; d = substr(d, i + 1) } print }' \
			"$TMP/exclude" - > "$TMP/domains"
	awk -v s="$NFT_SETS" '{ print "nftset=/" $0 "/" s }' "$TMP/domains" > "$TMP/xroute.conf"
	# VPN servers given by name: every address dnsmasq resolves for them joins the servers set (fw.sh),
	# so a VPN client on a PC in the LAN reaches the same server past the redirect and past zapret
	grep -E '^[a-z0-9-]+(\.[a-z0-9-]+)+$' /var/etc/xroute/servers 2>/dev/null | grep -vE '^[0-9.]+$' | sort -u \
		| awk '{ print "nftset=/" $0 "/4#inet#xroute#servers" }' >> "$TMP/xroute.conf"

	# subnets: plain IPv4 addresses or CIDRs
	sed 's/#.*//; s/[[:space:]]//g' "$TMP/subnets.src" \
		| grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$' | sort -u > "$TMP/subnets"
	{
		echo "flush set inet xroute dst_net"
		[ -s "$TMP/subnets" ] && awk 'BEGIN { ORS = "" } { if (NR % 500 == 1) { if (NR > 1) print " }\n"; print "add element inet xroute dst_net { " $0 } else print ", " $0 }
			END { if (NR) print " }\n" }' "$TMP/subnets"
	} > "$TMP/subnets.nft"

	if nft list table inet xroute >/dev/null 2>&1; then
		nft -f "$TMP/subnets.nft" || logger -t xroute "failed to load subnets"
		# domains dropped from the lists (e.g. YouTube switched back to zapret) must not keep going through
		# the VPN for a day; their addresses cannot be told from the others, so the set starts afresh
		# (dnsmasq restarts with the new config below and refills it from new answers)
		if [ -s "$TMP/domains.prev" ] && awk 'NR == FNR { now[$0] = 1; next } !($0 in now) { gone = 1; exit } END { exit !gone }' \
			"$TMP/domains" "$TMP/domains.prev"; then
			nft flush set inet xroute dst_dns
		fi
		cp -f "$TMP/domains" "$TMP/domains.prev"
		install_dnsmasq_conf "$TMP/xroute.conf"
	fi

	{
		echo "updated=$(date +%s)"
		echo "domains=$(wc -l < "$TMP/domains")"
		echo "subnets=$(wc -l < "$TMP/subnets")"
		echo "builtin=$(ls "$DIR"/*.builtin 2>/dev/null | wc -l)"
		echo "missing=$([ -f "$TMP/.missing.tmp" ] && echo 1 || echo 0)"
	} > "$TMP/lists.info"
	rm -f "$TMP/domains.src" "$TMP/subnets.src" "$TMP/subnets.nft"
	# .missing tells --boot to retry; written only here so the retry loop sees a finished build
	if [ -f "$TMP/.missing.tmp" ]; then mv -f "$TMP/.missing.tmp" "$TMP/.missing"; else rm -f "$TMP/.missing"; fi
}

update=0
case "$1" in
	--remove)
		install_dnsmasq_conf ""
		exit 0
		;;
	--update)
		update=1
		build
		;;
	--boot)
		build
		n=0
		# retries download only what is still missing or built-in
		while [ -f "$TMP/.missing" ] && [ $n -lt 20 ]; do
			sleep 30
			n=$((n + 1))
			build
		done
		;;
	*)
		build
		;;
esac
