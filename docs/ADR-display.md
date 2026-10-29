# ADR - display: the IddCx driver

Current path: `docs/ADR-graphics.md`.
This file keeps the detailed decisions. Section numbers are unchanged.

## In plain English

Stock Windows Tools has no display driver, so the guest runs on an emulated adapter with a fixed list of 29 resolutions. This package ships and activates an IddCx driver by default. It becomes the guest's only active display, the emulated adapter is disabled, and the guest resolution follows the dom0 window exactly. It can be switched off; that is also the recovery path for a black window.

The desktop is put on the IDD by the agent in the user session, behind a readiness gate. No other display may ever be active. The mode list is written by the agent and nothing ever snaps to a nearby resolution. The device is named Qubes Idd and is rebound in place on upgrade. The IDD never feeds frames through its own grant path without the owner's approval.

## The decisions at a glance

| § | decision | status |
|---|---|---|
| 1 | IddCx ships on and is the sole active output | ACCEPTED |
| 2 | Desktop put on the IDD by the agent | ACCEPTED |
| 3 | A monitor dom0 does not see is INACTIVE | ACCEPTED |
| 4 | Mode list is ours; nothing ever snaps | ACCEPTED |
| 5 | Device is Qubes Idd, rebound in place | ACCEPTED |
| 6 | IDD never feeds frames through its own grant path | ACCEPTED |

Detailed rules remain in this file. Status vocabulary: `docs/ADR-README.md`.
