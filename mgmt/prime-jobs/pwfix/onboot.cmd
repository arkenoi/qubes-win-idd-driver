@echo off
rem ===============================================================================================
rem  PRIME JOB: clear the dated password fuse from a PRISTINE base, and nothing else.
rem
rem  A pristine base carries no QWT, so there is no qrexec and no way in from outside. The resident
rem  primer hook, baked into every sealed golden, calls \qubes-prime\onboot.cmd exactly once AS
rem  SYSTEM at boot - before and independently of any interactive logon. That is the only channel
rem  into a base and the only moment that can act before the logon screen blocks.
rem
rem  The job carries clear-password-fuse.ps1 and runs it. That script records its own before/after
rem  into C:\qubes-pwfix.log inside the image: the stick is attached read-only, so the evidence has
rem  to live in the guest, and it travels with the image to whoever clones it next.
rem ===============================================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clear-password-fuse.ps1"
exit /b 0
