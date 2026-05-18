# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2024-present ROCKNIX (https://github.com/ROCKNIX)

PKG_NAME="lsfg-vk"
PKG_VERSION="1.0.0"
PKG_LICENSE="proprietary"
PKG_SITE="https://github.com/PancakeTAS/lsfg-vk"
PKG_URL="https://github.com/PancakeTAS/lsfg-vk/releases/download/v${PKG_VERSION}/lsfg-vk-${PKG_VERSION}-x86_64.zip"
PKG_DEPENDS_TARGET="vulkan-loader"
PKG_LONGDESC="Lossless Scaling Frame Generation Vulkan layer for Steam/Proton games"
PKG_TOOLCHAIN="manual"

makeinstall_target() {
  # Source files (read-only rootfs, used by lsfg-vk-setup at runtime)
  mkdir -p ${INSTALL}/usr/share/lsfg-vk
  cp ${PKG_BUILD}/lib/liblsfg-vk.so ${INSTALL}/usr/share/lsfg-vk/
  cp ${PKG_DIR}/files/VkLayer_LS_frame_generation.json ${INSTALL}/usr/share/lsfg-vk/
  cp ${PKG_DIR}/files/user_settings.py ${INSTALL}/usr/share/lsfg-vk/

  # Setup helper (copies into FEX RootFS + Proton dirs on /storage/)
  mkdir -p ${INSTALL}/usr/bin
  cp ${PKG_DIR}/sources/lsfg-vk-setup ${INSTALL}/usr/bin/lsfg-vk-setup
  chmod +x ${INSTALL}/usr/bin/lsfg-vk-setup

  # User-facing launch wrapper
  cp ${PKG_DIR}/sources/lsfg ${INSTALL}/usr/bin/lsfg
  chmod +x ${INSTALL}/usr/bin/lsfg
}

post_install() {
  enable_service lsfg-vk-setup.service
}
