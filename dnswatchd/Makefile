#
# dnswatchd - DNS upstream watchdog for OpenWrt
#
# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

PKG_NAME:=dnswatchd
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=AIerlIz

# 所有内容都在 ./files/ 下，不需要 PKG_SOURCE_*（不要写 git 拉取，
# 否则首次编译会去 clone 本仓库自己，既慢又容易因网络失败）

include $(INCLUDE_DIR)/package.mk

define Package/dnswatchd
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=DNS
  TITLE:=DNS upstream watchdog with response validation
  URL:=https://github.com/AIerlIz/dnswatchd
  DEPENDS:=+dnsmasq
  PKGARCH:=all
endef

define Package/dnswatchd/description
 dnswatchd continuously probes dnsmasq's upstream DNS servers and validates
 that the answers land in the expected address range (f.ex. a clash fake-ip
 range for proxy upstreams, or outside it for direct upstreams). When the
 preferred upstream stops answering correctly it switches dnsmasq's
 upstream via --servers-file, and switches back once the upstream recovers.

 Only ONE server line is ever written to the servers-file: dnsmasq queries
 multiple upstreams concurrently, which would mix fake-ip and real IPs and
 break transparent proxying.
endef

define Package/dnswatchd/conffiles
/etc/config/dnswatchd
endef

define Build/Compile
endef

define Package/dnswatchd/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/dnswatchd $(1)/usr/sbin/dnswatchd

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/dnswatchd.init $(1)/etc/init.d/dnswatchd

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/dnswatchd.config $(1)/etc/config/dnswatchd

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/dnswatchd.uci-defaults $(1)/etc/uci-defaults/90-dnswatchd
endef

define Package/dnswatchd/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/dnswatchd enable
	/etc/init.d/dnswatchd start
}
exit 0
endef

define Package/dnswatchd/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/dnswatchd stop
exit 0
endef

$(eval $(call BuildPackage,dnswatchd))
