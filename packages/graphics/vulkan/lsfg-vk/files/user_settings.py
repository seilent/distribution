# LSFG-VK integration for Proton
# Translates LSFG_DLL_PATH_UNIX (set by lsfg wrapper) to LSFG_DLL_PATH
# (the env var actually read by liblsfg-vk.so inside the container)
import os

user_settings = {}

if os.environ.get("LSFG_ENABLE") == "1":
    dll_path = os.environ.get(
        "LSFG_DLL_PATH_UNIX",
        "/storage/games-internal/roms/steam/steamapps/common/Lossless Scaling/Lossless.dll",
    )
    user_settings["LSFG_DLL_PATH"] = dll_path
