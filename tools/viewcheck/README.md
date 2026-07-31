# viewcheck — detect GUI-agent rendering defects WITHOUT a human looking

Compares **what Windows actually rendered** (captured inside the guest with
`Graphics.CopyFromScreen`) against **what dom0 received** (`local.WinScreenshot`). Any
difference is an agent/daemon defect, and the classifier says which kind:

| verdict | meaning |
|---|---|
| `OK` | dom0 matches the guest |
| `BLANK-IN-DOM0` | dom0 image is flat — damage was never sent (the blank-menu bug) |
| `STALE-BAND` | contiguous rows differ — stale scanlines (the tearing bug) |
| `CONTENT-DIFFERS` | wrong content — e.g. the composited-overlap artifact |
| `NOT-IN-DOM0` | never mapped, or `import` failed on it (layered/override-redirect windows) |

## Use
```
tools/viewcheck/bothshot.sh <tag>          # capture both sides
tools/qtest pushrun tools/viewcheck/enumwin.ps1   # window rects -> windows.json
python3 tools/compare-views.py <tag>-guest.png <tag>-dom0/ windows.json
```

## Why this exists
Four rendering bugs in this project were found by the user driving the VM by hand, not by
the performance numbers — which looked excellent throughout. Two of them I had made *worse*
without noticing. A metric that cannot see a blank menu is not a good enough gate.

## Caveats — read before trusting a verdict
1. **The two captures are seconds apart**, not simultaneous. Anything genuinely animating
   (a blinking caret, a clock) will show as a difference. Compare on a quiet desktop, and
   treat a single small band with suspicion before treating it as a bug.
2. **Sizes do not match exactly.** The guest `GetWindowRect` includes the invisible resize
   border; the agent reports DWM extended frame bounds (2580x1029 vs 2566x1022). The matcher
   allows 24 px and centre-crops, which is why it must not be tightened blindly.
3. **`import -window` silently fails** on layered / override-redirect windows, so menus and
   shadow strips come back as `NOT-IN-DOM0` rather than as an image. That is a limitation of
   the dom0 screenshot service, not evidence the agent dropped them — check `SendWindowMap`
   in the agent log to tell the two apart.
