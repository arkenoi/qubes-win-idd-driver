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

# THIS PACKAGE SHIPS NO dom0 SCRIPTS AND RUNS NOTHING IN dom0 beyond printing the notice below.
# It places the ISO, the auto-qwt stub and the manifest, and nothing else; the per-qube settings it
# used to apply are printed for the administrator to apply, which is why %%post is only a banner.

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
install -m 0644 %{SOURCE3} %{buildroot}%{qwtng_share}/MANIFEST.json

install -d -m 0755 %{buildroot}%{_docdir}/%{name}
install -m 0644 %{SOURCE2} %{buildroot}%{_docdir}/%{name}/README-qvm-create-windows-qube.md

%files
%{qwt_iso_dir}/qubes-windows-tools.iso
%dir %{qwtng_share}
%dir %{qwtng_share}/auto-qwt
%{qwtng_share}/auto-qwt/install-qwt.bat
%{qwtng_share}/MANIFEST.json
%doc %{_docdir}/%{name}/README-qvm-create-windows-qube.md

%post
cat <<'EOF'

qubes-windows-tools-ng installed.

  ISO:  /usr/lib/qubes/qubes-windows-tools.iso

The Windows binaries in this ISO are TEST-SIGNED: the in-guest installer enables testsigning
and trusts an unofficial certificate INSIDE THE WINDOWS GUEST. dom0 is unaffected.

THIS PACKAGE CHANGED NOTHING IN dom0 AND TOUCHED NO QUBE. Two per-qube settings cannot be set
from inside a guest, so apply them yourself to each Windows qube:

  qvm-features <qube> vmexec 1          dom0 sends its update commands over qubes.VMExec; without
                                        it qubesadmin falls back to qubes.VMShell, whose POSIX
                                        prep commands reach cmd.exe and fail before the update
                                        agent is reached
  qvm-prefs <qube> qrexec_timeout 600   a Windows boot APPLYING an update needs minutes to answer
                                        qrexec (measured 259 s); the 60 s default aborts the run
                                        at exactly that moment

Optional, for a usable application menu. A Windows guest reports every Start Menu shortcut it can
find, and dom0 ENABLES all of them until somebody makes a selection. MEASURED on a stock German
Windows 11 25H2 with no third-party software: 37 entries, of which 20 are the single folder
"Administrative Tools" - Registry Editor, services, Event Viewer, iSCSI Initiator, ODBC, Print
Management and the rest of the MMC consoles. All 37 stay AVAILABLE in Settings -> Applications
whatever you do here; this only picks what is enabled to begin with:

  qvm-features <qube> menu-items "<the .desktop names you want enabled>"
  qvm-features <template> default-menu-items "<the same>"   new AppVMs inherit this one

You do not have to compose that list by hand. Every run of the guest's own appmenu service writes
the suggested value to the guest log (Q:\Qubes Logs), on one line beginning MENU-RECOMMENDATION,
with the administration consoles left out and the applications kept.

UPDATES: with vmexec set, a Windows qube reports available updates to dom0 and is updated from
the Qubes Update tool like any other qube - no separate command and no script from this package.

Installing an update leaves the qube shut down: Qubes destroys a domain on a guest-initiated
reboot, and Windows finishes the update during its next boot. That boot happens by itself the
next time the qube is started or updated - for a template it is the boot that commits the
update to the template root.

NOTE on qvm-create-windows-qube: its auto-qwt stub globs for qubes-tools-*.exe|msi, which matches
nothing in this ISO and fails SILENTLY. The QWT-NG-aware stub is shipped as documentation under
%{qwtng_share}/auto-qwt/install-qwt.bat; swap it in yourself if you use QWCQ. This package does
not modify another package's files.

EOF

%changelog
* Sat Aug 08 2026 QWT-NG <noreply@example.com> - 4.3.0-1
- Initial QWT-NG 4.3 dom0 package: drop-in Windows Tools ISO for Qubes OS 4.3.
