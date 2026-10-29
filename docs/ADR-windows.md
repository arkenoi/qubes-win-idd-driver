# ADR - windows: which guest surfaces become dom0 windows

Current path: `docs/ADR-graphics.md`.
This file keeps the detailed decisions. Section numbers are unchanged.

## In plain English

Not every window a Windows guest has should become a window on your desktop. The agent decides.

Boot, sign-in, lock and shutdown screens are never shown. A borderless window filling the whole guest screen is shown only if dom0 opted in for that qube. A maximized application with a title bar is always fine. The secure desktop is never presented as free-standing windows in seamless mode. Chrome fragments are dropped. Menus and tooltips are sent borderless. If the capture helper is missing or dead the agent fails visibly rather than silently falling back. Autologon is enforced because a guest without a session is unreachable.

## The decisions at a glance

| § | decision | status |
|---|---|---|
| 1 | Boot, logon and shutdown screen never shown (Mode 1) | ACCEPTED |
| 2 | Borderless true-fullscreen shown only when dom0 opts in (Mode 2) | ACCEPTED |
| 3 | One control: service.gui-fullscreen | ACCEPTED |
| 4 | Secure desktop handled by mode | ACCEPTED |
| 5 | Non-seamless desktop is one bounded window | ACCEPTED |
| 6 | Chrome fragments are not windows | ACCEPTED |
| 7 | Popups, tooltips and toasts are override-redirect | ACCEPTED |
| 8 | No composite fallback on a direct-capable guest | ACCEPTED |
| 9 | Seamless tweaks applied in one place | ACCEPTED |
| 10 | Autologon enforced | ACCEPTED |

Detailed rules, evidence and open items remain in this file below the original section headings. Status vocabulary: `docs/ADR-README.md`.
