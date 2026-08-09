# Handover — 2026-08-09 (evening). Read this before touching anything.

## The result: the fork is SLOWER than what it forked

First single-variable ours-vs-stock measurement in this project's history. ONE guest
(`win11-idd-test`), our agent swapped in and out IN PLACE, hash-verified every rep,
5 rounds interleaved, classic Notepad both sides, DDA serving **99.4%** of captures
(ddacap=2293, pwcap=13, zero refusals — the feature worked exactly as designed).

| metric | stock 4.2.2 | ours (DDA on) | delta | verdict |
|---|---|---|---|---|
| typing | **2.188** | **4.381** | **+100%** | **REAL — distributions do not overlap** |
| drag | 12.314 | 11.727 | −4.8% | inside noise (spread 34.6%) — NO verdict |
| scroll | 4.369 | 5.158 | +18% | inside noise (spread 42.5%) — NO verdict |

    typing stock [1.400 1.867 2.188 2.333 2.651]   ours [3.042 3.756 5.007 5.795]

Typing is the robust result: **every** ours rep is worse than **every** stock rep. Drag and
scroll prove nothing either way — do not quote the harness's "BEATS STOCK" tag on drag.
(n=4 on ours: `ours-ro3`'s CPU sampler produced no samples, correctly emitted as `na`.)

**RETRACTED: "DDA is a large win, typing −67%."** That compared our binary against ITSELF with
DDA off. Lined up honestly:

    ours, DDA off   12.427   (5.7x WORSE than stock)
    ours, DDA on     4.381   (2.0x worse than stock)
    stock 4.2.2      2.188

DDA removes most of an overhead **the fork itself introduced**. It does not beat what it forked.
**This build must not ship as a performance fix.** Full analysis in FINDINGS.md
("THE STOCK COMPARISON, AT LAST").

## Next task: find where the fork spends 2x on typing — by READING, not benchmarking

The instrumentation confound is already closed, so do not re-measure it: perf logging writes a
line every frame (`g_PerfEveryN = 1`) but costs **228 µs/frame** out of 2200 µs total per-frame
processing — ~10%, a fraction of a CPU point. It is NOT the 2.2-point gap.

Mean µs/frame over 3774 measured frames (`acq` ≈ 50 ms is blocking in `AcquireNextFrame`
waiting for the next frame, not CPU):

    upd 1157   wak 596   enu 477   dmg 369   log 228   snd 91   rem 28   (tot 2200)

The fork is **143 commits, +8543/−237 lines** in `agent/gui-agent` vs `upstream/main`, including
new `wincapture.cpp` (442 lines) and `workarea.c` (543 lines). Stock streams the whole desktop
framebuffer; our build added per-window capture on top. That, not instrumentation, is the
likely source.

**Method:** diff the fork's frame path against upstream's for the TYPING case specifically —
one window, small dirty rects, no movement, no occlusion — and find what runs per frame that
did not run before. `enu` at 477 µs/frame is a concrete suspect and is the `EnumWindows`-per-frame
item Track A was created to kill (`main.c` ~"use window hooks").

**Acceptance:** a named cost with evidence and a proposed fix. Not "it is probably X". If a
measurement is needed to confirm, the swap loop makes it ~10 min per rep — but read first.

## Rig state — all of this WORKS now and did not this morning

- **`win11-idd-test`** — rebuilt today: genuine stock QWT 4.2.2 (MSI byte-identical to
  `vendor/qwt-4.2.2`), OFFLINE, Store Notepad removed (classic `notepad.exe` is the typing
  target), `EnableLUA=0` so the account gets a High-integrity token. **Do not reinstall it**;
  if you must, `scratchpad/provision-swappable-stock.sh` does the whole thing in ~25 min.
- **The elevated agent swap WORKS on Win11** — this is what unblocked everything.
  `guest/run-elevated.ps1 -Script <INC>\swap-in.ps1` (and `swap-restore.ps1`). ~40 s per swap,
  verified both directions by hash. It replaces the 45-minute reinstall per iteration.
- **Policy**: `/etc/qubes/policy.d/10-win-idd-all.policy`, source in `mgmt/10-win-idd-all.policy`.
  Numbered `10-` on purpose: qrexec stops at FIRST match, so it wins over anything else. The
  user deleted the six older files. The installed copy is the **152-rule** version; the repo
  file is now **215 rules** (adds `admin.vm.tag.*` on `@anyvm` and a `@tag:qwt-bench` scope).
  Re-copy only if tagging a qube that carries neither of our tags ever fails.
- **Benchmark**: `scratchpad/stock-remeasure-1guest.sh`. Honours `SETTLE` and `ROUNDS` env vars.
  Results under `$S/bm-1guest`. It gates on `ddacap` and aborts a rep whose binary hash is wrong.

## Traps that cost hours TODAY — each had a WRONG explanation in circulation

1. **A guest that restarts ~3 s after every `qvm-kill` is QUEUED QREXEC, not a script and not a
   zombie.** A qrexec call to a Halted qube auto-starts it; if the guest's agent is dead the call
   hangs for the whole `qrexec_timeout` (**6000 s** on these guests) holding 8 GB. Queued calls
   OUTLIVE the shell that made them, so process hunts find nothing. Drain:
   `qvm-prefs <vm> qrexec_timeout 15` then `qvm-kill`. **Never `sudo xl destroy`** — native tools
   were never the problem. (`win11-fresh` is deliberately left at 15.)
2. **`run-elevated.ps1 -Arguments "-NewAgent '<path>'"` is broken through `qtest ps`** — nested
   quotes collapse and the PATH binds to `-TimeoutSec`. It reads exactly like an elevation
   failure. Use the argument-free wrappers `guest/swap-in.ps1` / `guest/swap-restore.ps1`.
   This one failure was diagnosed and then re-introduced hours later by not wiring the fix in.
3. **`usb-provision.sh` netvm**: `${4:-core-net}` treated an explicit `''` as unset, so an
   "offline" provision came up NETWORKED. Fixed to `${4-core-net}`. Read the provisioner's echoed
   configuration; do not assume the argument you passed is the value it used.
4. **Only ONE Windows guest may run.** Three at 8 GB starved the host: qubesd started failing with
   an empty "Service call error" and `qvm-ls` blocked >120 s. That looks like a policy problem and
   is not.
5. **Always set `QTEST_VM` explicitly.** A bare `tools/qtest` targets `win-idd-test` and STARTS it.
6. **`admin.vm.Create.StandaloneVM`, not `.standalone`.** The lowercase form matches nothing, which
   is why VM creation was silently ungranted for weeks. Fixed in `dom0/06-install-mgmt-policy.sh`.

## Do NOT

- Do not re-run the stock comparison — it is done, recorded, and cost a rebuild to get.
- Do not measure the `PerfLog` confound — answered above from data already collected.
- Do not present this build as a performance improvement anywhere.
- Do not submit anything upstream (standing freeze; only the two gui-daemon bugs qualify, and
  only with the user approving exact text).

## Where the rest lives

- `FINDINGS.md` — the stock result, the qrexec-queue mechanism, the netvm bug, all retractions.
- Roadmap and the win11-only-split answer (**no — keep one universal tree**, with reasons) are in
  this session's plan output; the short version is that the split buys nothing because there is no
  Win10 tax in the code and the Win11 gap is version-agnostic.
- `win11-fresh` is expendable and has no working guest qrexec. `win11-clonetest` is a crash-state
  clone and should be removed; both are on the roster so their NAMES should be reused, never new ones.
