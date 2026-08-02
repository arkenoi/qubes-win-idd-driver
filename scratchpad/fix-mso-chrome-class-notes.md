# fix-mso-chrome-class — reject MSO_BORDEREFFECT_WINDOW_CLASS in the acceptance predicate

Branch `fix-mso-chrome-class`, commit `c789199`, based on `b299011`. Worked in a clone
(`.../scratchpad/mso-fix`), pushed back to the local clone source
(`/home/user/qubes-win-idd-driver/agent`). No remote/github push, no force-push, source
working tree untouched (still on `perwindow`, clean).

Author identity: a fresh clone has no user.name/user.email, so `git commit` refused. No
identity was invented or persisted — the commit was made with a one-shot
`git -c user.name=... -c user.email=...` reading the values already configured in
`/home/user/qubes-win-idd-driver/agent` (arkenoi), i.e. the same author every sibling fix
branch there carries.

## Change (2 hunks, gui-agent/main.c only)

1. `#define MSO_BORDER_EFFECT_CLASS L"MSO_BORDEREFFECT_WINDOW_CLASS"` next to the existing
   `UAC_DUMMY_WINDOW_CLASS` define (main.c:141-145) — same placement/comment style.
2. Rule 3 in the 2A-chrome section of `ShouldAcceptWindow()`, after the existing rule 2
   style heuristic and before the DWM-cloaked note:
   `if (0 == wcscmp(data->Class, MSO_BORDER_EFFECT_CLASS)) { LogVerbose(...); return FALSE; }`

Style/marshalling matches the precedent in this tree: the class name is captured once in
`GetWindowData()` via `GetClassName(window, entry->Class, ARRAYSIZE(entry->Class))`
(main.c:889) into `WCHAR Class[256]` (main.h:49); every existing class test uses
case-SENSITIVE `wcscmp` on that cached copy (main.c:920, 1591, 1994). No new
cross-process call is added on the hot path. `LogVerbose` (not `LogDebug`) for the same
reason rule 2 gives: the strips move with the window they decorate, so their reject-cache
signature changes at input rate during a drag.

## Rejection blocks synthesis, not just announcement (verified paths)

- New windows: `ExamineWindow()` calls `ShouldAcceptWindow(data)` at **main.c:1585** and
  returns after `CacheRejectedWindow()` — `AddWindow()` at **main.c:1601** is never reached.
- `AddWindow()` is the **only** `InsertTailList(&g_WatchedWindowsList, ...)` in the whole
  agent (**main.c:1208**) and the **only** caller of `SynthActivate()` (**main.c:1216**,
  guarded by `SynthQualifies`). So a window that never reaches AddWindow is never tracked,
  never synthesized, never `SendWindowCreate`d (main.c:1245) — and having no synthesis, it
  has nothing to materialize from (the materialization paths at main.c:2153 and main.c:2381
  only walk list entries / SynthChildren).
- Only other `AddWindow()` caller is the taskbar re-show path (**main.c:1756**), which
  bypasses the predicate but is hard-wired to `g_TaskbarWindow` (Shell_TrayWnd) — cannot be
  an MSO strip.
- Defence in depth for an entry that somehow is already tracked and synthesized:
  `UpdateWindowData()` re-runs `ShouldAcceptWindow()` at **main.c:2145** and sets
  `DeletePending` (silent removal) *before* the `SynthQualifies` materialization check at
  **main.c:2153**, and again at **main.c:2408**. So even that ordering favours silent drop
  over materialize. (Line numbers post-patch.)

## Untouched, as instructed

`wincapture.*`, `SynthFlushMasks`/`SynthUpdateMask`, `SynthActivate`'s body — no edits;
branches fix-mask-sort-v2 / fix-joint-maskpush-v2 / fix-office-chrome-v2 own those.

## Honest limits

- Not built (no toolchain here); every hunk re-read by hand. `/W4`-safe: no new variables,
  no signed/unsigned mix, format args (`%x` HWND, `%u` DWORD) match existing LogVerbose
  calls in the same function.
- Not validated against a live reproduction: per FINDINGS 2026-08-02 the daemon-kill could
  not be triggered on demand (move, resize and a scripted outside-click all gave
  MATERIALIZING 0 / VCHANDISC 0). This removes the precondition; it does not prove the
  daemon-kill is fixed.
- Class-name matching is an app-behaviour bet: if Office renames the class, the strips come
  back as bordered fragments (cosmetic regression, not a crash). Rule 2 and the containment
  / CreateSent work on the other branches remain necessary for non-Office cases.
- False-positive risk is essentially nil: the class is Office-private and the strips are
  click-through decoration, so no interactive UI can be hidden by this.
