include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mihomo-mini
PKG_VERSION:=0.1.2
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

LUCI_NAME:=luci-app-mihomo-mini
LUCI_TITLE:=Mihomo Mini service manager
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-digest +curl +ca-bundle
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# Intended for the existing mihomo-safe-run / mihomo_tproxy_safe installation.
# It does not install or replace a network service or a Mihomo core.
