# QWT-NG 4.3.28 — Windows Update works on guests whose account is not named "user"

This is 4.3.27 (the xenbus freeze fix) plus one more field fix, and unlike 4.3.27 it has been
through a **full, clean acceptance run**.

## The fix: updates failed on any guest not using the default account name

**Symptom.** On a Windows template whose local account is named anything other than `user`,
Windows Update reported **"no network" / could not find the proxy**, and the Qubes logs filled
with **authentication failures** from the qrexec wrapper. Updating from the Qube Manager appeared
to succeed while nothing had actually run. Reported by a field tester on 2026-09-10.

**Cause.** Two assumptions that only hold when the account happens to be called `user`. dom0 asks
the guest to run a service as its *default* user, which is the literal name `user`. The guest then
compared that name against the account actually logged in and, when they differed, **threw away the
valid session it already had** and tried to log in as `user` with a fixed built-in password. On such
a guest no `user` account exists, so that login failed and the service never started — including the
small helper that bridges Windows Update to the Qubes update proxy. No proxy, no updates.

**What changed.** A service meant to run in the interactive desktop now simply runs as **whoever is
actually logged in**, instead of matching a name and guessing a password. The update relay and the
notification client no longer name an account at all: the piece they start only moves bytes and
needs no user identity, so it runs under the system account. A helper that scheduled work under a
hardcoded `user` now reads the real account from the live session. And a login failure that quietly
downgrades a service is now logged loudly instead of silently.

**If you were affected,** no action is needed beyond installing this build: nothing about your
account name, password or template has to change.

## Also in this release

Everything from 4.3.27, most importantly the **PV bus driver freeze fix** (`xenbus.sys`): a race in
the driver's internal lock could leave a guest running but unreachable, burning a full CPU core,
recoverable only by killing the qube. See the 4.3.27 notes for detail. The fixed driver binds at the
first reboot after install.

## Acceptance

Full end-to-end acceptance **passed COMPLETE** on this payload: all eight install/upgrade/AppVM
cells across Windows 10 and 11 green (72 checks, 0 failures), both feature tests green, and the
verdict recorded. That run was performed on build `1912fd9`; this release differs from it by exactly
one source commit — the version bump — plus a notes file that is not part of the package.

**Known limitation, unchanged from 4.3.27:** the fixed bus driver binds at the reboot *after* the
install, so the rare freeze can still occur on that single install boot. If it does, kill and
restart the qube once and the fixed driver takes over.
