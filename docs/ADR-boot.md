# ADR - boot: what the guest and our tools may do in a fresh domain's first minutes

Decisions about the install and boot paths as seen from the device model. One section per decision, newest last.

## 1. Serialize and pace everything that reaches QEMU or Xen in a fresh domain's first minutes - ACCEPTED (owner, Jev), 2026-10-04

**Decided:** in the first minutes of a fresh domain - every install stage, every post-install boot, every boot with an emulated
medium - our product and our test tools never release work all at once. Anything that reaches the device model (QEMU in the stub
domain) or Xen happens ONE THING AT A TIME, each step started when the previous one's completion is OBSERVED: QWT's services after
msiexec come up one by one, each after the previous one is running. **The harness half is WITHDRAWN (owner, 2026-10-04: "420s? you
want me to tell each install is going to take 7min more because we are afraid to touch it?").** It said our test harness makes no guest
call in a boot's first minutes (prime-run `QUIET_BOOT_SECS`, 420 s); a hands-off window is avoidance that ships nothing - dom0 itself
calls into a new qube at once - and in the A/B it confounded the product change. The harness keeps touching the guest as the gate does.
Pacing means waiting for an observed completion, never a fixed sleep (owner: no pauses or timeouts as a fix).

**Why:** measured 2026-10-04 (findings/wedge.md): the stall is QEMU in the stub domain no longer completing the guest's I/O
requests - Xen holds a vCPU (pause_flags=4, blocked in Xen) waiting for the device model, the stub domain idle, nothing pending; in
2026-09-10's captures QEMU itself was stuck (QMP unanswered; once its greeting arrived 63 minutes late). It strikes in a fresh
domain's first minutes under concentrated activity, and a guest with no QWT at all froze that way, so the defect is below us. The
owner's observation ("the more we follow quality best practices, the worse the stalls") has this explanation (Jev 1.00): our
quality changes SYNCHRONIZED and CONCENTRATED the guest's demands on the device model at that moment - readiness waits that release
everything at once, deterministic fresh-domain transitions, readiness polling, instrumentation, synchronous cleanup - where ad hoc
code had spread them out by accident. The one change ever measured to help fits it: close+pin serialized every qrexec call's vchan
work on one CPU, 0/26 stalls under load vs 17/26 (Jev 0.74). The rule (Jev 0.93 over judging changes by exposure alone 0.07).

**Cost:** installs and test runs take longer by the serialization and the quiet window - tens of seconds to ~2 minutes per clean
install (the serialized start measured ~0.3 s).

**Not done:** the device-model defect itself - outside this repo; reported upstream only with the owner's approval of the exact
text. **Seen to fail / pass:** owed - the pre-registered clean-install A/B `mgmt/harness/paced-ab.sh` (CONTROL today vs PACED),
30 runs per arm, one-sided Fisher on stall counts, bar p <= 0.05; started 2026-10-04 11:51Z with the withdrawn harness window in its
PACED arm, so it cannot grade the product change; Jev: stop it 0.81, run STOCK vs OURS first 0.85 (`mgmt/harness/stock-ab.sh`).

## 2. The qrexec service opens only after stage 2's device work - ACCEPTED (owner, Jev), 2026-10-04

**Decided:** in stage 2 of `packaging/setup/Install-QwtImproved.ps1`, right after msiexec, only QdbDaemon is started - observed
RUNNING and READY (the local qubesdb answers /name), because the device work reads the qube class from the live qubesdb (the PV
NIC priming latch). QrexecAgent is HELD (`svc_serial_start`: held-for-device-work) through every step that reconfigures a device
or a driver - xenvif, xencons, the IddCx device and the emulated-VGA disable, the overlays, the PV NIC priming
latch, the netvm task, the shipping state, the UAC policy - and started, observed RUNNING, at the QREXEC-RELEASE site after the
last of them (`Start-HeldQrexecAgent`; the RESULT records the site and the hold's length: `svc_qrexec_start`,
`svc_qrexec_held_secs`). Every exit path after msiexec that does not power off starts it before its RESULT: Fail, the main catch, a
refused power-off. On the `-Auto -RebootAtEnd` path it is not started in this stage at all: the guest powers off within seconds,
the service is auto-start and comes up on the next boot as stock QWT's does, and the RESULT says so (not-started-powering-off). A
RESULT written on a non-power-off path with it still held is an error of its own (`svc_qrexec_never_started`); a release that does
not reach RUNNING is `svc_qrexec_start_failed`; both red in `mgmt/harness/result-flags.py`. No fixed sleep anywhere: every wait is
an observed condition with a bounded failure detector, one observation routine for every start (`Start-QwtServiceObserved`). The
offline suite `tools/tests/svc-serial-start-test.ps1` asserts the order on the shipped file and drives every path; each assertion
has a knob that makes it fail (`tools/tests/svc-serial-start-selftest.sh`).

**Amended 2026-10-04 (4.3.35):** the Windows Update agent deploy, which sat in this stretch in 4.3.34, runs right after the
QREXEC-RELEASE site. It touches no device or driver (a csc compile, the relay process, three scheduled tasks), and since 4.3.35 it
may wait for the previous updater's running boot scan - which reaches dom0's update proxy over qrexec, so inside the hold it had
no network path to finish on while dom0 could not reach the guest at all (docs/ADR-updater.md 13; Jev: move 0.99). The order is
asserted by the same offline suite (knob `deployinhold`).

**Why:** the mechanism, verified in source: Xen 4.19's `p2m_remove_entry` requests a device-model mapcache invalidate for every
page the guest removes from its physmap (XENMEM_decrease_reservation, unmapping a mapped grant), so the vCPU waits synchronously
for QEMU in the stub domain, and QEMU 9.0.2's invalidate handler runs `bdrv_drain_all` first. Every qrexec call INTO the guest
makes the guest map the caller's vchan ring and unmap it at close (the service side is the vchan client) - two synchronous QEMU
round trips per call; the guest's own outgoing calls and the agent's control channel only GRANT pages. Four recorded freezes (#3,
#5, #6, E18) are each a call into the guest that landed in stage 2 between the moment QWT's services came up after msiexec and
the stage's power-off - the window of the device work. Before 168f72c (2026-09-08) the stage-2 agent usually gave up after 60 s
waiting for QubesDB, so that window ran with no qrexec service; the stall rate jumped after it. Section 1 declined to hold qrexec
back for the stage; on this mechanism the owner chose it ("need the fix first ... checks a posteriori"). Jev: this shape 0.95
combined, "removes the window for every caller" 0.91, the top implementation risk the QubesDB dependency 0.45 - met by starting
QdbDaemon first and waiting for READY before any device-work step. The owner rejected any test-harness hands-off window: this is
a property of the product, enforced in the product.

**Cost:** qrexec answers only when the install is done. On the interactive path (install.cmd, or /auto without /reboot) the
no-qrexec phase of stage 2 grows by the device work - measured 33-60 s from msiexec's return to INSTALL COMPLETE over 25 archived
runs (2026-09-05..10-03) - on top of the ~60 s the MSI already takes; on the `-Auto -RebootAtEnd` path (the clean install through
prime-run) qrexec does not answer in stage 2 at all. dom0 calls issued meanwhile queue for `qrexec_timeout` and land together at
the release. The harnesses already live with a no-qrexec phase: `quick-upgrade.sh` and `e2e-wait.sh` call a stall only after
`STALL_SECS` (300 s) without an answer, and `admin.vm.Stats` needs no agent. A death of one of our components during the hold
reaches dom0 only through the guest log - the death reporter's notification rides the local qrexec-agent (`guest/qwt-notify-error.ps1`,
HONEST LIMIT).

**Not fixed:** a freeze in a post-install boot (#4 - our agent was running and answered the harness's first-answer burst, which
the stage-2 hold does not reach; the every-boot form, F2, waits on a premise probe) and a freeze with no QWT at all (J-C sp.1)
remain; QEMU's own hang is not ours to patch (dom0 is not patched - owner). The hold does not cover the pre-msiexec part of an
upgrade (the previous QWT's agent answers until the vchan_prestop stops it) or the seconds between the release and the end of the
stage. **A coin flip on the framing, stated plainly:** Jev rated "a product property rather than avoidance" at 0.44. The check is a
posteriori - the stall rate on the rig with this order against the record before it, through the gate as it runs, with no harness
quiet window. **Seen to fail / pass:** offline, every assertion of the suite fails under its knob (24 knobs, re-run by the reviewer: 77/0 clean); on the rig, gate #6 on
4.3.34 (24e28f46, 2026-10-04): QrexecAgent held 24.2 s through stage 2's device work and not started before the power-off, all
8 install cells PASS with no stall, record CLEAN - 0 of 8 at the recent ~18% rate has P = 0.21, so consistent, not proof.
