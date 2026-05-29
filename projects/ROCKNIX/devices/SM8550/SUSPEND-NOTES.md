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
     the **CX rail staying enabled/voted at suspend** by consumer
     sub-domains (multimedia `mmcx` + `ufs_phy`/`pcie`/`gpu` GDSCs) that
     don't all release. Because the regular `cx` rpmhpd domain's *sleep*
     vote equals its *active* corner (`to_active_sleep`), any residual CX
     vote keeps CX on in sleep. (The interconnect/bus votes are a red
     herring — see the deep-dive; they are already correctly zero.)
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
   "off" votes for the relevant rails/resources.
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

### The interconnect/BCM votes are NOT the blocker (corrected)
A first pass blamed the bus-bandwidth (BCM) sleep votes, because the
`[sleep]`-set writes (trace `events/rpmh/rpmh_send_msg`, decode addr via
`/sys/kernel/debug/cmd-db`) showed nonzero data:
```
0x50000 MC0  (DDR)   0x50008 SH1 (LLCC)   0x50010 SN0 (SNoC)
0x50038 CN0  (CNoC)  0x50048 QUP1 (i2c)   0x50068 ACV   = data 0x40000000
```
**This was wrong.** Per `drivers/interconnect/qcom/bcm-voter.c`
`tcs_cmd_gen()`: when `vote_x==0 && vote_y==0` it sets `valid=false`, and
`BCM_TCS_CMD(commit, valid, vote_x, vote_y) = (commit<<30)|(valid<<29)|…`.
So **`0x40000000` = commit=1, valid=0, vote=0 — a ZERO bandwidth vote
with the commit bit set**, i.e. those buses are correctly voted OFF in
the sleep set. Dropping the USB (1 GB/s) and display (716 MB/s) *active*
icc votes therefore made no difference to `cxsd` (verified: still 0).
The interconnect is fine.

### The real blocker: the CX rail stays enabled/voted at suspend
The captured sleep set contained **only BCM addresses (`0x500xx`) and no
CX/MX rail votes (`0x300xx`)** — cmd-db maps `cx.lvl=0x30000`,
`mx.lvl=0x30010`, `mmcx.lvl=0x30080`, etc. `rpmhpd` *does* emit sleep
votes (`drivers/pmdomain/qcom/rpmhpd.c:912`,
`rpmhpd_send_corner(pd, RPMH_SLEEP_STATE, sleep_corner, …)`), but for the
regular (non-`active_only`) `cx` domain, `to_active_sleep()` sets
**`sleep_corner = active_corner`**. So CX's sleep vote simply tracks
whatever CX is voted to when we suspend — if any consumer still holds CX,
it stays on in sleep (and no *change* means no dirty flush, hence no
`0x30000` write appears in the trace).

Measured CX holders (`/sys/kernel/debug/pm_genpd/`):
- Awake, `cx` perf = 256.
- Unbinding USB drops it 256 → 64.
- Forcing display off too: **still 64**, held by `mmcx` (= 64, the
  multimedia-CX rail) plus enable-votes from
  `ufs_phy_gdsc/ufs_mem_phy_gdsc`, `pcie_*_gdsc`, `gpu_cc_cx/gx_gdsc`.
- `1d84000.ufshc` shows `runtime_status=active` (rootfs UFS never
  runtime-suspends).

So CX cannot reach corner 0 / disabled while those sub-domains are still
voting. During a real s2idle the device `suspend_noirq` phase *should*
drop pcie/ufs/gpu/display, but `cxsd` stays 0 — so at least one of them
is not releasing its CX vote in the s2idle path.

### Remaining work for CX collapse
- Determine, during an actual s2idle (not awake), which sub-domain keeps
  `cx`/`mmcx` voted: instrument `rpmhpd_aggregate_corner` /
  `genpd_power_off` for `cx`/`mmcx`, or trace the `0x30000`/`0x30080`
  rpmh writes across a cycle (note: only *dirty* votes are flushed, so
  force a corner change or read the cached vote).
- Prime suspects: `mmcx` held by the DPU/display path (DPMS-off alone
  did not clear it — the `ae00000.display-subsystem` device likely stays
  runtime-active), and the `ufs_phy` GDSC (UFS does not runtime-suspend).
- Make each holder release at suspend (proper device `suspend_noirq`,
  or quiesce in the pre-suspend hook), then re-test `qcom_stats`
  `cxsd/ddr/aosd`.

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
