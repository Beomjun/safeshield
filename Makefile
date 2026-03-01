# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3
# of the License, or (at your option) any later version.

include $(TOPDIR)/rules.mk

PKG_NAME:=safeshield
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Beomjun Kang <kals323@gmail.com>
PKGARCH:=all

PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)

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

define Package/safeshield/conffiles
/etc/config/safeshield
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(CP) ./files $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/safeshield/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/etc/init.d/safeshield $(1)/etc/init.d/safeshield

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/files/etc/config/safeshield $(1)/etc/config/safeshield

	$(INSTALL_DIR) $(1)/usr/lib/safeshield
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/safeshield.log.sh    $(1)/usr/lib/safeshield/log.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/safeshield.status.sh $(1)/usr/lib/safeshield/status.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/safeshield.utils.sh  $(1)/usr/lib/safeshield/utils.sh
endef

$(eval $(call BuildPackage,safeshield))

