#
# dnswatchd - DNS upstream watchdog for OpenWrt
#
# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

PKG_NAME:=dnswatchd
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=AIerlIz

# Everything lives in ./files; there is no PKG_SOURCE on purpose. Pointing this
# at the repository itself would make the first build clone the package it is
# building.
#
# Note the missing PKGARCH:=all: the package now ships a compiled probe, so it
# is architecture specific. The probe is linked statically so one binary per
# architecture serves every supported OpenWrt release.

include $(INCLUDE_DIR)/package.mk

define Package/dnswatchd
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=DNS
  TITLE:=DNS upstream watchdog with response validation
  URL:=https://github.com/AIerlIz/dnswatchd
  DEPENDS:=+dnsmasq
endef

define Package/dnswatchd/description
 dnswatchd probes the upstream resolvers dnsmasq uses and validates that the
 answers land in the expected address range (a Clash fake-ip pool for a proxy
 upstream, outside it for a direct one). When the preferred upstream stops
 answering correctly it rewrites dnsmasq's --servers-file to the next candidate
 and reloads it.

 Exactly ONE server line is ever written. dnsmasq chooses between its configured
 upstreams by itself, so a second one — from `list server`, or from
 resolv.conf.auto while noresolv=0 — means losing control of which resolver
 answers, which is how real addresses leak into a fake-ip setup.

 Installing this package changes nothing about your DNS. `dnswatchd takeover`
 (or the LuCI wizard) performs the migration, after taking a backup, and
 `dnswatchd rollback` undoes it.
endef

define Package/dnswatchd/conffiles
/etc/config/dnswatchd
endef

define Build/Compile
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) \
		-static -no-pie -o $(PKG_BUILD_DIR)/dnswatch-probe \
		./files/dnswatch-probe.c
	$(STRIP) $(PKG_BUILD_DIR)/dnswatch-probe
endef

define Package/dnswatchd/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/dnswatchd $(1)/usr/sbin/dnswatchd

	$(INSTALL_DIR) $(1)/usr/lib/dnswatchd
	$(INSTALL_DATA) ./files/lib/common.sh  $(1)/usr/lib/dnswatchd/common.sh
	$(INSTALL_DATA) ./files/lib/config.sh  $(1)/usr/lib/dnswatchd/config.sh
	$(INSTALL_DATA) ./files/lib/state.sh   $(1)/usr/lib/dnswatchd/state.sh
	$(INSTALL_DATA) ./files/lib/probe.sh   $(1)/usr/lib/dnswatchd/probe.sh
	$(INSTALL_DATA) ./files/lib/apply.sh   $(1)/usr/lib/dnswatchd/apply.sh
	$(INSTALL_DATA) ./files/lib/select.sh  $(1)/usr/lib/dnswatchd/select.sh
	$(INSTALL_DATA) ./files/lib/takeover.sh $(1)/usr/lib/dnswatchd/takeover.sh

	$(INSTALL_DIR) $(1)/usr/libexec/dnswatchd
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/dnswatch-probe $(1)/usr/libexec/dnswatchd/probe

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/rpcd/dnswatchd $(1)/usr/libexec/rpcd/dnswatchd

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
	# A new rpcd plugin only shows up after rpcd rescans /usr/libexec/rpcd.
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1
	/etc/init.d/dnswatchd enable
	# start is harmless before takeover: the init script warns and the daemon
	# only writes a file nobody reads yet.
	/etc/init.d/dnswatchd start
}
exit 0
endef

define Package/dnswatchd/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/dnswatchd stop
	if [ -f /etc/dnswatchd/takenover ]; then
		logger -t dnswatchd "removing dnswatchd while it still manages dnsmasq; dnsmasq keeps using /etc/dnswatchd/servers. Run 'dnswatchd rollback' first if you want the original setup back." 2>/dev/null
	fi
}
exit 0
endef

$(eval $(call BuildPackage,dnswatchd))
