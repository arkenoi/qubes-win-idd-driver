# How other hypervisors make a Windows guest's resolution follow the host window
(researched 2026-08-05 at the user's request; sources cited inline; fact vs inference marked)

## The universal pattern (every non-Microsoft stack converges on it)

Host pushes exact geometry -> guest user-mode agent receives it -> agent pokes the display
driver via a private escape/IOCTL -> driver mutates a reserved "custom mode" slot in its mode
table (NO replug) -> the SAME user-mode agent applies the mode via SetDisplayConfig /
ChangeDisplaySettingsEx. Nobody replugs monitors per resize; nobody ships a dense grid for
autofit; the requested size is offered and applied exactly; the OS never auto-switches — the
agent always commits the mode.

## 1. VirtualBox (VBoxWddm + VBoxTray) — verified from source
- Replug-on-resize exists behind `VBOX_WDDM_REPLUG_ON_MODE_CHANGE` but is COMPILED OUT with
  in-source comments calling it "a bad idea". Instead the miniport injects the mode into the
  live monitor source mode set via DxgkCbQueryMonitorInterface -> pfnAddMode — a raw-DXGK
  facility IddCx does not expose.
- Dense builtin list (10 entries) + ONE self-replacing transient custom slot per target —
  repeated drags never grow the list. Arbitrary width exact under VBE_DISPI_ID_ANYX, else
  masked to &0xFFF8.
- VBoxTray applies: VMMDEV_EVENT_DISPLAY_CHANGE_REQUEST -> D3DKMTEscape(VBOXESC_UPDATEMODES)
  -> SetDisplayConfig(SDC_USE_SUPPLIED_DISPLAY_CONFIG|SDC_VALIDATE then |SDC_APPLY|
  SDC_SAVE_TO_DATABASE) with a fallback ladder and retry timer.
- Pitfalls: persisted tiny custom mode bricked boot until range-checked (#16843);
  D3DKMTInvalidateActiveVidPn "causes deadlocks since Win10 TH2"; SetDisplayConfig needs
  scanLineOrdering=UNSPECIFIED with database refresh values.
- Sources: VBoxMPVidPn.cpp / VBoxMPVModes.cpp / VBoxMPWddm.cpp / VBoxDispIf.cpp (mirror/vbox
  on GitHub), virtualbox.org/wiki/Guest_resizing, ticket #16843.

## 2. QEMU/KVM: qxl-wddm-dod + vdagent; virtio-gpu viogpudo — verified from source
- qxl-wddm-dod (KMDOD): escape rewrites a custom slot, then
  DxgkCbIndicateChildStatus(Connected=TRUE) — a CONNECT-ONLY re-assert forcing monitor
  re-query; no Connected=FALSE anywhere. TWO reserved rotating custom slots — alternation
  defeats dxgkrnl's mode-set dedup (inference). Applied by vdagent:
  SetDisplayConfig(SDC_APPLY|SDC_USE_SUPPLIED_DISPLAY_CONFIG|SDC_FORCE_MODE_ENUMERATION|
  SDC_SAVE_TO_DATABASE) — FORCE_MODE_ENUMERATION makes the injected mode eligible.
  Win10 broke this vs Win7 until the D3DKMTEscape rework (vrozenfe/qxl-dod#7).
- viogpudo: EDID list + one custom slot; config interrupt -> rewrite slot -> connect-only
  UpdateChildStatus(TRUE) (FULL replug present in source but COMMENTED OUT — tried and
  disabled); driver signals Global\VioGpuResolutionEventN; per-session viogpuap applies via
  SetDisplayConfig. Without the service nothing switches (RH bug 1923886).
- Sources: daynix/qxl-wddm-dod QxlDod.cpp (~4919/4972/4905), spice win32 vd_agent
  display_configuration.cpp (~637), virtio-win viogpu sources.

## 3. VMware — SVGA II takes any SVGA_REG_WIDTH/HEIGHT; guestrpc DisplayTopologyModes_Set
pushes a mode list at runtime; vmtoolsd -> VMwareResolutionSet.exe -> SetDisplayConfig.
VRAM-bounded; boot topology applies post-login. (Win32 backend closed; strings + KB
316485/331544/313896.)

## 4. Parallels — full PCI WDDM miniport (prl_kmdd.sys), Toolgate video channel, dynamic
resolution via Tools; NO IddCx evidence. Mostly inference; thin public record.

## 5. Microsoft RDP / Enhanced Session — the IddCx path itself
- Resize = IddCxMonitorUpdateModes(new single mode) + IddCxAdapterDisplayConfigUpdate()
  ("Scenario 4", IddCx 1.4 remote updates). Departure/arrival ONLY when monitor count changes.
- IddCxAdapterDisplayConfigUpdate(2) is documented REMOTE-ONLY; InitAsync rejects console
  drivers claiming REMOTE_SESSION_DRIVER. The apply half of RDP's resize is structurally
  unavailable to a console driver. Win10 19045 = IddCx 1.5 frozen; UpdateModes2 etc are 1.10.
- MS-RDPEDISP size constraints worth copying for the dom0->guest channel: width 200-8192 AND
  EVEN; height 200-8192 (evenness not required).

## 6. Console IddCx prior art
- IddCxMonitorUpdateModes has NO documented remote-only restriction, but two public console
  failure reports exist (MS Q&A 5924412: monitor blinks black, mode never appears;
  Windows-driver-samples#1184: MonitorObject "no real effect" multi-monitor) and zero public
  successes. Its only first-party consumer is remote.
- Every shipping console virtual display (parsec-vdd, VirtualDrivers/Virtual-Display-Driver,
  ge9/IddSampleDriver, Looking Glass LGIdd) is modes-fixed-at-attach + replug/restart to
  change. parsec-vdd documents unplugging monitors latest-index-first to dodge Win10 registry
  caching; VDD#254: too many modes breaks monitor init.
- On arrival Windows auto-applies the EDID-preferred mode UNLESS the GraphicsDrivers\
  Configuration cache for that monitor path wins. STABLE EDID identity across replugs keeps
  one Enum\DISPLAY instance; rotating identities => runaway registry + "random resolutions".

## Synthesis for Phase 2B-resize (IddCx 1.5, console, Win10 19045)
1. The industry pattern rests on DXGK verbs IddCx hides (pfnAddMode / IndicateChildStatus).
   Our only in-place verb is IddCxMonitorUpdateModes — legal on console per docs, publicly
   unproven there (our D3 spike is exactly this experiment).
2. Replug-per-resize is what nobody else ships (VBox compiled out, viogpu commented out) but
   the only demonstrated-working console-IddCx mechanism. Mitigations: STABLE EDID identity,
   requested size as sole/preferred mode at arrival, agent follow-up apply for the
   Configuration-cache-override case. Blackout duration data does not exist publicly — ours
   is first.
3. Sizes: adopt RDP constraints (even width, 200-8192). Debounce drag; one final size per
   gesture; every unique size persists to the registry database.
4. The user-mode agent must own the apply step in any design (matches every working stack).
