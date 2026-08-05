# DRAFT upstream report — Xen Windows PV drivers: gnttab revoke of a still-mapped grant can spin unboundedly (guest livelock)

Status: **draft awaiting user approval** (standing policy). Target: XenProject Windows PV
drivers (xenbus/xeniface, github.com/xenserver or xenbits winpv), possibly via Qubes first
since QWT ships these drivers.

## Summary

On a Windows 10 (19045) HVM guest under Qubes OS 4.3 (Xen), a workload that rapidly
re-grants and revokes large framebuffer grant sets (via `IOCTL_XENIFACE_GNTTAB_*`) can
drive the guest into a whole-OS livelock: one CPU spins forever inside xenbus's grant
code with locks held, after which every other xenbus consumer (xenvchan/qrexec, ACPI
shutdown delivery) blocks. The guest never bugchecks; from outside it looks frozen with
elevated CPU. Reproducible within minutes with our workload.

## Evidence (NMI kernel dump, export-symbol stacks)

Spinning CPU at NMI time:

```
xenbus+0x1cd35            <- executing here (spin), reached via:
nt!MmUnlockPages+...      <- releasing granted pages (revoke path)
xenbus+0x1cbd1
xenbus+0x11bab
xeniface+0xc23c           <- IOCTL dispatch
xeniface+0xb07d
```

Other CPUs idle. Meanwhile dom0's `xl debug-keys g` shows the domain holding ~22,000
ACTIVE grant entries with pin flags set (still mapped by dom0) — the revoked-entry's
mapping had not been released by the dom0-side consumer at revoke time.

Normally a revoke of a still-mapped grant fails fast (we observe clean
`ERROR_NOT_FOUND`/busy returns, 0x490, on the same path); the unbounded spin is a rarer
race, plausibly revoke racing a concurrent dom0 unmap or maptrack contention.

## Expected behavior

A revoke of a still-mapped grant should fail (or retry boundedly) — never spin at the
kernel level with locks held. The guest OS must stay schedulable regardless of dom0-side
mapping behavior (dom0 holding mappings indefinitely is legal, if impolite).

## Reproduction sketch

Windows HVM guest with xeniface; a user-mode service that in a loop: grants a ~14k-page
buffer read-only to dom0 (`GNTTAB_PERMIT_FOREIGN_ACCESS`), has the dom0 peer map it, then
revokes while the peer's unmap is racing. Our full harness (Qubes GUI agent fork + resize
storm) wedges within ~2 minutes; a minimal repro should be extractable from the above.

## Environment

Xen (Qubes 4.3 dom0), guest Win10 19045.6466, PV drivers as shipped with QWT 4.2.2
(xenbus/xeniface versions TODO — read from guest driver properties before submission).

## To do before submission (user)

1. Approve text and venue.
2. Fill in exact xenbus/xeniface driver versions.
3. Optionally attach: full kd stack file, xl grant-table dump excerpt (both in the
   reporter's repo under instrumentation/hang-2026-08-04/), and the NMI dump on request.
