# DRAFT upstream report — `xl console` crashes with buffer overflow (dom0)

Status: **draft awaiting user approval** (standing policy: user approves exact text before any
upstream submission). Target: Xen project (xen-devel / xl tooling), possibly via a Qubes issue
first since the reproduction environment is Qubes dom0.

## Observed

On Qubes OS 4.3 dom0 (kernel 6.18.x, Xen version as shipped), attaching to the serial console
of a wedged Windows HVM domain:

```
$ sudo timeout 6 xl console win-idd-test
*** buffer overflow detected ***: terminated
timeout: the monitored command dumped core
```

`xl console` itself aborts via fortify (`__fortify_fail` → `*** buffer overflow detected ***`)
and dumps core. Reproduced once, 2026-08-04, against a domain that was in a CPU-spinning
livelock at the time (guest unresponsive, all vCPUs runnable). The console ring content at
that moment is unknown — plausibly garbage or unusually long lines from the wedged guest.

## Why it matters

A buffer overflow in a dom0 tool that parses data influenced by a (potentially hostile or
malfunctioning) guest is a robustness issue at a trust boundary: `xl console` reads the
console ring that the guest writes. Even if this particular overflow is in benign formatting
code, fortify-abort means out-of-bounds write reached libc's checks.

## Reproduction status

Not yet reduced. The domain state that triggered it (Windows HVM, 4 vCPUs, livelocked,
QWT PV drivers active, stubdomain present) is described in the reporter's project notes.
The core dump should still exist in dom0 (`coredumpctl list xl` / abrt) — retrieving a
backtrace from it is the obvious next step and should accompany the report.

## Ask for the user (before submission)

1. In dom0: `coredumpctl list | grep xl` and if present
   `coredumpctl info <pid>` / `coredumpctl gdb <pid>` → `bt` — attach the backtrace here.
2. `xl info | grep xen_version` and the xen package version, to pin the build.
3. Approve final text and the venue (xen-devel vs qubes-issues first).
