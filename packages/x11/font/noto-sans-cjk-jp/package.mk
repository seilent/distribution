# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-present Team ROCKNIX

PKG_NAME="noto-sans-cjk-jp"
PKG_VERSION="2.004"
PKG_SHA256="2bbdd2c20f30670b39ca735c96d75f1fdabdb348103e43b820cf17701fd22b18"
PKG_LICENSE="OFL-1.1"
PKG_SITE="https://github.com/notofonts/noto-cjk"
PKG_URL="https://github.com/notofonts/noto-cjk/releases/download/Sans${PKG_VERSION}/16_NotoSansJP.zip"
PKG_DEPENDS_TARGET="toolchain util-macros"
PKG_LONGDESC="Noto Sans CJK JP - Japanese subset of Google's Noto Sans CJK fonts."
PKG_TOOLCHAIN="manual"

unpack() {
  mkdir -p ${PKG_BUILD}
  unzip -o ${SOURCES}/${PKG_NAME}/${PKG_NAME}-${PKG_VERSION}.zip -d ${PKG_BUILD}
}

makeinstall_target() {
  mkdir -p ${INSTALL}/usr/share/fonts/noto-cjk-jp
  cp ${PKG_BUILD}/*.otf ${INSTALL}/usr/share/fonts/noto-cjk-jp
}

post_install() {
  mkfontdir ${INSTALL}/usr/share/fonts/noto-cjk-jp
  mkfontscale ${INSTALL}/usr/share/fonts/noto-cjk-jp
}
