# SM8550 (AYANEO Pocket ACE) Suspend / Deep-Sleep Investigation

Status as of 2026-05-30. Device: AYANEO Pocket ACE, SoC Qualcomm SM8550
(Snapdragon 8 Gen 2), mainline Linux 6.15.2 (ROCKNIX labels it 7.0.2).

This documents the full root-cause analysis of suspend on SM8550 so the
work can be resumed without re-deriving everything.

---

## TL;DR

- **Use s2idle, not "deep".** Mainline SM8550 does not advertise PSCI
  SYSTEM_SUSPEND; `echo mem` "deep" is unstable and, crucially, never
  flushes the RPMh sleep votes (see below). `mem_sleep=s2idle` is the
  correct, stable mode.
- **Shipped & working:** stable s2idle (no reboot, no spurious wake when
  cool/idle), clean power-button + RTC wake, ~75% lower draw than
  awake-idle. Power-button suspend is gated per `system.suspendmode` so
  other (fake-suspend) devices are unaffected.
- **Two hard problems remain, both fully characterised here:**
  1. **No CX/DDR/AOSD collapse** → sleep draw is ~hundreds of mA
     (~10 h standby), not the multi-day deep-sleep target. Root cause is
     interconnect (bus-bandwidth) votes that never reach 0 in the RPMh
     sleep set.
  2. **Hard kernel hang when suspending under heavy load** (Steam/gamescope
     mid-game) — a task in uninterruptible (D) state can't be frozen.

---

## Committed patches / changes (branch `pocket-ace`)

| Item | What it does | Verdict |
|------|--------------|---------|
| `030-suspend_mode` quirk | forces `/sys/power/mem_sleep=s2idle` at boot | **keep** |
| `input_sense` | power button gated on `system.suspendmode`: mem/freeze/standby → `systemctl suspend`, else → stock `rocknix-fake-suspend` | **keep** (other devices safe) |
| `0510-arm64-dts-sm8550-add-deepest-idle-state.patch` | adds `system_pd` power-domain + `domain_ss3` (PSCI `0x0200c354`), re-points `apps_rsc` at `system_pd` | **keep** — this is what wires `rpmh_flush` to genpd |
| `0511-soc-qcom-aoss-add-deep-sleep-pm-ops.patch` | AOSS QMP suspend_noirq/resume_early | inert under s2idle; harmless |
| `0512-irqchip-qcom-pdc-save-restore-wake-config.patch` | PDC wake-config syscore save/restore across CX collapse | **fixes deep-wake** (only matters once CX actually collapses) |
| `0513-thermal-tsens-drop-wakeup.patch` | stop TSENS IRQs being system wakeup sources | **keep** — fixes "turns on by itself" |

Removed: the original `0510/0511` genpd-force-off patches (were for the
wrong "deep" approach).

---

## Symptom → cause map (all confirmed)

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| "device turns on by itself" after gaming | TSENS thermal IRQs are level-triggered + `enable_irq_wake`; when warm they storm and wake from s2idle (saw ~1900 IRQ 23 events in ~15 s) | `0513` drops `enable_irq_wake` (PMIC still does emergency thermal shutdown in HW) |
| "won't wake, fan spins" from deep | PDC wake-config registers wiped on CX collapse, never restored | `0512` PDC syscore save/restore |
| spurious wake during long sleep | same TSENS storm | `0513` |
| high sleep power (~hundreds of mA) | CX/DDR never collapse (see deep-dive) | **unsolved** |
| hard hang suspending under load | task in D-state can't be frozen (freeze deadlock) | **unsolved** |

---

## Deep-dive: why CX / DDR / AOSD never collapse

Goal counters live in `/sys/kernel/debug/qcom_stats/{aosd,cxsd,ddr,apss}`
(`Count:` field). Observed: `apss` increments (APSS collapses) but
`aosd/cxsd/ddr` stay **0** — the SoC never reaches true deep sleep.

Causal chain, each step verified on-device:

1. CX/DDR collapse in sleep is gated by the **RPMh Sleep TCS** carrying
   "off" votes for the DDR / LLCC / NoC bus clock managers (BCMs).
2. The Sleep/Wake TCS are programmed by `rpmh_flush()`.
   `rpmh_flush()` is invoked from `rpmh_rsc_pd_callback()` on the
   `GENPD_NOTIFY_PRE_OFF` of the power-domain that `apps_rsc` is attached
   to. Patch `0510` attaches `apps_rsc` to `system_pd` to enable this.
3. **`rpmh_flush` fires in s2idle but NOT in "deep".** Function-tracing
   (`current_tracer=function`, filter `rpmh_flush rpmh_rsc_pd_callback`)
   shows:
   - deep (`echo mem`): domains go down via `genpd_sync_power_off`
     (from `genpd_finish_suspend`) — **0** calls to `rpmh_rsc_pd_callback`
     / `rpmh_flush`. The suspend path does not fire the genpd PRE_OFF
     notifier.
   - s2idle: `rpmh_flush` fired ~1355×, `rpmh_rsc_pd_callback` ~5422×
     (cpuidle domain-idle path fires the notifier).
   → **s2idle is the only mode that can collapse CX.**
4. Even in s2idle the flushed **sleep-set votes are nonzero**. Trace
   `events/rpmh/rpmh_send_msg`, filter `[sleep]`, decode addresses with
   `/sys/kernel/debug/cmd-db`:
   ```
   0x50000 MC0  (DDR mem controller)  data 0x40000000   <- ON in sleep
   0x50008 SH1  (LLCC/cache bus)       data 0x40000000   <- ON
   0x50010 SN0  (system NoC)           data 0x40000000   <- ON
   0x50038 CN0  (config NoC)           data 0x40000000   <- ON
   0x50048 QUP1 (geni i2c bus)         data 0x40000000   <- ON
   0x50068 ACV  (aggregated active)    data 0x40000000   <- ON
   ```
5. Those BCMs stay voted because **interconnect (icc) bandwidth consumers
   never drop their votes to 0 in the sleep set.**
   `/sys/kernel/debug/interconnect/interconnect_summary`, DDR node
   (`ebi@interconnect-1`), average (committed) bandwidth voters:
   ```
   a600000.usb                 avg 1,000,000   (1 GB/s, constant)
   ae00000.display-subsystem   avg   716,325
   a90000.i2c                  avg       400   (touchscreen bus, see below)
   cpu*/pcie*/pmu              avg 0 (peak only)
   ```
   - **USB:** unbinding `a600000.usb` (dwc3-qcom) drops its 1 GB/s vote
     (verified). The pre-suspend hook already unbinds it.
   - **Display:** `swaymsg "output * power off"` drops the 716 MB/s vote
     `716325 → 0` (verified). NOT yet done in the suspend path — candidate
     fix: DPMS-off / disable CRTC before suspend.
   - **Touchscreen i2c:** `a90000.i2c` (bus i2c-2) hosts `2-0070`
     (synaptics_dsx, run in **polling mode**) → constant transfers keep the
     geni controller active → votes the whole QUP1→NoC→LLCC→DDR path on.
     This maps to the `QUP1 0x40000000` sleep vote.
6. **Even after dropping USB + display, `cxsd` stayed 0** — the residual
   i2c/QUP1 + `ACV` `0x40000000` votes remain. So collapse needs *every*
   bus voter released, and the meaning of the `ACV` vote / the
   `0x40000000` value still needs decoding (likely needs Qualcomm BCM
   command-format knowledge).

### Remaining work for CX collapse
- Ensure the geni-i2c / polling touchscreen fully drops its icc vote on
  suspend (unbind touchscreen earlier, stop polling, or force the i2c
  controller to runtime-suspend so QUP1 → 0).
- Add display DPMS-off / CRTC-disable to the pre-suspend path (drops the
  716 MB/s DDR vote). Note: in Steam, gamescope holds DRM directly
  (`--backend drm`), so sway DPMS won't apply — needs a gamescope-aware
  method.
- Decode `ACV` (`0x50068`) and the `0x40000000` BCM sleep value; confirm
  whether it is a real bandwidth vote or a structural keepalive.
- Re-test `qcom_stats` `cxsd/ddr/aosd` after each.

---

## Deep-dive: hard hang when suspending under load

- Reproduces only under heavy CPU/GPU load (e.g. Steam game running).
- Symptom: suspend stalls ("screen dims, hangs") or resume never
  completes (fan spins, no display, **no SSH** → kernel did not resume).
- Cause: the freezer cannot freeze a task stuck in an uninterruptible
  (D) state inside a driver (GPU fence / FEX / emulation path). Classic
  ordering deadlock: freezer waits for the task, the task waits for the
  GPU, the GPU isn't idled until the later device-suspend phase that is
  never reached. SIGSTOP does not help (a D-state task ignores it until
  it returns to userspace).
- This is independent of the sleep.d hooks and of `0513` (it was just
  masked before, because the TSENS storm woke the device before the
  freeze could deadlock).
- Direction: drain/idle the GPU before the freeze, or make the offending
  wait freezable/interruptible. This is the same class of problem SteamOS
  solved with deep amdgpu+gamescope drain-on-suspend work; not wired up
  for mainline Qualcomm + gamescope + FEX.

---

## How to observe (debug kernel)

A debug kernel is required for the tracing above. Debug-only config
(NOT committed; revert before shipping):
- `linux.aarch64.conf`: `CONFIG_PM_DEBUG=y`, `CONFIG_PM_ADVANCED_DEBUG=y`,
  `CONFIG_PM_SLEEP_DEBUG=y`, `CONFIG_FTRACE=y`, `CONFIG_FUNCTION_TRACER=y`,
  `CONFIG_DYNAMIC_FTRACE=y`
- `options` EXTRA_CMDLINE: `pm_debug_messages no_console_suspend`
- NOTE: enabling FTRACE exposed an old 2-arg `__assign_str()` in the
  ROCKNIX `qcom-hv-haptics` trace header
  (`include/trace/events/qcom_haptics.h`); it must be changed to the
  1-arg form for the build to compile with tracing on.

Useful commands:
```sh
# which deep low-power states were entered
for s in aosd cxsd ddr apss; do echo "$s=$(sed -n 's/^Count: //p' \
  /sys/kernel/debug/qcom_stats/$s)"; done

# RPMh sleep-set votes (need flush to have run, i.e. s2idle)
T=/sys/kernel/debug/tracing
echo 1 > $T/events/rpmh/rpmh_send_msg/enable; echo 1 > $T/tracing_on
# ... suspend ...
grep '\[sleep\]' $T/trace      # decode addr via /sys/kernel/debug/cmd-db

# is rpmh_flush firing?
echo function > $T/current_tracer
echo 'rpmh_flush rpmh_rsc_pd_callback' > $T/set_ftrace_filter

# interconnect bandwidth voters (DDR = ebi@interconnect-1)
cat /sys/kernel/debug/interconnect/interconnect_summary

# safely test which suspend phase hangs (auto-resumes ~5s) — PM_DEBUG only
echo freezer > /sys/power/pm_test   # also: devices / core
# ALWAYS read back /sys/power/pm_test before `echo mem`; if it didn't
# take, `echo mem` is a REAL suspend (will hang under load).
```

---

## Test environment notes
- Device reached over SSH via ZeroTier (alias `seac` → root@172.26.69.19,
  ProxyCommand through the builder `pc.seilent.net`). Builder hostname is
  `SeSL` — do NOT use nested `$(...)` command substitution through the
  builder's fish shell, it evaluates on the builder, not the device.
- ROCKNIX `/` is read-only squashfs. `/usr/lib/autostart/...` has a
  writable overlay (hot-copy works); `/usr/bin` does not (bind-mount to
  test). `/storage` persists across reboot — use it for logs that must
  survive a hang + power-cycle.
- Build on builder: `make docker-SM8550`; kernel build runs
  `kernel_make oldconfig` so it resolves added Kconfig symbols.
