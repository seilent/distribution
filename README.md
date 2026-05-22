# ROCKNIX - Pocket ACE Steam Edition

A fork of [ROCKNIX](https://github.com/ROCKNIX/distribution) with tweaks made for the AYANEO Pocket ACE, focused on running Steam.

## Changes from upstream

- Direct boot to Steam session (bypasses EmulationStation)
- Power button hold-to-suspend with haptic feedback
- Fake-suspend display fallback, fast resume, and auto-unmute
- Input sense axis filtering to prevent high CPU during joystick use
- Disable Proton xalia (high CPU on ARM)
- Xbox controller target (overrides upstream DualSense default)
- Timedatectl shim for Steam timezone persistence
- Audio tweaks: disable speaker compression, boost PulseAudio gain

## Build

```bash
make docker-SM8550
```

## Upstream sync

```bash
git fetch upstream
git rebase upstream/next
git push --force-with-lease origin pocket-ace
```

## Credits

Based on [ROCKNIX](https://github.com/ROCKNIX/distribution), which is a fork of [JELOS](https://github.com/JustEnoughLinuxOS/distribution/). All upstream licenses apply.
