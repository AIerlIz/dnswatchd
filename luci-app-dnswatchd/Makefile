#
# luci-app-dnswatchd - LuCI interface for dnswatchd
#
# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI interface for dnswatchd
LUCI_DESCRIPTION:=Web UI for the dnswatchd DNS upstream watchdog
LUCI_DEPENDS:=+dnswatchd +luci-base
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-dnswatchd
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=dnswatchd contributors

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
