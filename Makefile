# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3
# of the License, or (at your option) any later version.

include $(TOPDIR)/rules.mk

PKG_NAME:=safeshield
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Beomjun Kang <kals323@gmail.com>
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/safeshield
  SECTION:=net
  CATEGORY:=Network
  TITLE:=SafeShield Service
  URL:=https://github.com/Beomjun/safeshield
  DEPENDS:=+curl +jshn
endef

define Package/safeshield/description
SafeShield is a Lightweight, DNS-based protection for OpenWrt — block ads and phishing sites.
endef

$(eval $(call BuildPackage,safeshield))