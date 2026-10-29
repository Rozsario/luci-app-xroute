include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xroute
PKG_VERSION:=0.1.1
PKG_RELEASE:=1
PKG_LICENSE:=LicenseRef-xroute-noncommercial

LUCI_TITLE:=Route blocked domains and subnets through Xray (VLESS/Hysteria2), the rest direct
LUCI_DEPENDS:=+luci-base
# runtime-only dependencies: recorded in the package metadata, not built by the SDK
# (they come as ready packages from the official OpenWrt repository)
LUCI_EXTRA_DEPENDS:=xray-core (>=26.3.27), kmod-nft-tproxy (>=6.12), dnsmasq-full (>=2.90), curl (>=8.0), \
	ucode (>=2025.01.01), ucode-mod-uci (>=2025.01.01), ucode-mod-fs (>=2025.01.01)
LUCI_PKGARCH:=all
LUCI_URL:=https://github.com/Rozsario/luci-app-xroute
LUCI_MAINTAINER:=Rozsario <https://github.com/Rozsario>

define Package/luci-app-xroute/conffiles
/etc/config/xroute
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
