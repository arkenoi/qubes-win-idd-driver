# appmenus — findings

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below. A correction belongs HERE,
not only as a new dated section — the whole reason this file exists is that 654
correction lines were buried chronologically in a 25k-line log, so reading a topic
top-down returned the stale answer.

- dom0's per-qube Terminal and File Manager launchers key off FIXED desktop-entry ids that qubes-core-agent-linux installs on every Linux qube: `qubes-run-terminal` and `qubes-open-file-manager`. A Windows guest emitted neither, so they pointed at nothing. Both are now emitted by get-appmenus.ps1 and handled by start-app.ps1. [verified 2026-09-01]
- Two measured defects in start-app.ps1, both fixed: `Start-Process -Wait` held the qrexec service open for the app's whole lifetime, and `explorer.exe` with no argument yields the shell's own empty-title Progman window, not a browser window. [verified 2026-09-01]
- The log.ps1 dot-source guard and the bounded logon loop in that file are HARDENING, not observed causes - QUBES_TOOLS is set machine-wide and a session existed. [verified 2026-09-01]
- Verified guest-side (both entries emit, launch, and return in 4-5 s). Clicking them in dom0's menu after `qvm-sync-appmenus` is NOT yet confirmed. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

## 2026-08-11 (cont.) — START MENU CAPTURED (user opened it by hand) — 24H2 renders it CORRECTLY

The user opened Start manually on win11-24h2 and I took an immediate `qtest fullshot`. dom0's window
list (the authoritative one, with the override_redirect column):
    0x1c00190  531 142  858x890  or=1 mapped=1  Start
    0x1c0018e 1524 700  396x332  or=1 mapped=1  New notification      <- a TOAST, mapped, override-redirect
    0x1c0018b  123 129 1426x746  or=0 mapped=1  Untitled - Notepad

Pixel measurement of the capture (numbers, not impressions):
- the red qube border around the popup runs x 531..1388 (**858 px**) and y 142..1031 (**890 px**);
- the announced geometry is **858x890** — an EXACT match, and the visible Start card fills it
  (854 px wide inside the 2 px border on each side).
VERDICT: on 24H2 the Start menu is announced with correct geometry and dom0 renders it correctly.
The "thin border" the user sees is dom0's own border around an override-redirect popup, which is
CORRECT Qubes behaviour (Linux qubes border menus the same way) — not a defect. No oversized
rectangle, no stale-pixel band, no garbling on this build.

So the S1a "garbled Start" remains a 25H2-side claim, unreproduced by us; 24H2 is now a clean
CONTROL for it. Toasts are confirmed mapped as override-redirect windows on this build too.

METHOD NOTE that unblocked this: **manual input works where every injected input path failed.**
Automated keybd_event / mouse_event / WM_COMMAND all leave the Start CoreWindow at 1x1 cloaked=2.
Any Start-related test therefore needs either a human keystroke or an input path we have not found
yet; the storm probe measures the agent under Start CHURN, but cannot be trusted to have opened
Start at all unless a guest-side capture confirms it. Also confirmed: a qrexec call taken while
Start is open STEALS FOCUS and closes it — capture dom0 FIRST, ask the guest questions after.

## User requirements added 2026-08-11 (not yet implemented)
1. **The Win key must NOT work from a seamless app.** The user confirmed the agent does not
   currently suppress it. In seamless mode a guest Start menu opened by a stray Win press is
   unmanaged UI in the middle of the dom0 desktop.
2. **The Start menu should instead be reachable as a regular app-menu item** (a normal launcher
   entry for the qube), which is the Qubes-native way to expose it.
Both are Track A / 2A-chrome scope and must wait until the menu is proven to render correctly.

## 2026-08-11 (cont.) — 25H2 START MENU = GWeck S1a, MEASURED; and a crash-loop I caused

**S1a IS REPRODUCED.** From the 18:17 fullshot of win11-fresh (25H2) with Start open, measured:
    announced / bordered by dom0 : 531,142  **858 x 890**
    visible Start card           : 544,145  **832 x 874**
    dead margin inside the border: L=13  T=3  R=13  B=13
On **24H2 the same menu has NO margin** (announced 858x890, card fills it - measured earlier today).
So 25H2's Start gained a shadow inside its window rect, dom0 borders the whole rect and fills the
margin with composited desktop. That is the user's "thin border with extra stuff within rectangle",
and it is the same defect class as the toast - which is why the earlier class-name crop
(FlexibleToastView/ToastView) could never have fixed it.

FIX PUSHED: the card is now found GEOMETRICALLY - the largest descendant fully inside the window
and strictly smaller in BOTH dimensions. The strictness matters: the toast's ScrollViewer is 396
wide inside a 396-wide window and would otherwise win. Classifier widened to
StartMenuExperienceHost.exe and SearchHost.exe; the fixed 1000x600 ceiling removed (it would have
excluded Start at 858x890), oversize surfaces still handled by IsPopup's 90% rule.

**CRASH-LOOP I CAUSED, and the lesson.** The first geometric build crash-looped on win11-fresh:
unhandled c0000005 at address 0, a new agent log every ~6 s, the qube's windows gone from dom0.
Cause: the rewrite left the old `IUIAutomationElement_get_CurrentBoundingRectangle(card, ...)` call
in place while `card` is never assigned any more - a NULL COM pointer deref on the first shell
popup after startup. Reverted with `swap-agent.ps1 -Restore`; the shipped binary brought the
display straight back. Fixed and pushed; NOT yet rebuilt or redeployed.
The build was CI-green and both static reviews passed it. **Compiling is not working.** Any deploy
must now be followed by: same PID after 60 s AND the agent log not rotating, before any measurement
is taken - a crash-loop check, added to the deploy routine.
(The user's "a lot of sounds and zero toasts" was this: Windows kept firing notifications while the
agent was dead, so nothing reached dom0.)

## 2026-08-12 (cont.) — Movable Start on 25H2: WALLPAPER PHANTOM, root identified, investigating

USER-VISIBLE: movable Start moves+stays (NOACTIVATE fix works) but renders "a peek into the
underlying desktop" - pure wallpaper, no menu. Also "responds to resize", and the opener
flashed "two terminal windows".

DECISIVE EVIDENCE (win11-fresh 25H2, build CEBD5650):
 - A GUEST-SIDE screenshot shows NO Start menu rendered in the guest at all (only Notepad +
   toast) while dom0 shows a framed or=0 "[win11-fresh] Start" at 2352,56 1201x919 full of
   wallpaper. So the agent maps a StartMenuExperienceHost window that the guest is NOT
   presenting as an open menu = a PHANTOM (the persistent Wnd_StartFeed window that exists
   while Start is CLOSED - GWeck-investigation class).
 - Agent: PwAttach 0x10184 1201x919 SLICE-FED, then "no card measured for
   4294966630x4294966546" = GetRealWindowRect returned an INVERTED rect (-666 x -750).
 - EnumWindows from a guest script sees ZERO StartMenuExperienceHost top-levels (shell
   surfaces evade it; only the agent's hook tracking sees 0x10184).
 - ~2h earlier (C55DCDA7) a fullshot showed a CORRECT 832x736 cropped card - so the agent
   CAN render Start right when it is genuinely open; the failure is state-dependent.

Multiple root threads (investigation wf_82456c4a running): (a) the closed-Start phantom
passes ShouldAcceptWindow+IsShellToastWindow and is mapped showing wallpaper; (b) slice-feed
of a moved shell surface reads a screen region with no menu pixels; (c) GetRealWindowRect
returns negative for the managed Start, poisoning crop + slice geometry.

FIXES LANDED THIS ROUND (necessary, not sufficient alone):
 - Sticky crop (agent, toastcrop.c): last-good insets per hwnd, never revert a managed shell
   surface to uncropped. Fixes the garble+resize WHEN a card was ever measured; does not help
   a phantom that never had a card.
 - SWP_NOACTIVATE on daemon moves (main.c): a frame drag no longer dismisses Start. CONFIRMED
   working (moved+stayed).
 - Windowless wscript/VBS Start opener (installer + guest scripts): no more conhost flash
   that dismissed Start ("two terminal windows").

PROCESS NOTE: went too fast in the live loop here (3 user-visible failed attempts) - the
25H2 Start capture is a real investigation, not a one-shot fix. Stopped guessing; running
wf_82456c4a with the guest-pixel evidence to decide movable-managed-with-fixes vs
correct-corner-drop-movable.

## 2026-09-01 — "Run Terminal": what it is, and why OUR Windows equivalents launch nothing

**What the Linux shortcut actually is.** No magic: `qubes-core-agent` ships
`/usr/share/applications/qubes-run-terminal.desktop` (`Name=Run Terminal`,
`Exec=qubes-run-terminal`) INSIDE the VM. dom0 picks it up through `qubes.GetAppmenus` and
launches it through `qubes.StartApp+qubes-run-terminal`. `/usr/bin/qubes-run-terminal` is a shell
script that tries `x-terminal-emulator ptyxis gnome-terminal kgx xfce4-terminal konsole ... xterm`
and execs the first one present. (Not to be confused with `qubes.ShowInTerminal`, which is the
DispVM-xterm service behind `qvm-console-dispvm`.)

**Do we have it for Windows? The PLUMBING yes, the FUNCTION no.** Our fork already emits built-in
appmenu entries from `get-appmenus.ps1` - Command Prompt, Command Prompt (Administrator), Windows
PowerShell (+admin), Notepad, File Explorer, Settings, Edge - precisely because a fresh Windows
guest's Start Menu sweep finds almost nothing and seamless mode has no taskbar or desktop. But
owner, 2026-09-01: *"it does not open a terminal from dom0 either ... neither it does file
manager. we need both."* Correct. Reading `start-app.ps1` found **four independent ways it
launches nothing and reports nothing**, all now fixed:

1. **Unguarded dot-source on line 1**: `. $env:QUBES_TOOLS\qubes-rpc-services\log.ps1`. With
   `QUBES_TOOLS` unset in the service environment this expands to `. \qubes-rpc-services\log.ps1`,
   **throws**, and the script is dead before it reads its argument. `get-appmenus.ps1` carries an
   explicit warning about this exact trap and was hardened; `start-app.ps1` - the half that
   actually launches things - never was.
2. **An unbounded wait**: `while (!(Get-CimInstance Win32_ComputerSystem).UserName) { sleep }` has
   no exit. No session (or a throwing CIM call) = spin forever = the qrexec call hangs and the
   menu entry does nothing. Now bounded at 60 s and it says which exit it took.
3. **`Start-Process -Wait`** held the qrexec service open for the launched app's ENTIRE LIFETIME.
   Linux's qubes.StartApp does not wait. This is also why a manual
   `qrexec-client-vm <vm> qubes.StartApp+cmd` appears to hang (measured: rc=124).
4. **`explorer.exe` with no argument** asks the already-running shell to act and the new process
   exits immediately; whether a window appears depends on shell state. Now passes `%USERPROFILE%`
   so it deterministically opens a browser window.
Plus a fifth: a missing AppMap value threw unhandled, so a stale entry died silently. Every
failure path now writes to stderr, which qrexec returns to dom0, instead of being a menu entry
that does nothing.

**CORRECTED, and this is the ACTUAL cause - owner, 2026-09-01:** *"these launchers are tied to
fixed labels on linux, and those labels do not exist on windows, we need to create them."* Right,
and my four-bug hunt above was largely beside the point. dom0's per-qube launchers are wired to
SPECIFIC desktop-entry ids that `qubes-core-agent-linux` installs on every Linux qube
(`app-menu/Makefile`): **`qubes-run-terminal.desktop`** and **`qubes-open-file-manager.desktop`**.
A Windows guest emitted NEITHER id, so those launchers had nothing to point at and did nothing.
Our own ids (`cmd`, `explorer`, ...) are extra entries; they were never what dom0's Terminal and
File Manager buttons look for. Both ids are now emitted by `get-appmenus.ps1` and handled by
`start-app.ps1`, with the upstream names verbatim ("Run Terminal", "Open File Manager").

Of the four defects found while going the long way round, exactly TWO were real and observed:
`Start-Process -Wait` blocks the service forever (measured: the child was still running after
25 s), and `explorer.exe` with no argument yields the shell's own empty-title Progman window
rather than a browser window (measured: `explorer pid=5628 title=''`). The other two - the
unguarded dot-source and the unbounded logon loop - are hardening, NOT observed causes:
`QUBES_TOOLS` is set machine-wide (`C:\Program Files\Qubes Tools\`) and a session existed.
Recorded as hardening so nobody later cites them as the fix.

**NOT VERIFIED YET, and it must be before this is claimed fixed.** win10-app's qrexec stopped
answering mid-session - self-inflicted: I ran `taskkill /f /im cmd.exe`, which killed the
`qubes.VMShell` shell running that very command (the self-matching-process trap, in a new
costume). The PV console confirms the guest is alive (`[ATTACHED] / WIN-IDD-TEST login:`) - and
demonstrates its documented limit at the same time, since post-reboot it is at a login prompt and
this rig holds no guest credentials, so I can see the guest but not act on it. There is also no
PowerShell in this dev qube, so the two edited scripts have only had a brace-balance check, not a
parse. Acceptance is: deploy both scripts, `qvm-sync-appmenus`, then launch Command Prompt, Run
Terminal and File Explorer FROM THE DOM0 MENU and see three windows.

**Unrelated note for the owner:** the dom0 policy dialog seen during this was MY call -
`qubes.StartApp` is not granted to win-idd-mgmt in `12-install-policy-tagged.sh`, so it fell
through to an ask rule. dom0's own menu launches are not affected by that.

**Kit defect found at the worst possible moment (2026-09-01).** `dom0/11-wedge-forensics.sh` took
its subject from `VM="${VM:-win-idd-test}"` with no argument - so the documented invocation,
during a LIVE wedge on `win10-app`, would have aborted with "FATAL: win-idd-test not running per
xl list" against a qube that has not booted in weeks, losing the evidence while someone worked
out why. Now `sudo ./11-wedge-forensics.sh <vm> [--nmi]`, arguments in any order, with a usage
message that lists the running domains. `VM=` env still works, which is how
`13-install-wedge-forensics-service.sh` invokes it (`VM="$VM" /usr/local/sbin/win-wedge-forensics.sh`)
- verified unchanged. A forensics tool that defaults to the wrong subject at the only moment it
matters is worse than no tool.

