# Field reports: forum thread 42717

Source: <https://forum.qubes-os.org/t/shiny-new-qwt-has-landed-was-old-man-yells-at-a-cloud/42717>
Fetched 2026-08-14. Reporter for everything below is **Dr. Gerhard Weck (GWeck)**, who runs a
**German** edition of Windows — which is why the locale work in FINDINGS.md matters to him directly.

A cached copy of the first 20 posts sits in the session scratchpad as `t42717.json`; it predates
these reports, so re-fetch rather than trust it. Discourse serves one post per URL fragment to a
fetcher - use the JSON API (`/t/42717.json?page=N`) to get whole pages.

## Post 27 — W11 25H2, QWT 4.2.2 template

1. **`qvm-create-windows-qube` finds nothing in our ISO and fails SILENTLY.** It globs for
   `qubes-tools-*.exe|msi`, which matches nothing in the QWT-NG ISO.
   *Status: our dom0 RPM claims to auto-patch `qvm-create-windows-qube` (README). VERIFY whether
   that patch covers this glob, and whether it was present in the build he used. A silent failure
   is the worst shape, so this deserves a loud error even when the patch is absent.*

2. **PV disk driver upgrade crashes the VM.** Uninstalling old QWT drops back to emulated IDE, and
   the next boot crashes; recovery needs a safe-mode boot before reinstalling.
   *Status: OPEN, and this is an UPGRADE path we have never tested - every test here installs onto
   a clean image. High severity: it bricks a working qube until the user knows the safe-mode trick.*

## Post 33 — W11, QWT 4.3.0

1. **PV disk driver installer prompt is not clickable** ("should a shutdown be performed?").
   *Status: same class as the Start/toast clickability work already done. `guest/dismiss-restart-prompts.ps1`
   exists for restart prompts - check whether it covers THIS dialog, and whether it runs early
   enough during install.*

2. **`control.exe` still reports 4.2.2.0** in the installed-apps list after installing 4.3.0.
   *Status: cosmetic but confusing - package version metadata not updated. Cheap fix.*

3. **Start menu via the Windows key renders only partially and cannot be used.**
   *Status: relates to tasks #4/#7 (shell-managed Start). Note he is on 4.3.0; the Start work landed
   later (agent 4dc559b on win11-fresh). Needs re-testing on a CURRENT build before treating it as
   still-open - it may already be fixed.*

4. **Shutdown button unreachable** - "the button is at the bottom right, which is not displayed",
   i.e. the Start card is cropped.
   *Status: same root cause as 3. This is the concrete user-visible consequence worth using as the
   acceptance test: can he shut Windows down from the Start menu?*

## Post 35

**`install /idd` fails**: "file not found" with a PowerShell `InvalidOperationException`.
*Status: this is exactly task #9 (`/iddonly` actually shipped + corrected README). Now confirmed
from the field rather than suspected. Get the exact failing line from him or reproduce locally.*

## Cross-reference: what 2026-08-14 already fixed

Several of his complaints may be stale by now, and re-testing on a current build costs less than
re-fixing. Today's session closed: the culture-bound progress bar (a **German** guest saw NO update
progress at all), the catalog-sibling rollback, non-ASCII paths mangled through `VMExec` (umlauts in
any `qvm-run` argument), Turkish/locale `ToLower` breaking the Xen PV driver check, and the
plain-HTTP truncation that made Windows Update fail on one boot and succeed on the next.

**Suggested order:** ask him to retest 3, 4 and the `/idd` flag on the current release first - those
are cheap to confirm and may already be closed. Then attack the PV disk upgrade crash (post 27.2),
which is the only one that leaves a user with a broken qube.

## Posts 41-55 (fetched separately, page 3) — the important half

### THE REGRESSION: agent 7ccb459 is worse than 09b643e (posts 54, 55)

GWeck, on **W10 22H2 AND W11 25H2**: `09b643e` "works well" with Open-Shell; **`7ccb459` brings
back serious mouse/window problems**. He asks for a `/noidd` switch.

`7ccb459` is what we SHIP (`v4.3.1-agentc7ccb45`). So the current release is a regression against the
previous one, on two different Windows versions, on his hardware. This outranks everything else here.

**INDEPENDENT OF THE START MENU** (user, 2026-08-14): he reproduces it with Open-Shell running.

CORRECTED 2026-08-14 - what that does and does not mean. It does NOT exonerate toastcrop or the
shell-managed policy: that code classifies and crops EVERY top-level window, whatever shell is
running, so Open-Shell only means the stock Start is not the surface being mangled. Those files stay
suspects.

What it DOES invalidate is **winenum as the diagnostic here**. winenum dumps top-level HWNDs and
their attributes to identify SHELL SURFACES; for a mouse-offset / window-position bug reproducing
without the stock Start in play, that dump does not describe the failure. His attached winenum.log
is evidence about the Start-menu case, not about this regression - do not lead with it.

It also reframes his "what is the IDD for in seamless?" question: he is not asking academically, he
suspects the IDD and wants it switchable. Our README currently says the opposite is policy - "no
switch to turn it off; the Basic Display Adapter is a failure state, not an option".

### Other posts

* **44, 45** - W11 25H2, 4.3.1: mouse position offset ~1 cm, text windows lose position, Windows key
  produces artifacts plus an error.
  **SCREENSHOTS ARE ATTACHED AND THEY ARE THE USEFUL ARTIFACT** (user, 2026-08-14). For a visual
  defect they beat any log we could ask him for: they show WHAT is misplaced and BY HOW MUCH,
  against surrounding window geometry, with no instrumentation to install and no round trip. Fetch
  the images from posts 44/45 FIRST and read the offset off them - direction, magnitude, and whether
  it is constant across the screen or grows with distance from the origin. That last property is
  what separates an origin/offset error from a scaling or DPI error, and it may be readable straight
  off the pictures.
  (A winenum.log is also attached, but it answers the Start-surface question, not this one.)
* **46, 47** - arkenoi: reproduced; "some stuff is 25h2 specific"; suspected "artifacts of non-idd
  legacy driver".
* **48, 49** - where Open-Shell entered: disabling the stock Start in seamless was considered, GWeck
  proposed Open-Shell and confirmed it works correctly on `09b643e`. That is the origin of the
  `enableWinKey` feature added 2026-08-14 - note it is built on the REGRESSED agent.
* **41** - corporateblush, W11, STOCK QWT: resize differs between seamless and non-seamless. Not ours.

### Order of attack

1. **Bisect 09b643e -> 7ccb459.** A known-good/known-bad pair on the reporter's hardware is the
   cheapest possible lead and we have both hashes.
2. Ask him for a MOUSE/WINDOW-COORDINATE artifact, not winenum: the agent log around a mis-click
   (protocol trace of the announced rect vs where the click lands), and whether the ~1 cm offset
   scales with window position or is constant. winenum.log answers a different question.
3. PV disk upgrade crash (post 27.2) - the only report that leaves a user with a broken qube.
4. Only then retest Start/`/idd` items on current; they may already be closed.
