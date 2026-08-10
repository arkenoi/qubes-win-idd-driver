# QWT-NG 4.3.1 — IDD display driver now ON BY DEFAULT (out-of-band fix)

**Why this release exists:** every prior build activated the Qubes IddCx display driver only
with an opt-in `/idd` switch. The default install therefore ran the **emulated Basic Display
Adapter** — i.e. stock display — so the headline capability of this package (arbitrary guest
resolutions that follow the dom0 window, no oversized fixed-mode snapping) was silently off
for everyone who didn't pass the flag. That was a stale gate from when IDD-vs-capture was
unproven; it is validated now.

**The fix:** the IddCx driver is installed **and activated by default and mandatory**. There is
no user switch to skip it — the Basic Display Adapter is a failure state, not a supported
option. If activation ever fails, the install still completes (the guest stays usable) but it
is logged as an **ERROR** and flagged in the result (`detail.idd_failed`), never silent
success. `install.cmd /idd` is now a redundant no-op; there is deliberately no `/noidd`
(a `-NoIddDriver` switch exists for TESTING only).

Everything else is unchanged from v4.3.0-agent09b643e (agent `09b643e`: idle-burn fix, in-place
MSI upgrade, PV-disk gate, app HW-accel pre-tweak). This release changes only the installer's
IDD default.

**Acceptance note:** published out-of-band to stop shipping the wrong display default; full
end-to-end re-acceptance (fresh-guest IDD activation + seamless capture confirmation) is being
run separately and will be recorded in FINDINGS.md.
