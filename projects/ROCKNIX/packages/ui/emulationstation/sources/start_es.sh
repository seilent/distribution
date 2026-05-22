#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024 ROCKNIX (https://github.com/ROCKNIX)

### setup is the same
. $(dirname $0)/es_settings

# If a bootgame is configured, launch it once per boot (bypass ES)
BOOTGAME_CMD=$(get_setting global.bootgame.cmd)
BOOTGAME_FLAG="/tmp/.bootgame_launched"
if [ -n "${BOOTGAME_CMD}" ] && [ ! -f "${BOOTGAME_FLAG}" ]; then
  touch "${BOOTGAME_FLAG}"
  eval ${BOOTGAME_CMD}
fi

emulationstation --log-path /var/log --no-splash
