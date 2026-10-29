# Ready-made lists: itdoginfo/allow-domains and the lists kept in this package's own repository.
# Sourced by lists.sh. catalog_urls <id> prints "dom <url>" and/or "net <url>" lines.

XROUTE_LISTS_BASE=https://raw.githubusercontent.com/itdoginfo/allow-domains/main
XROUTE_OWN_BASE=https://raw.githubusercontent.com/Rozsario/luci-app-xroute/main/lists

catalog_urls() {
	local b=$XROUTE_LISTS_BASE o=$XROUTE_OWN_BASE
	case "$1" in
		telegram)      echo "dom $b/Services/telegram.lst"; echo "net $b/Subnets/IPv4/telegram.lst" ;;
		meta)          echo "dom $b/Services/meta.lst"; echo "net $b/Subnets/IPv4/meta.lst" ;;
		twitter)       echo "dom $b/Services/twitter.lst"; echo "net $b/Subnets/IPv4/twitter.lst" ;;
		discord)       echo "dom $b/Services/discord.lst"; echo "net $b/Subnets/IPv4/discord.lst" ;;
		roblox)        echo "dom $b/Services/roblox.lst"; echo "net $b/Subnets/IPv4/roblox.lst" ;;
		geoblock)      echo "dom $b/Categories/geoblock.lst" ;;
		google_ai)     echo "dom $b/Services/google_ai.lst" ;;
		google_play)   echo "dom $b/Services/google_play.lst" ;;
		youtube)       echo "dom $b/Services/youtube.lst" ;;
		tiktok)        echo "dom $b/Services/tiktok.lst" ;;
		hdrezka)       echo "dom $b/Services/hdrezka.lst" ;;
		news)          echo "dom $b/Categories/news.lst" ;;
		block)         echo "dom $b/Categories/block.lst" ;;
		russia_inside) echo "dom $b/Russia/inside-raw.lst" ;;
		ukraine)       echo "dom $o/domains/ukraine.lst" ;;
		viber)         echo "dom $o/domains/viber.lst"; echo "net $o/subnets/viber.lst" ;;
	esac
}
