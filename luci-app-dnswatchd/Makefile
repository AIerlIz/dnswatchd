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
PKG_VERSION:=0.2.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=AIerlIz

# Translations live in ./po/<lang>/dnswatchd.po and are picked up by luci.mk.
include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,$(PKG_NAME)))
