# Goal status — measured, with evidence

All numbers from win-idd-test (Win10 Enterprise LTSC 2021 19044.1288, 4 vCPU, seamless),
same rig and same workload before and after. Raw logs are committed next to each claim.

## (a) Phase 2A landed, drag median < 5 ms — **MET**

`tools/bench-agent.sh`, phase-sliced (`instrumentation/PHASE-SPLIT.md`,
`instrumentation/bench-before.txt`, `instrumentation/bench-after.txt`):

| phase | before | after | factor |
|---|---|---|---|
| **drag median** | **44.9 ms** | **1.33 ms** | **34x** |
| drag p95 | 102.9 ms | 8.1 ms | 13x |
| scroll median | 18.7 ms | 0.13 ms | 140x |
| type median | 17.9 ms | 0.14 ms | 128x |
| windows interrogated / frame | ~67 | 1.44 (drag) | — |

Threshold was < 5 ms; measured 1.33 ms. Root cause was never "EnumWindows is slow": rejected
windows were re-interrogated every frame (cross-process `GetWindowText` + a DWM RPC each),
67 of the guest's 68 top-level windows, forever. See `instrumentation/PHASE1A-RESULT.md`.

**Upstreamable:** yes. The tearing artifact found during testing is NOT a Phase 2A
regression — the identical test on the stock shipped agent reproduces it (screenshots for
both committed, `instrumentation/ARTIFACT-TEARING.md`). It is a separate pre-existing QWT
defect, tracked, not shipped as ours.

## (b) ACCESS_LOST recovers in place, no window unmapping — **MET**

`instrumentation/ACCESS-LOST-VERIFIED.md`. Forced desktop switch:

| | before fix | after fix |
|---|---|---|
| window unmaps | **6** | **0** |
| frames captured after the error | — | **11** |
| agent / mapped window alive | teardown | both alive |

Two iterations were needed and both were found by measuring: the failure actually arrives
from `ReleaseFrame` (not `AcquireNextFrame`), then from a third site `GetFrameDirtyRects`.

## (c) Office synthetic-window fix verified via chromerepro — **MET**

`instrumentation/PHASE2A-CHROME-RESULT.md`:

| agent | windows mapped to dom0 |
|---|---|
| shipped QWT 4.2.2 | **5** (main + 4 shadow strips) |
| with the 2A-chrome fix | **1** (main only) |

Measured by `SendWindowMap` in the agent log. Counting screenshot PNGs — the original
criterion — is invalid: `import -window` silently fails on layered/transparent windows and
reported 1 PNG while 5 windows were mapped, i.e. a false PASS before the fix existed.

**Caveat, stated deliberately:** chromerepro's strips are oversized because
`ShouldAcceptWindow` has always dropped windows below ~136x39. Whether REAL Office strips
clear that threshold is UNVERIFIED, so coverage of real Office is not yet claimed — it needs
a `dump-windows` capture in the user's Office qube.

## (d) reviewed diff ready for the upstream PR — **PREPARED, awaiting approval**

`upstream/0001-access-lost-recover-in-place.patch` (+104 / -4, one file) against PRISTINE
upstream `capture.c`, with no dependency on our instrumentation or the tracking rework;
every symbol it uses already exists upstream. PR text with before/after evidence in
`upstream/PR-access-lost.md`. NOT submitted — CLAUDE.md requires explicit approval of the
exact diff and text before any upstream contact.

## (e) full QWT package built by CI, drop-in installable — **MET**

CI artifact `qwt-improved-package`, verified end-to-end on the live guest:

| check | result |
|---|---|
| installs on stock QWT 4.2.2 | ✅ agent replaced, `.orig` kept |
| service + agent after install | ✅ Running / alive |
| our build actually active | ✅ `QGAPERF on` in the agent log |
| seamless still renders | ✅ 2 live windows captured |
| `-Restore` | ✅ shipped binary back byte-for-byte (80968 B) |
| idempotent | ✅ second run: "Nothing to do" |
| provenance | ✅ `4.2.2+agent.580328e1b8b0`, `mm_431e4517-6-g580328e` |

**Scope, stated honestly:** this is an overlay updater — it replaces the GUI agent only.
Patching the upstream MSI would break ITL's Authenticode signature, and rebuilding all of
QWT needs the WDK/EWDK for the KMDF PV drivers we deliberately avoid
(`ci-notes/packaging.md`, `ci-notes/trackA-build.md`).

## Known open items (not part of this goal)
- Pre-existing framebuffer tearing in shipped QWT (persistent, does not self-heal).
- Phase 2B-resize: the geometry-changed recovery path is deliberately a full reinit and has
  not been exercised.
- Real-Office validation of the chrome fix.
