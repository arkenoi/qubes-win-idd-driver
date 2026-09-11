# QWT-NG 4.3.27 — Windows PV bus driver freeze fix (xenbus)

**Why this release exists:** on some boots a Windows guest would stop responding — the qube
stays *Running* and burns a full CPU core, but qrexec is dead, the window capture goes blank,
and nothing reaches the event log. It could only be recovered by killing the domain. This
release fixes the cause.

**Root cause.** The bug is in the Xen PV **bus** driver (`xenbus.sys`), in the hand-rolled
lock that guards its internal event-channel/grant hash table. Two threads releasing an
event channel on two CPUs at the same moment could race so that the lock's writer bit is left
set with nobody holding it. From then on the next event-channel close — and on Qubes **every
qrexec connection is an event-channel open and close in the guest** — spins forever at the
highest interrupt level, which is why no watchdog fires and the crash path itself deadlocks.
Stock Qubes Windows Tools ships this exact `xenbus.sys`; the driver is upstream Xen code that
XenServer's workloads never exercise the way Qubes' qrexec churn does.

**The fix.** `xenbus.sys` is rebuilt from the same pinned upstream commit Qubes uses, with the
bucket lock rewritten so the writer bit is taken and released by single compare-exchanges that
cannot leave a phantom holder. All other PV interfaces are unchanged, so `xenvif`, `xenvbd`,
`xeniface` and `xennet` bind exactly as before. The fixed driver installs after the MSI and
binds at the next boot (`DriverVer 9.1.0.442`, above the stock `9.1.0.0`).

**Proof.** A stress test that opens and closes event channels from four threads wedges a stock
guest within seconds; a guest carrying the fixed driver ran nearly three million open/close
pairs with zero errors and stayed responsive. The full driver package was also exercised
through clean-install, reinstall and upgrade cells on Windows 10 and 11.

Also in this build (test-harness and packaging robustness; no guest-facing behaviour change):
the release verifier now understands the rebuilt driver's message DLL, and two guest
health-check probes that were querying the Windows event log incorrectly were fixed.

**One caveat for testers.** The fix binds at a reboot *after* install. During the install boot
itself the guest is still on the old `xenbus.sys`, so the rare freeze can still happen on that
one boot; if it does, kill and restart the qube once and the fixed driver takes over.

---

**Acceptance:** published at the maintainer's request so field testing can begin now. The
automated end-to-end acceptance campaign was **not** run to a recorded CLEAN verdict on these
exact bytes — it differs from the 4.3.26-line bytes that were validated only by the version
number. Treat this as a **testing release**.
