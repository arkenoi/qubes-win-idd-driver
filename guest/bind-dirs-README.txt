qubes-bind-dirs for Windows
===========================

Directories listed here persist across reboots of this AppVM: they are copied to
Q:\bind-dirs\<path> the first time and replaced by a junction to that copy at every boot,
before any service starts. This is the Windows counterpart of Linux Qubes' qubes-bind-dirs
(https://www.qubes-os.org/doc/bind-dirs/); full details in docs/BIND-DIRS.md of QWT-NG.

Create a file named  50_user.conf  in this directory (this README is not read: only *.conf
files are). Same syntax as on Linux, with Windows paths - QUOTE THEM:

    # Keep this application's state across reboots.
    binds+=( 'C:\ProgramData\SomeVendor\SomeApp' )
    binds+=( 'C:\Program Files\SomeVendor\Plugins' "C:\Data\Shared" )

    # Remove an entry a lower-numbered file added:
    binds=( "${binds[@]/'C:\ProgramData\SomeVendor\SomeApp'}" )

Then reboot. The outcome of every boot is in Q:\Qubes Logs\bind-dirs-result.txt and the log
in Q:\Qubes Logs\bind-dirs.log; problems are also printed on the boot screen.

Rules that differ from Linux (all are reported as errors, never skipped silently):
  * directories only (junctions cannot point at files);
  * C:\Windows, the Qubes Tools directory, C:\Users (MoveUsers owns it) and the top-level
    system directories cannot be bound; nothing outside C: can;
  * a path that exists neither on C: nor on Q: is an error (typo protection);
  * nested paths are refused; a bare (unquoted) path may not contain a backslash;
  * a syntax error anywhere aborts the whole run before anything is touched.
