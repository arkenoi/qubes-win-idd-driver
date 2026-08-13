# QWT-NG dom0 package.
#
# Installs the QWT-NG ISO exactly where Qubes tooling already looks for a Windows Tools
# image, so `qvm-create-windows-qube` and the manual "attach the QWT ISO" flow both find it
# with no argument changes:
#
#     /usr/lib/qubes/qubes-windows-tools.iso
#
# That path is not an invention: qvm-create-windows-qube checks for it directly and, on
# Qubes 4.3, prints "Qubes OS does not currently offer an official build of Qubes Windows
# Tools for 4.3. To continue, please build Qubes Windows Tools yourself and place it at:
# /usr/lib/qubes/qubes-windows-tools.iso". This package is that build.
#
# The ISO is consumed with NO signature or hash verification by that tooling
# (tools/unpack-qwt-installer.sh simply loop-mounts it and copies the contents), so the
# trust decision belongs to whoever installs this RPM. See the testsigning warning below.

%global qwt_iso_dir  %{_prefix}/lib/qubes
%global qwtng_share  %{_datadir}/qubes-windows-tools-ng

Name:           qubes-windows-tools-ng
Version:        %{?_qwtng_version}%{!?_qwtng_version:4.3.0}
Release:        %{?_qwtng_release}%{!?_qwtng_release:1}%{?dist}
Summary:        Qubes Windows Tools NG 4.3 - drop-in Windows Tools ISO for Qubes OS 4.3

License:        GPL-2.0-or-later
URL:            https://github.com/arkenoi/qubes-win-idd-driver
BuildArch:      noarch

Source0:        qwt-improved-setup.iso
Source1:        install-qwt.bat
Source2:        README-qvm-create-windows-qube.md
Source3:        MANIFEST.json
Source4:        qwt-ng-fix-qwcq
# Fallback/diagnostic updater command. The NORMAL way to update a Windows qube is the same
# click as any other qube: the guest answers dom0's stock qubes-vm-update, so the Qubes
# Update GUI drives it. This wrapper calls the guest service directly, which is useful when
# that path misbehaves and as the explicit CLI some admins prefer.
Source5:        qvm-windows-update
# Per-qube dom0 settings a Windows qube needs before dom0 can drive its updates: the
# `vmexec` feature and a qrexec_timeout long enough for a Windows boot that is applying an
# update. Neither can be set from inside the guest.
Source6:        qwt-ng-prepare-qube

# The stock package owns the same path. Conflict LOUDLY rather than silently replacing a
# signed vendor ISO with a test-signed one - a silent overwrite is exactly the kind of
# surprise this project has been burned by.
Conflicts:      qubes-windows-tools

%description
Qubes Windows Tools, next generation, for Qubes OS 4.3.

Built from upstream QWT 4.2.2 sources with a reworked GUI agent, a Xen PV network driver
that actually binds (stock 4.2.2 ships xenvif at VIF revision 0x09000004 while its own
xennet requires 0x09000005, so the PV NIC never binds and Windows silently falls back to the
emulated Realtek), and an IddCx display driver that becomes the guest's real display.

IMPORTANT - the Windows binaries in this ISO are TEST-SIGNED. The in-guest installer runs
"bcdedit /set testsigning on" and adds an unofficial certificate to the guest's Root and
TrustedPublisher stores. That weakens driver-signature enforcement inside the Windows guest
for as long as it stays enabled. It affects the guest only, not dom0. Install this only if
that trade-off is acceptable to you.

Installing this package does NOT change any Windows qube by itself; it only places the ISO
where the provisioning tools look for it.

%prep
# Nothing to unpack: the sources are installed verbatim.

%build
# Nothing to build: the ISO is produced by CI and passed in as Source0.

%install
install -d -m 0755 %{buildroot}%{qwt_iso_dir}
install -m 0644 %{SOURCE0} %{buildroot}%{qwt_iso_dir}/qubes-windows-tools.iso

install -d -m 0755 %{buildroot}%{qwtng_share}/auto-qwt
install -m 0644 %{SOURCE1} %{buildroot}%{qwtng_share}/auto-qwt/install-qwt.bat
install -d -m 0755 %{buildroot}%{_bindir}
install -m 0755 %{SOURCE4} %{buildroot}%{_bindir}/qwt-ng-fix-qwcq
install -m 0755 %{SOURCE5} %{buildroot}%{_bindir}/qvm-windows-update
install -m 0755 %{SOURCE6} %{buildroot}%{_bindir}/qwt-ng-prepare-qube
install -m 0644 %{SOURCE3} %{buildroot}%{qwtng_share}/MANIFEST.json

install -d -m 0755 %{buildroot}%{_docdir}/%{name}
install -m 0644 %{SOURCE2} %{buildroot}%{_docdir}/%{name}/README-qvm-create-windows-qube.md

%files
%{qwt_iso_dir}/qubes-windows-tools.iso
%dir %{qwtng_share}
%dir %{qwtng_share}/auto-qwt
%{qwtng_share}/auto-qwt/install-qwt.bat
%{qwtng_share}/MANIFEST.json
%{_bindir}/qwt-ng-fix-qwcq
%{_bindir}/qvm-windows-update
%{_bindir}/qwt-ng-prepare-qube
%doc %{_docdir}/%{name}/README-qvm-create-windows-qube.md

%post
# Apply the per-qube settings dom0-driven updates need, to Windows qubes that already exist.
# Only touches qubes whose `os` feature reads Windows - i.e. qubes that have run QWT - and is
# idempotent. Never fails the transaction: a report is enough.
%{_bindir}/qwt-ng-prepare-qube --all || :

cat <<'EOF'

qubes-windows-tools-ng installed.

  ISO:  /usr/lib/qubes/qubes-windows-tools.iso

The Windows binaries in this ISO are TEST-SIGNED: the in-guest installer enables testsigning
and trusts an unofficial certificate INSIDE THE WINDOWS GUEST. dom0 is unaffected.

UPDATES: a Windows qube installed from this ISO reports available updates to dom0 and is
updated from the Qubes Update tool like any other qube - no separate command. Two per-qube
settings make that work, and they were just applied to every existing Windows qube:

  qvm-features <qube> vmexec 1        dom0 sends its update commands over qubes.VMExec
  qvm-prefs <qube> qrexec_timeout N   a Windows boot APPLYING an update needs minutes to
                                      answer qrexec (measured 259 s); the Qubes default of
                                      60 s would abort the run at exactly that moment

For a qube created LATER, run:  qwt-ng-prepare-qube <qube>   (or --all)

Installing an update leaves the qube shut down: Qubes destroys a domain on a guest-initiated
reboot, and Windows finishes the update during its next boot. That boot happens by itself the
next time the qube is started or updated - for a template it is the boot that commits the
update to the template root.

EOF
# qvm-create-windows-qube's auto-qwt stub globs for qubes-tools-*.exe|msi, which matches
# nothing in this ISO and fails SILENTLY. Instead of telling the user to fix it, fix it:
# find QWCQ installations and swap in the QWT-NG-aware stub (original backed up once).
# Idempotent, reports what it did, never fails the transaction. Re-runnable any time as
# qwt-ng-fix-qwcq (e.g. after installing qvm-create-windows-qube later than this package).
%{_bindir}/qwt-ng-fix-qwcq || :

%changelog
* Sat Aug 08 2026 QWT-NG <noreply@example.com> - 4.3.0-1
- Initial QWT-NG 4.3 dom0 package: drop-in Windows Tools ISO for Qubes OS 4.3.
