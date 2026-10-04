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
