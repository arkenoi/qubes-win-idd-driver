# console — findings

## CURRENT STATE

AUTHORITATIVE — and the ONLY content of this file. The dated history log was amputated
2026-09-01 (owner call): the chronological format itself caused stale-first reads and
contaminated sessions. Maintain by editing bullets IN PLACE (add, correct, delete);
never append dated sections (the pre-commit hook refuses them). Every bullet carries
`[verified <date>]` or `UNVERIFIED`. Git history retains the old log for deliberate
forensics only — do not load it into context.

- Sections dated 2026-08-30/31 were ERASED on 2026-09-01 (owner call: those sessions were contaminated and their output is void). Do not cite them and do not reconstruct them from git history. Claims RETRACTED in that window STAY retracted; claims MADE in that window are void — re-verify live before relying on anything that traces there. [verified 2026-09-01]
- We SHIP `xencons` since 4.3.16. `XENBUS\VEN_XP0001&DEV_CONS` binds (cm=0) and the guest runs an interactive `cmd.exe` on the PV console ring. [verified 2026-09-01]
- `qvm-console <vm>` == `sudo xl console -t pv <vm>`. Plain `xl console <vm>` can NEVER work on a Qubes HVM: no `<serial>` in the libvirt XML, so the stubdom has no console 3 (qubes-issues #3039). [verified 2026-09-01]
- `Unable to attach console` means execv failed, not "no tty" - `/usr/libexec/xen/bin/xenconsole` is mode 0700 root, so use sudo. [verified 2026-09-01]
- Stock Qubes DENIES `admin.vm.Console` to everyone including dom0; the shipped policy file is comments only. Grant added to dom0/12-install-policy-tagged.sh. [verified 2026-09-01]
- The guest CAN WRITE the ring - `guest/console-write.ps1`, a second handle on the xencons device. Lines land in dom0's `guest-<vm>.log` continuously with no qrexec, no session and no attached reader. [verified 2026-09-01]
- An emulated serial needs NO dom0 change (`qvm-features <vm> qemu-extra-args '-serial file:/dev/hvc0'` -> COM1 appears). Output-only; interactive SAC is unreachable on Qubes because a Qubes patch drops the dom0 qemu that serves stubdom consoles. [verified 2026-09-01]
- Traps: ONE attacher at a time (a concurrent `xl console` makes a probe read empty), and it needs a LOGIN per boot. [verified 2026-09-01]
- It will NOT rescue the wedge: no bugcheck occurs and nothing is schedulable to emit. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

## The experiment

Control = `6b5b298` reverted on top of `a4f6961` (`768CA58C`), i.e. a **single variable** — unlike
`98eed30`, which also lacks four other fixes. Test = `F06C0979`. `PerWindowCapture` on (its
default). Scene: a console window scrolling text forever, so its per-window channel produces
continuous damage — a static window emits none even when perfectly healthy, which would have made
"no damage" unreadable. Trigger: `CreateDesktop` + `SwitchDesktop` away for 8 s (more than the
five capture attempts needed to trip `DEAD_AFTER_FAILURES`) and back.

| build | damage before | damage after | channel |
|---|---|---|---|
| guard REVERTED `768CA58C` | 136 / 12 s | **83 / 12 s** | alive |
| guard PRESENT `F06C0979` | 176 / 12 s | **118 / 12 s** | alive |

**Identical behaviour.** The hypothesised harm — `AttachThreadToInputDesktop()` following onto a
non-`Default` desktop, captures failing five times, `DEAD_AFTER_FAILURES` marking the channel
dead forever — **did not occur without the guard**.

Combined with the rest of the case against it, that is enough to revert:
- its stated justification (guest stuck at "Welcome", PrintWindow stalling LogonUI from SYSTEM)
  was **already retracted** — FINDINGS 2026-08-03 shows that hang was Windows Update;
- it logs **nothing** on either edge of its idle branch, so in production it can never be shown
  to have acted — unfalsifiable by construction, which CLAUDE.md's instrument rule forbids.

Reverted in agent `8629a9c`.
