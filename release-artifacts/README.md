# release-artifacts — NOT in git any more, and deliberately so

This directory used to hold a COMMITTED COPY of built release output. It is now ignored, because
that copy became a bug rather than a convenience.

## What went wrong

The snapshot was last refreshed on 2026-08-12 and then drifted from source. On 2026-08-21 the
committed `qwt-improved-setup/install.cmd` was still the pre-fix installer: no `%SELF%` elevation
fix, no `/noidd`, no exit-code propagation - three releases after the source had been corrected.
Anyone taking the installer from the repository got the broken one, while CI had been building the
fixed one all along. That is exactly the defect behind GWeck's forum reports 35 and 64 (`C:\idd`,
`D:\idd`), which had already been fixed in `packaging/setup/install.cmd`.

A build output that lives in version control has no mechanism keeping it honest. Nothing read from
this directory - not the workflows, not `packaging/make-setup.ps1`, not `mgmt/` - so nothing ever
noticed it was stale.

## Where the real artifacts come from

They are built from source by CI and downloadable from the run:

    gh run list --workflow=release-package
    gh run download <run-id> -n qwt-improved-setup     # the installable directory
    gh run download <run-id> -n qwt-improved-iso       # the ISO
    gh run download <run-id> -n qwt-full-package       # the full QWT package
    gh run download <run-id> -n pv-xenvif              # the signed PV NIC driver

`packaging/make-setup.ps1` assembles the setup directory from `packaging/setup/` plus the staged
`guest/*.ps1`, so the SOURCE is the single place a fix has to land. `MANIFEST.json` in each artifact
records the package version and the exact agent commit it was built from - check that, not a file
committed months ago.
