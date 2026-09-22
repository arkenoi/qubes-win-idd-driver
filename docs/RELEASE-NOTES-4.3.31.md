# QWT-NG 4.3.31 — each notification is routed on its own merits, and the display device says Qubes

Everything in 4.3.30 is carried forward unchanged. This release changes two things a user sees: which
notifications reach dom0, and what the guest's display adapter is called.

## A notification is routed on its own merits, not on its application's name

4.3.30 forwarded notifications from **allowlisted applications**. An application nobody had
enumerated kept drawing its own banner inside the guest, whatever the notification was — which is
most applications, on most guests, most of the time.

Now every notification that is not already allowlisted is classified in its own right, and the
verdict decides the route:

- a notification that needs no answer from you is forwarded to dom0 and rendered there;
- a notification carrying buttons stays a guest window, so the buttons still work.

The allowlist remains as a shortcut for applications whose notifications are known to be
informational — they are forwarded without waiting for a verdict — and the built-in seed is
unchanged (Snipping Tool, Camera, Photos, Security & Maintenance, the backup reminder).

Nothing is ever dropped to make this work. A notification the classifier cannot place within about
six seconds, every notification while the bridge is unhealthy, and every notification on a Windows
build whose notification database does not match what the classifier expects, all keep the ordinary
window path. `qvm-features <vm> service.legacy-toasts 1` still forces the old behaviour outright.

Measured on a guest before release: an informational notification from a non-allowlisted application
was classified `verdict=bridge` and forwarded; a buttoned one from another non-allowlisted
application was classified `verdict=window` and kept its buttons on the guest path.

The reasoning behind the routing, including what happens when Windows moves the notification
database schema, is recorded in `docs/ADR-toasts.md`.

## The display adapter is called "Qubes Idd"

Device Manager showed the Microsoft sample's untouched placeholders: an **IddSampleDriver Device**
made by **&lt;Your manufacturer name&gt;**. It now reads **Qubes Idd**, by **Qubes OS (QWT-NG fork)**,
and the device's hardware id is `root\qubesidd`.

An existing guest is renamed in place. The driver package declares both the new hardware id and the
one every pre-4.3.31 guest carries, so an upgrade rebinds the devnode your desktop is already
running on instead of destroying and recreating it — a display device is not something to tear down
to change a label. Nothing else about the display changes.

## Upgrading

In-place over 4.3.30 or earlier, the usual way. The display device is renamed during the upgrade;
no reconfiguration is needed, and `qvm-features` settings are untouched.
