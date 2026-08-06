# Seamless/Office defect investigation — 2026-08-07

Target: win-idd-test, agent cb1fa4b, seamless (mode=s), IDD primary 5120x1440, guest DPI 150%.
Session log: `C:\Program Files\Qubes Tools\log\gui-agent-20260806-235115-3644.log`.

Executive verdict: **both reported defects are instrument artifacts, not agent bugs.**
The real, user-impacting item found is the maximize clamp (task 3), plus two harness gaps
that manufactured the false defects.

---

## DEFECT A — "full-screen (Windows Desktop) window mapped in seamless": REFUTED

**The desktop window (protocol window 0) is NOT mapped in dom0.** The X window exists but
is withdrawn; the fullshot geometry harness cannot tell the difference.

### Evidence

1. Agent log (boot, 2026-08-06 23:51):
   ```
   23:51:16.220 StartFrameProcessing: CaptureInitialize failed 0x887a0026 (A7RETRY attempt 1)
   23:51:17.073 SendWindowUnmap: Unmapping window 0x0
   23:51:17.088 SetSeamlessMode: Seamless mode changed to 1
   ```
   `SendWindowMap(NULL)` logs the distinct string "Mapping desktop window"
   (agent/gui-agent/send.c:500). That string appears **nowhere** in the session log:
   MAP(0) was never sent. UNMAP(0) was sent and is not gated — window-0 messages bypass
   the CREATE gate by design (send.c:270-273).
2. Daemon side: MSG_UNMAP for window 0 does a plain `XUnmapWindow`
   (upstream/ro/qubes-gui-daemon/gui-daemon/xside.c:3977-3990); MSG_CREATE does not map.
   So after CREATE(0)+UNMAP(0) the X window exists in the tree, unmapped.
3. Live probe (00:41): `qtest resize query` -> `GEOM ok=1 x=0 y=56 w=5120 h=1384`.
   The service picks the **largest window in `_NET_CLIENT_LIST`** (dom0/10-install-
   resize-service.sh). The desktop window is 5120x1440 = 7.37 Mpx; the largest managed
   window found is a 5120x1384 Word frame. A mapped, managed 5120x1440 window would have
   won. The desktop window is therefore not in `_NET_CLIENT_LIST` => withdrawn/unmapped.
4. Fresh fullshot geometry (00:39) listed 7 windows including `0x1c00188 0 0 5120 1440 0
   win-idd-test (Windows Desktop)` — alongside three Word documents and the sign-in
   dialog the user sees. The desktop entry is the unmapped X window.

### Why the harness lied

`dom0/07-install-fullscreen-screenshot.sh` builds geometry.txt from
`xwininfo -root -tree` (lists ALL windows, mapped or not) and never reads the
`Map State:` line that `xwininfo -stats` already outputs (lines ~99-113 of the
installed service). An unmapped window is indistinguishable from a mapped one.

### The timing question (a)/(b)/(c)

None of the three. `g_SeamlessMode` is loaded from the registry at process start
(main.c:4305-4315) and was TRUE from the first instruction — hence `mode=s` on the first
QGAPERF frame and `M6SEAMLESS` lines at 23:51:15 (BuildIddModeSet, resolution.c:305-308,
reads the already-TRUE global during init). The *application* of the mode
(UNMAP(0)+ResetWatch) deliberately happens inside StartFrameProcessing
(main.c:3505 -> SetSeamlessMode(g_SeamlessMode, TRUE), map/unmap at main.c:1917-1947),
which this boot was delayed ~1.7 s by the 0x887a0026 capture-init retry. The
"SetSeamlessMode logged after M6SEAMLESS" ordering is init-log vs apply-log, not a bug.
At no point was window 0 mapped this session.

### Fix (harness, minimal)

```diff
--- a/dom0/07-install-fullscreen-screenshot.sh
+++ b/dom0/07-install-fullscreen-screenshot.sh
@@
-    echo "# id x y w h override_redirect name"
+    echo "# id x y w h override_redirect mapped name"
@@
         ovr=$(printf '%s' "$info" | grep -c 'Override Redirect State: yes')
+        ms=$(printf '%s' "$info" | grep -c 'Map State: IsViewable')
         name=$("${X[@]}" xprop -id "$id" WM_NAME 2>/dev/null |
                sed -n 's/^WM_NAME(\(STRING\|UTF8_STRING\)) = "\(.*\)"$/\2/p' | head -1)
-        echo "$id ${x:-?} ${y:-?} ${w:-?} ${h:-?} $ovr ${name:-?}"
+        echo "$id ${x:-?} ${y:-?} ${w:-?} ${h:-?} $ovr $ms ${name:-?}"
```
(Requires the user to re-run the installer in dom0; the info is already in the
`xwininfo -stats` output the service parses, so this costs nothing.)

No agent change needed for defect A.

---

## DEFECT B — "Word's main frame 0x2032C never mapped": REFUTED (misidentified hwnd)

**0x2032C is not Word's main frame.** Live enumeration (winprobe.ps1, 00:41):

```
HWND=0x2032C cls=MSO_BORDEREFFECT_WINDOW_CLASS style=0x96000000 ex=0x00080080
     owner=0x0 rect=(1303,785)-(2164,790)   # 861x5 DIP strip, title empty
HWND=0x602FA cls=OpusApp  title=Document1 - Word   rect=(-4,30)-(3417,964)
HWND=0x50366 cls=OpusApp  title=Document3 - Word
HWND=0x50354 cls=OpusApp  title=Document2 - Word   rect=(-21333,...)  # iconic
HWND=0x20328 cls=NUIDialog title=Sign in to set up Office  owner=0x602FA
```
(Coordinates are DIPs — the probe process is DPI-virtualized at 150%; multiply by 1.5
for physical. 0x2032C is a 5 px Office frame-shadow strip hugging the bottom edge of the
sign-in dialog 0x20328, painted 785..790 directly below the dialog's 243..785.)

- Word's real frames (class **OpusApp**) ARE mapped, with per-window buffers:
  ```
  00:26:35.278 PwAttachWindow: 0x602fa: per-window buffer 5110x1379 attached
  00:26:35.278 SendWindowMap: Mapping window 0x602fa
  00:26:35.795 SendWindowMap: Mapping window 0x20328
  00:27:47.394 SendWindowMap: Mapping window 0x50354
  00:33:47.099 SendWindowMap: Mapping window 0x50366
  ```
- dom0 confirms (fullshot 00:39): `Document1 - Word`, `Document2 - Word`,
  `Document3 - Word` (each 0,56 5120x1384) and `Sign in to set up Office`
  (1962,364 1275x813) all present — matching what the user sees on screen.
- 0x2032C is **correctly rejected** by ShouldAcceptWindow rule 3, the exact class match
  `MSO_BORDER_EFFECT_CLASS` (main.c:2159-2166; define main.c:171). It is pure
  decoration; dropping it is the 2A-chrome fix working as designed. Proof it is
  rejected rather than lost: no X window for any 5 px strip exists in the dom0 tree at
  all (rejection happens before AddWindow, so no CREATE is ever sent).
- Why "never logged as rejected": the rule logs at **LogVerbose** (main.c:2163,
  deliberate — strips are re-examined at input rate during drags) and the deployed log
  level is Info. Silence in the log is expected, not evidence of a swallow.
- Note: on this build the strips are **unowned** (owner=0x0), unlike the owned strips
  measured in FINDINGS 2026-08-02. Style-based rule 2 (main.c:2121-2134, requires
  Owner != NULL) would NOT catch them; only the class rule does. The class rule is
  therefore load-bearing — do not weaken it.
- The earlier "dom0 shows only Desktop+Notepad while 0x50366/0x20328/... were mapped"
  observation was a stale fullshot: those maps happened 00:26-00:33; the current
  fullshot shows every one of them. (0x103c6 no longer exists — a transient window,
  likely Word's splash.)

**No agent fix needed.** Optional hardening (not required): a once-per-hwnd LogDebug on
class-rule rejection would make future forensics cheaper without the input-rate flood.

---

## TASK 3 — maximize clamp: VERIFIED DEFECT (the one real agent issue found)

`GetWindowData` clamps a maximized window's rect to **screen bounds**
(main.c:977-997: `x2 > g_HostScreenWidth`, `y2 > g_HostScreenHeight`), while the thing
dom0 will actually grant is the **work area**.

Measured on live state:
- dom0 work area: 0,56 5120x1384 (top panel 56 px).
- Guest applied work area (workarea.c g_WaLastApplied, log 23:54:52):
  `(5,56)-(5115,1435)` = 5110x1379 physical.
- Maximized Word raw rect: (-4,30)-(3417,964) DIP = (-6,45)-(5126,1446) physical
  (work area + DWM invisible borders).
- Screen clamp yields (0,45)-(5120,1440) = **5120x1395** — overflowing the work area by
  11 px top and 5-6 px right/bottom. dom0's WM then constrains the window to 5120x1384,
  the daemon echoes it back, and only the DaemonMaxValid feedback clamp
  (UpdateWindowData, main.c:2255-2261) stops the CONFIGURE ping-pong — after one
  round-trip and a per-window grant rebuild, with an ~11 px content/geometry mismatch
  band until it settles. Before the qubesdb work-area feed arrives (23:51-23:54 this
  boot: applied area was a stale `(0,31)-(1920,1080)` then `(0,31)-(5120,1440)`),
  maximized windows genuinely ignore the dom0 workspace — this is the user-visible
  symptom that was blamed on the "mapped desktop window".

**Yes, it should clamp to the applied work area** (fall back to screen bounds when no
work area has ever been applied). `g_WaLastApplied` is static in workarea.c:41 with no
accessor, so one must be added.

### Proposed minimal fix (not applied)

```diff
--- a/gui-agent/workarea.h
+++ b/gui-agent/workarea.h
@@
 // Record a dom0-provided work area + frame extents (qubesdb or MSG_WORKAREA).
 void WorkAreaSetDom0(int x, int y, int w, int h, int fl, int fr, int ft, int fb);
+
+// Copy out the last successfully applied guest work area (physical px).
+// FALSE until the first successful apply - callers fall back to screen bounds.
+BOOL WorkAreaGetApplied(OUT RECT* applied);
--- a/gui-agent/workarea.c
+++ b/gui-agent/workarea.c
@@ -222,6 +222,14 @@ void WorkAreaApply(void)
     EnumWindows(WaRefitProc, 0);
 }
 
+BOOL WorkAreaGetApplied(OUT RECT* applied)
+{
+    EnterCriticalSection(&g_WaLock);
+    *applied = g_WaLastApplied;
+    LeaveCriticalSection(&g_WaLock);
+    return !IsRectEmpty(applied);
+}
+
--- a/gui-agent/main.c
+++ b/gui-agent/main.c
@@ -977,14 +977,21 @@
     if ((entry->Style & WS_MAXIMIZE) && entry->IsVisible &&
         g_HostScreenWidth > 0 && g_HostScreenHeight > 0)
     {
-        int cx = entry->X < 0 ? 0 : entry->X;
-        int cy = entry->Y < 0 ? 0 : entry->Y;
+        // Clamp to the work area dom0 can actually display, not the raw screen:
+        // dom0's WM constrains the window to ITS work area, so reporting anything
+        // larger just buys a CONFIGURE round-trip, a grant rebuild and a content
+        // mismatch band until DaemonMax feedback settles. Screen bounds remain the
+        // fallback until the first work-area apply.
+        RECT wa;
+        if (!WorkAreaGetApplied(&wa))
+            SetRect(&wa, 0, 0, (int)g_HostScreenWidth, (int)g_HostScreenHeight);
+        int cx = entry->X < wa.left ? wa.left : entry->X;
+        int cy = entry->Y < wa.top ? wa.top : entry->Y;
         int x2 = entry->X + (int)entry->Width;
         int y2 = entry->Y + (int)entry->Height;
-        if (x2 > (int)g_HostScreenWidth)
-            x2 = (int)g_HostScreenWidth;
-        if (y2 > (int)g_HostScreenHeight)
-            y2 = (int)g_HostScreenHeight;
+        if (x2 > wa.right)
+            x2 = wa.right;
+        if (y2 > wa.bottom)
+            y2 = wa.bottom;
         // All-or-nothing: a window entirely off-screen keeps its raw geometry rather
         // than getting a half-applied clamp.
         if (x2 > cx && y2 > cy)
```

Risk note: if Explorer wins the work-area fight (workarea.c backoff path), the OS work
area can exceed `g_WaLastApplied` and the clamp could crop up to that delta; the pixels
in question are ones dom0's WM will not show anyway, and the existing DaemonMax clamp
already imposes a harder cap once dom0 responds. Acceptance for the fix: maximize Word,
verify the FIRST reported geometry equals the dom0 work-area rect (no post-hoc
CONFIGURE shrink in the daemon log), and verify a maximized window still repaints
correctly after a work-area change (panel added/removed in dom0).

---

## Ranking by user impact

1. **Maximize clamp to work area** (real defect; visible as maximized windows
   overflowing/ignoring the dom0 workspace, worst during the boot window before the
   qubesdb work-area feed lands). Fix above.
2. **Fullshot geometry harness: add Map State** — it manufactured defect A and will
   keep producing false "window X is mapped" findings until fixed. Fix above (dom0
   reinstall needed).
3. **Defect B: none** — Word mapping works; 0x2032C is Office chrome correctly dropped
   by the 2A-chrome class rule. Keep the class rule; note the strips can be UNOWNED, so
   rule 2 alone would not cover them.

## Instrument validity notes

- winprobe.ps1 (this session's enumerator) collects into an ArrayList (Write-Output in
  the EnumWindows delegate is lost) and was validated against windows KNOWN to be
  mapped (Notepad 0x30298, console 0x3005a) before its output was trusted.
- The probe process is not DPI-aware: all its coordinates are 150%-scaled DIPs.
- `qtest resize query` as a map-state oracle was cross-checked: its winner (5120x1384)
  matches a window the fullshot proves visible.
