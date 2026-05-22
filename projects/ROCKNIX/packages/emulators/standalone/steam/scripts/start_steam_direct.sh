#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Direct-boot-to-Steam session for AYANEO Pocket ACE (SM8550)
# Launched as UI_SERVICE by autostart when Steam is set as boot game.
# On exit, starts essway for ES access.

source /etc/profile

export STEAM_FLAVOR=arm64
set_kill set "gamescope steam FEX"

# Load helper functions from main steam script
. /usr/bin/start_steam.sh

# Prepare environment (FEX, storage, thunks, CPU affinity, binfmt)
steam_ensure_fex_config_template
steam_prepare_storage_and_vdf
steam_load_es_thunk_settings
steam_write_fex_config_json
steam_set_cpu_affinity
steam_arm64_binfmt_and_proton_prep

# Screen geometry — hardcoded for Pocket ACE (1080x1620 panel, 90° rotation)
W=1080
H=1620
REFRESH_HZ=60
TRANSFORM=90

# Re-exec under systemd scope if needed
STEAM_MAIN_SCRIPT="/usr/bin/start_steam_direct.sh"
steam_scope_reexec_if_needed "$@"

# Initialization run (only needed on first setup)
if [ ! -f /storage/.local/share/Steam/.steam_init_done ]; then
  SDL_VIDEODRIVER=x11 \
  LD_LIBRARY_PATH=/storage/.local/share/Steam/lib/aarch64-linux-gnu/ \
  ${EMUPERF} /storage/.local/share/Steam/steamrtarm64/steam -steamdeck -exitsteam 2>/dev/null || true
  touch /storage/.local/share/Steam/.steam_init_done
fi

# Disable Steam bootstrapper update check
echo "BootStrapperInhibitAll=enable" > /storage/.local/share/Steam/steam.cfg

# Launch gamescope directly on DRM
GAMESCOPE_MODE_SAVE_FILE=/storage/.config/gamescope/modes.cfg \
GAMESCOPE_FAKE_OUTPUT_MM=508x286 \
env -u WAYLAND_DISPLAY \
LD_LIBRARY_PATH=/storage/.local/share/Steam/lib/aarch64-linux-gnu/ \
${EMUPERF} \
  gamescope -W "$W" -H "$H" -r "$REFRESH_HZ" \
    --xwayland-count 2 --mangoapp --backend drm \
    --force-orientation right --use-rotation-shader -e -- \
  /storage/.local/share/Steam/steamrtarm64/steam \
    -steamdeck -steamos3 -gamepadui -noverifyfiles \
    -nobootstrapupdate -skipinitialbootstrap -norepairfiles

# Restore binfmt and start ES for "Switch to Desktop"
systemctl restart systemd-binfmt
touch /tmp/.bootgame_launched
systemctl start essway
exit 0
