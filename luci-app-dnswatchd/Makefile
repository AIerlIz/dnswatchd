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

# Translations live in ./po/<lang>/dnswatchd.po; luci.mk compiles them with
# po2lmo into a generated luci-i18n-dnswatchd-zh-cn package.
include $(TOPDIR)/feeds/luci/luci.mk

# luci.mk defines the packages but does not give the generated translation
# package a `package/<name>/compile` target, so asking make for it fails with
# "No rule to make target" and its .ipk is never produced. Naming both packages
# here is what registers those targets; the definitions themselves still come
# from luci.mk, so this only re-registers the same recipes.
$(eval $(call BuildPackage,$(PKG_NAME)))
$(eval $(call BuildPackage,luci-i18n-$(PKG_NAME:luci-app-%=%)-zh-cn))
