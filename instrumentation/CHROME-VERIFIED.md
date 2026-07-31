# Office synthetic-window fix - verified

Method: full-desktop dom0 capture (`local.WinFullScreen`), which lists override-redirect
windows the per-window service cannot see. Binary hash verified against the manifest before
every run; 3 runs per side, interleaved.

| | dom0 windows | shadow strips in dom0 | Notepad content |
|---|---|---|---|
| stock QWT 4.2.2 (`3D2E6BCE`) | 8, 8, 8 | **4, 4, 4** | 25872 x3 |
| ours (`f4695698af33`) | 4, 4, 4 | **0, 0, 0** | 25872 x3 |

chromerepro creates 1 real window plus 4 layered/transparent/toolwindow shadow strips. On stock
all four reach dom0 and render as solid rectangles around the real window. With ours none do,
and the real window is unaffected. Content measure identical on both sides, so the fix removes
the chrome without costing rendering.

Prerequisites that had to be fixed before this number meant anything:
* the scene now settles (forced repaint + drain) - without it the content metric swung the full
  range on ONE unchanged binary, which voided an entire bisect;
* the harness verifies the running binary's hash - it previously proceeded on a failed install
  and reported results for a build that was never running;
* helper scripts are pushed every run rather than relied on from an earlier manual push.
