# appmenus — findings

## CURRENT STATE

AUTHORITATIVE — and the ONLY content of this file. The dated history log was amputated
2026-09-01 (owner call): the chronological format itself caused stale-first reads and
contaminated sessions. Maintain by editing bullets IN PLACE (add, correct, delete);
never append dated sections (the pre-commit hook refuses them). Every bullet carries
`[verified <date>]` or `UNVERIFIED`. Git history retains the old log for deliberate
forensics only — do not load it into context.

- dom0's per-qube Terminal and File Manager launchers key off FIXED desktop-entry ids that qubes-core-agent-linux installs on every Linux qube: `qubes-run-terminal` and `qubes-open-file-manager`. A Windows guest emitted neither, so they pointed at nothing. Both are now emitted by get-appmenus.ps1 and handled by start-app.ps1. [verified 2026-09-01]
- Two measured defects in start-app.ps1, both fixed: `Start-Process -Wait` held the qrexec service open for the app's whole lifetime, and `explorer.exe` with no argument yields the shell's own empty-title Progman window, not a browser window. [verified 2026-09-01]
- The log.ps1 dot-source guard and the bounded logon loop in that file are HARDENING, not observed causes - QUBES_TOOLS is set machine-wide and a session existed. [verified 2026-09-01]
- Verified guest-side (both entries emit, launch, and return in 4-5 s). Clicking them in dom0's menu after `qvm-sync-appmenus` is NOT yet confirmed. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.
