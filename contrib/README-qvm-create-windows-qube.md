# Using QWT-NG with `qvm-create-windows-qube`

**Scope: this document applies ONLY to `qvm-create-windows-qube` users.** Installing
manually — attaching the ISO to the qube and running `install.cmd` inside Windows — needs
none of it; if that is you, stop reading here.

Read against the real upstream source (`QubesOS/qvm-create-windows-qube`, branch `master`),
not from memory. Line references are to that branch.

## What already works, unchanged

`qvm-create-windows-qube:191` checks for `/usr/lib/qubes/qubes-windows-tools.iso` and, on
Qubes 4.3, prints:

> Qubes OS does not currently offer an official build of Qubes Windows Tools for 4.3. To
> continue, please build Qubes Windows Tools yourself and place it at:
> `/usr/lib/qubes/qubes-windows-tools.iso`

So on 4.3 **QWCQ already expects a self-built ISO**. Installing `qubes-windows-tools-ng`
puts one there.

It is worth being explicit about what that means: the ISO is consumed with **no signature and
no hash check**. `tools/unpack-qwt-installer.sh` loop-mounts it and runs

```
cp -r "$iso_mntpoint/." "auto-qwt/installer"
```

then `tools/pack-auto-qwt.sh` runs `genisoimage -JR -o auto-qwt.iso auto-qwt`. Nothing
validates the contents. The trust decision is entirely the operator's.

`auto-qwt/trust-certificates.bat` already imports every certificate under `certificates/`
before the installer runs, which is compatible with QWT-NG's test-signing certificate.

## The one change that is required

`tools/auto-qwt/install-qwt.bat` upstream is:

```bat
cd installer || exit
for %%i in (qubes-tools-*.exe qubes-tools-*.msi) do (
    start %%i /passive
)
```

That glob expects a **single** `qubes-tools-*.exe|msi` at the ISO root. QWT-NG ships an
installer **tree** — `install.cmd`, `Install-QwtImproved.ps1`, `msi\installer.msi`, `certs\`,
`pv-drivers\`, `idd-driver\` — because the install is two-stage: the binaries are test-signed,
so testsigning must be enabled and the guest rebooted before the MSI can run. A single
`/passive` msiexec cannot express that.

**Left unpatched, the glob matches nothing.** There is no error and no dialog — the qube
finishes provisioning with no tools installed, which reads as "QWT silently failed" rather
than "the installer was never invoked". That silent-failure mode is the whole reason this
document exists.

## Since 4.3.2 this usually needs NO patch at all

The package now ships a `qubes-tools-<version>.exe` at its root whose only job is to start
`install.cmd` (`/passive` and friends map to `/auto`). That is the exact shape upstream's glob
looks for, so an UNPATCHED `qvm-create-windows-qube` finds it and runs it. The install also
costs only ONE guest shutdown now, which is what upstream's "restart the qube once, then wait
for os=Windows" sequence can survive - a second shutdown left it waiting on a halted qube.

The rest of this section describes the older patching route. It remains valid, and is still
what you want if you are running a build that predates the bootstrap executable.

**This is applied automatically.** The RPM's `%post` runs `qwt-ng-fix-qwcq`, which finds
`qvm-create-windows-qube` installations (the resolved entry point on `PATH`, plus
`/opt`, `/usr/local/share`, `/root` and `/home/*` clones), backs the upstream stub up
once as `install-qwt.bat.stock`, and swaps in the shipped replacement. It reports what it
patched, is idempotent, and never fails the package transaction. If you install
`qvm-create-windows-qube` *after* this package — or keep it somewhere the search does not
look — run it once by hand:

```
qwt-ng-fix-qwcq
```

(The manual equivalent remains a plain copy of
`/usr/share/qubes-windows-tools-ng/auto-qwt/install-qwt.bat` over
`<qvm-create-windows-qube>/tools/auto-qwt/install-qwt.bat`.)

The replacement stub runs `install.cmd /auto` when it sees a QWT-NG tree, and falls back
to the upstream glob otherwise, so the same file still works with a stock QWT ISO.

## What is NOT verified

These are behavioural and cannot be settled by reading source. Treat them as open until
someone runs the full flow end to end:

1. **Extra reboots.** `install.cmd /auto` reboots and resumes itself, consuming *more than
   one* reboot. `qvm-create-windows-qube` sequences provisioning with
   `wait_for_shutdown_or_qwt` (`:31`, called at `:334`, `:344`, `:368`). Whether that
   tolerates the additional cycle is untested.
2. **Drive letters.** `auto-qwt/run.bat` moves itself from `D:` to `E:` via
   `change-drive-letter.bat` so QWT can place the private volume on `D:`. QWT-NG installs
   `MoveUsers`, which relocates `C:\Users` to `Q:\Users` on the private image. The
   interaction between that relocation and QWCQ's drive-letter shuffle has not been
   exercised.
3. **Private volume size.** QWT-NG puts user data on the private volume. The Qubes default
   is 2 GiB and a bare Windows profile already uses ~550 MB, so a qube created with defaults
   will be tight. Extend it:

   ```
   qvm-volume extend <vm>:private 40GiB
   ```

4. **The whole path, on any platform.** Neither the QWCQ flow nor the manual "attach the ISO"
   flow from the Qubes guide has been run end to end with QWT-NG. Every acceptance and
   benchmark result in this repository came from this project's own clean-room provisioner
   (`scratchpad/usb-provision.sh` + `mgmt/build-answer-stick.sh`), which invokes
   `install.cmd /auto` directly. The installer is therefore well tested; **its integration
   with QWCQ is not**.
