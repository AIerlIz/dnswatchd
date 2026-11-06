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
#
# luci.mk already calls BuildPackage for PKG_NAME and for every generated
# luci-i18n-* package (luci.mk:353-355); calling it here as well re-registers
# the app package ("ignoring old recipe for target ...luci-app-dnswatchd...ipk")
# and the translation package never gets packaged.
include $(TOPDIR)/feeds/luci/luci.mk
