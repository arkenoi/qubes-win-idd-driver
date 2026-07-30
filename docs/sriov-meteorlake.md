# Intel iGPU SR-IOV on Qubes/Xen — documented, NOT yet executed

Status: **transcribed reference, unverified by us.** Source: Qubes forum community guide
"Virtualised Intel GPU with SR-IOV"
(https://forum.qubes-os.org/t/virtualised-intel-gpu-with-sr-iov/40649), fetched 2026-07-30.
Commands below are as published; a few had obvious transcription typos in the source
(missing leading `/`), corrected here and flagged. **Verify against the live thread before
running anything** — this touches the dom0 kernel.

## Why this file exists

Meteor Lake SR-IOV under Qubes/Xen is **demonstrated for Linux guests** — a user reports a
NovaCustom V54 (Meteor Lake) on kernel **6.19.5.1** with "gpu acceleration is great,
browsing is so much smoother with it". Relevant because the target hardware here
(ASUS NUC 14 Pro+, Core Ultra 9 185H) is the same generation. Note upstream `xe` still does
NOT support MTL SR-IOV; this works via the out-of-tree strongtz i915 fork.

**It does not currently help the Windows display project.** `qubes-gui-agent-windows`
`capture.c:176-183` hard-fails when `DesktopImageInSystemMemory` is FALSE, so a VF driving a
Windows desktop *breaks* QWT capture (seamless AND fullscreen) rather than accelerating it.
Prerequisite: the staging-texture fallback (Phase 1B/#4 in ../CLAUDE.md). Reproduce this
with a **Linux** qube first; revisit for Windows only after the fallback lands.

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

1. Staging-texture fallback in `capture.c` must exist first (../CLAUDE.md Phase 1B / #4).
2. Windows guest + VF under Xen is **unverified anywhere** — every working report is a Linux
   guest. Expect the Intel Windows driver to be its own project.
3. Only then does the "removes the WARP ceiling" payoff become testable.
