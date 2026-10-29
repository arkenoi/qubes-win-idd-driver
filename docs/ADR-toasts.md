# ADR - guest notifications: the toast bridge

Current path: `docs/ADR-graphics.md`.
This file keeps the detailed decisions. Section numbers are unchanged.

## In plain English

A Windows notification in a seamless qube is forwarded to dom0's own notification service by default and the guest banner is suppressed while the connection is up. The route is decided per toast by a classifier that looks at the toast's own content. When the bridge is unsure the toast keeps the old guest-window path. Buttons travel to dom0 as actions only when every button can be carried; otherwise the toast stays a guest window. The guest banner is suppressed by not mapping it, never by ShowBanner. All switches are read once at agent start.

## The decisions at a glance

| § | decision | status |
|---|---|---|
| 1 | Guest notification is dom0's to render | ACCEPTED |
| 2 | Route decided per toast; allowlist is a shortcut | ACCEPTED |
| 3 | Misrouting fails open | ACCEPTED |
| 4 | Allowlist ships with a conservative seed | ACCEPTED |
| 5 | Dom0 notification is the copy | ACCEPTED |
| 6 | Error reporting is a sibling route | ACCEPTED |
| 7 | Every gate read once at agent start | ACCEPTED |
| 8 | Classifier stops when it cannot trust inputs | ACCEPTED |
| 9 | Allowlist is guest-side; switches that matter are dom0's | ACCEPTED |
| 10 | Banner suppressed by not mapping it | ACCEPTED |
| 11 | Buttons travel as actions, all or none | PROPOSED |

Detailed rules remain in this file. Status vocabulary: `docs/ADR-README.md`.
