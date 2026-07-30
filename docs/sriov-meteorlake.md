# Intel iGPU SR-IOV on Qubes/Xen — documented, NOT yet executed

Status: **transcribed reference, unverified by us.** Source: Qubes forum community guide
"Virtualised Intel GPU with SR-IOV"
(https://forum.qubes-os.org/t/virtualised-intel-gpu-with-sr-iov/40649), fetched 2026-07-30.
Commands below are as published; a few had obvious transcription typos in the source
(missing leading `/`), corrected here and flagged. **Verify against the live thread before
running anything** — this touches the dom0 kernel.

## TL;DR for an agent reading this

1. **This is background reference. It is NOT a task.** Do not set up SR-IOV, do not attach a
   VF, do not add it to any plan unless the user explicitly asks.
2. **dom0 SR-IOV setup is harmless to Windows qubes.** Installing the module, GRUB changes,
   creating VFs — none of it is visible to a guest. QWT is unaffected. The user may be
   experimenting with this independently; it does not break your test VM.
3. **The only risky action is attaching a VF to a Windows qube.** If the desktop then moves
   off the Basic Display Adapter, `capture.c:176-183` fails fatally (no fallback, capture
   thread dies, display lost). Reversible by detaching the VF.
4. **We control this**: the agent is our code, so VF support arrives when we implement it
   (output pinning + staging-texture fallback). There is no external dependency to wait on
   and no coordination problem to solve.
5. Therefore: **do not attach a VF to a Windows qube** during any phase, unless the user
   explicitly asks for that experiment.

## Why this file exists

Meteor Lake SR-IOV under Qubes/Xen is **demonstrated for Linux guests** — a user reports a
NovaCustom V54 (Meteor Lake) on kernel **6.19.5.1** with "gpu acceleration is great,
browsing is so much smoother with it". Relevant because the target hardware here
(ASUS NUC 14 Pro+, Core Ultra 9 185H) is the same generation. Note upstream `xe` still does
NOT support MTL SR-IOV; this works via the out-of-tree strongtz i915 fork.

Recorded so the option is ready when the agent-side work makes it usable — not because it
is on the critical path. It is not.

## Security cost (do not skip)

- Out-of-tree DKMS kernel module running **in dom0 at kernel privilege**. The guide's own
  author flags this as "a security risk depending on your threat model".
- Qubes devs have called this path "not recommended" pending upstream support.
- A VF gives a guest DMA/MMIO access to a shared GPU engine; isolation rests on GuC
  firmware + IOMMU. Cross-VF side channels and DoS are realistic.
- Blacklisting `xe` in dom0 changes the graphics stack for the whole machine.

## Procedure (Linux guest)

### 1. Driver into dom0
Match the driver release to dom0's kernel (`uname -a`). Get the archive from
https://github.com/strongtz/i915-sriov-dkms, then transfer (archives only, not loose files):
```bash
qvm-run -p <VM> "cat <path/to/archive>" > code
unzip code            # or: tar -xaf code
sudo dkms add ./<extracted-dir>
sudo dkms install i915-sriov-dkms/<version>
```

### 2. Kernel command line
Add to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`:
```
intel_iommu=on i915.enable_guc=3 i915.max_vfs=7 module_blacklist=xe
```
```bash
sudo grub2-mkconfig -o /boot/efi/EFI/qubes/grub.cfg
sudo dracut --regenerate-all --force
```
Reboot. **Re-sign boot files if using HEADS/AEM.**

### 3. Create VFs (iGPU is normally PCI 00:02.0 — verify with `lspci`)
```bash
echo 7 | sudo tee /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs
```
(source had `sys/...` without the leading slash — corrected.)
1–7 supported; the guide suggests fewer VFs for gaming workloads. Not persistent across
reboots as written — needs a unit/rc script if you want it permanent.

### 4. Attach a VF to a qube
Assign the VF PCI device to the qube (Qubes Devices UI or `qvm-pci attach`), then:
```bash
qvm-features <VM> boot-mode.kernelopts.sriov "i915.force_probe=XXXX i915.enable_guc=3"
qvm-features <VM> boot-mode.active sriov
qvm-service <VM> --disable software-rendering
```
`XXXX` = device ID from `cat /sys/devices/pci0000:00/0000:00:02.0/device`
(source had `pci000:00` — corrected.)

Qube requirements: HVM mode, adequate RAM, **static RAM (memory balancing disabled)**, and
the qube's kernel must match dom0's.

### 5. Guest template
Install the same DKMS driver **inside the template** ("required on some (probably most)
systems, but not on all"). Per the Meteor Lake report, this was exactly the fix when the
driver loaded in dom0 but failed in the guest — modules do **not** propagate automatically.
Also ensure `firmware-intel-graphics` is present.

### 6. Verify
```bash
glxheads     # in the guest
```

## Known problems

- Display-output hangs in some games — "not really reproducible", per the guide author.
- Some games outright incompatible. Non-gaming acceleration reported as solid.
- Rebinding issues → add `rd.qubes.hide_pci=<pci-device>` (comma-separated for several VFs)
  to the dom0 kernel parameters.
- Hardware-sensitive: ThinkPad T14 Gen 5 reports SR-IOV **not** working with `xe` blocked in
  dom0, cause undetermined. Treat your machine as its own experiment.
- Kernel-version coupled: dkms rebuilds are needed on every dom0 kernel update, and driver
  releases lag kernels. Other generations show build failures on some kernels
  (i915-sriov-dkms issues #210, #327).

## If/when revisiting for Windows

Windows guest + VF under Xen is **unverified anywhere** — every working report is a Linux
guest. Expect the Intel Windows driver binding to a VF to be its own project.

### What happens if a VF is attached to a Windows qube

Two outcomes, decided by which adapter ends up owning the desktop:

- Desktop stays on the Basic Display Adapter → `DesktopImageInSystemMemory` stays TRUE,
  QWT unaffected. Only apps explicitly rendering on the VF gain anything; DWM still
  composites in WARP, so no drag/scroll/typing improvement.
- Desktop moves to the VF → `DesktopImageInSystemMemory` FALSE →
  `capture.c:176-183` fails **fatally, with no graceful fallback**: capture thread dies,
  seamless AND fullscreen are lost. Recover by detaching the VF (`qvm-kill` first; note
  screenshots and `qtest` are useless while capture is dead).

Since the agent is our code, the fix is ours to write whenever we want it: pin capture to a
chosen output, and implement the staging-texture fallback so a non-system-memory desktop is
capturable. Until that is written and tested, **do not attach a VF to a Windows qube.**

### The actual endgame pairing (why this matters later)

VF and the IddCx driver are COMPLEMENTARY, not alternatives. Windows' standard hybrid model
is: render on one adapter, present to a display-only adapter (how hybrid laptops and every
IDD product work). Target configuration:

    VF renders → DWM composites in HARDWARE → cross-adapter present into the IDD swapchain
    → agent grants those frames to dom0

That is where the WARP ceiling actually disappears while seamless keeps working. It requires
the IDD driver to exist first (../CLAUDE.md Phase 2B) — and in that configuration the
staging-texture fallback may become unnecessary, since frames arrive via the IDD swapchain
rather than Desktop Duplication.
