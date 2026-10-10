# BUG: a live Windows guest shows no windows in dom0

## CURRENT STATE

**OPEN, P1. This machine holds NO measured occurrence of the defect** — only source reading and
self-authored notes (Jev `occurrence_measured` = `no-only-source-reading`, **conf 1.00**, 2026-10-10;
wire: `scratchpad/jev-wire.jsonl`). Onset unknown. Whether it is a regression is unknown.

Every claim was put to Jev on its own. Three passed; they are the only facts here.

- **F1 [verified 2026-10-10] Jev 0.88 — our agent has a code path that reports the daemon gone for good.**
  `agent/gui-agent/main.c:13328` logs `dom0's gui-daemon for this qube is gone and is not coming back on
  its own`, reached only when `!g_VchanClientConnected` has held for `VCHAN_FIRST_CLIENT_WAIT_MS` across
  `VCHAN_FIRST_CLIENT_MAX_RESTARTS` respawns with `REG_CONFIG_HAD_CLIENT_VALUE` set.
  `agent/include/common.h:68-69`: **90000 ms** and **3**.
- **F2 [verified 2026-10-10] Jev 0.79 — our agent deliberately drops some windows, and dom0 then shows
  nothing, correctly.** A DWM-cloaked window is folded into `IsVisible` and dropped
  (`agent/gui-agent/main.c:1888`, `:8213`). `SanitizeWireGeometry` refuses any window whose width or
  height is not positive, sends nothing, and logs `GEOMDROP` (`agent/gui-agent/send.c:118-124`).
- **F3 [verified 2026-10-10] source read — the harness cannot tell this defect from its own blind
  spots.** Its guest-side window probe is `Get-Process notepad | Where-Object { $_.MainWindowHandle -ne
  0 }` (`mgmt/harness/matrix.sh:1639`): no window class, no cloak state, no geometry, no hung state. The
  harness grades "guest window present + empty dom0 capture" as **`INVALID-INSTRUMENT … not a product
  verdict`** (`:1643`), and `:1627-1636` records a false positive of the empty-capture reading as the
  reason that probe exists at all.

## NOT established

- **When the defect first appeared — no date, no commit** [verified 2026-10-10]. Earliest material is
  `DESIGN-gui-daemon-restart-survival.md` (2026-08-04), about incidents whose logs are not in this repo.
- **That a guest ever emitted the F1 line** [verified 2026-10-10] Jev **0.03**. No raw gui-agent log on
  this machine contains it; all 7 matches are files the assistant wrote (its own Jev state, wire log,
  grep script, notes).
- **The 2026-10-10 six-empty-captures reading** [verified 2026-10-10] Jev **0.05**. The harness code is
  receipted; the occurrence is not. It was never a reproduction.
- **The 2026-09-11 campaign false positive** [verified 2026-10-10] Jev **0.16**. The source comment is a
  receipt that this project *recorded* it, not that the campaign facts were verified.
- **Whether that notepad window was real, a ghost, cloaked or zero-sized** [verified 2026-10-10]. The F3
  probe reads none of those. `IsHungAppWindow` exists in the agent (`workarea.c:131`), unused by it.
- **Everything in `DESIGN-gui-daemon-restart-survival.md`** [verified 2026-10-10] — guid's two EOF paths,
  `handle_vchan_error` skipping `vchan_at_eof`, the class (i)/(ii) split, "the daemon dies first", the
  discriminator strings. Read from an upstream clone never version-matched to dom0's installed daemon.
  Mechanism reference only. Its `E1`/`E2`/`E3`/`E9` numbers are internal to it; `findings/wedge.md`'s
  E-series is unrelated (install stalls).
- **The agent-restart line is CLOSED** [verified 2026-10-10] — owner: *"guest daemon restart NEVER was
  the cure, stop chasing this path at all"*. §2/§3 of that doc, including its G0, are retired. Do not
  propose a restart, a reconnect, or a survival strategy for one.

## Conditions observed on

Three readings exist. **Only the first was measured**; the other two are listed so nobody mistakes them
for observations.

| | guest | VM class | Windows | our build | trigger | standing |
|---|---|---|---|---|---|---|
| 2026-10-09 | `win11-acc` | **StandaloneVM**, `virt_mode=hvm`, `netvm=None`, `os=Windows`, `gui=1` | Win11, exact build pending | not recorded per-observation | **agent service restart** (one variable, same guest, same window, same probe) | MEASURED |
| 2026-10-10 | `WIN10-appvm` cell | **AppVM**, created by the cell | Win10 | the release package under test | plain boot (boot 3) | NOT established, Jev 0.05 |
| 2026-10-07 | `win11r-gz` | guest no longer exists on the rig | Win11 retail lineage | — | — | NOT established, Jev 0.03 |

What the measured row consists of (`findings/issues.md` GUIDNORECONNECT, verified 2026-10-09): notepad
running guest-side with `hwnd=459290 visible=True`, the agent parked on `Awaiting for a vchan client`
with no `A vchan client has connected` after its last init record, and the dom0 per-window capture
returning **0** PNGs. After a guest reboot: `A vchan client has connected` 0.32 s later, capture **1**
PNG. Note `visible=True` — that probe read visibility, which the F3 probe does not; it still did not read
class, cloak state, rect or hung state.

Two cautions on that row, both from the owner. He **closed** it on 2026-10-09 as dom0-side, and on
2026-10-10 closed the agent-restart path entirely. So it is the only measured instance of the symptom,
and its trigger is not a path to work on.

**Our build version is not recorded against any of the three.** This session's work was on **4.3.36**
(unreleased); the last release is **v4.3.35-agentf613dc3**. Which package was installed on `win11-acc`
when the 10-09 reading was taken is not established — and per this project's own evidence rule, the
running binary's hash against the manifest is what "our build" means, not a release tag.

## Reproduction sequence

**Not known to be deterministic** — this is the sequence the condition was seen in, not a recipe known
to fire. One guest at a time.

1. Start a Windows AppVM with our QWT; let it reach the desktop.
2. Open an app window. **Confirm dom0 shows it.** Required, not a sanity check: F1 only reports "daemon
   gone" on a guest that has had a daemon client before.
3. Reboot the guest normally; let it reach the desktop again.
4. Open an app window again.
5. Look at dom0. The defect: no window appears, the guest stays alive (qrexec answers), and nothing
   short of shutting the qube down and starting it again brings the GUI back.
6. **Do not reboot, do not kill, do not restart the agent** until everything below is collected. A
   restart loses the only generation of evidence there is.

## Evidence to look for

Agent log, `Q:\Qubes Logs`, read as SYSTEM. Prefix `[YYYYMMDD.HHMMSS.mmm-PID:TID-LEVEL]`; three
different PIDs in one boot are the agent's three deliberate respawns, not a crash loop.

| look for | what it tells you |
|---|---|
| `GEOMDROP` | **check first.** If present, we refused to send that window ourselves (F2) and dom0 is correctly empty. Flips the diagnosis |
| `A vchan client has connected` | whether a daemon connected this boot, and when. Absent = never arrived; present = arrived, then went away |
| `dom0's gui-daemon for this qube is gone and is not coming back on its own` | F1: 90 s with no client, three times, on a guest that had had one |
| `Awaiting for a vchan client` | the parked state |

About the window itself, for the exact hwnd. None of it is collected today, and without it the guest
side proves nothing (F3):

| read | why |
|---|---|
| window **class** | a `Ghost` class means the app hung and Windows substituted a stand-in — no real window to show, no display bug |
| `DWMWA_CLOAKED`, `IsWindowVisible` | a cloaked window is one we drop on purpose |
| the window **rect** | zero or negative width/height is one we refuse on purpose |
| `IsHungAppWindow` | whether the app pumps messages at all |

Two read-only dom0 facts separate "daemon gone" from "daemon stuck", for whoever has dom0 access, taken
before the recovery restart: whether a `qubes-guid` process exists for that domain, and whether
`/run/qubes/guid-running.<domid>` exists.

## To measure first

1. **Capture one raw occurrence** — pull the agent log off a failing guest and keep it. Nothing can be
   dated or attributed until such an artefact exists here.
2. **Fix the F3 probe before any run grades this again** — the four window reads above, for the specific
   hwnd. Until then an empty-capture result is uninterpretable, which is what the harness already says.
