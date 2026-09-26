# Per-window capture: the DWM-thumbnail relay

## Applies to Windows 11 build 26100 and later. Nothing here applies to Windows 10.

Stated first, deliberately. The relay is built on Windows.Graphics.Capture, which cannot be activated
from SYSTEM (`0x8007000E`) and therefore runs in a user-session broker; on 19045 the capture border
cannot be removed and `DirtyRegions` is absent, so a per-window path does not exist there at all.

The previous "de-slice release" (4.3.18) was named as though it were global while it covered ONE
window class on >= 26100 only. This note does not repeat that: every class below carries its own
verdict, and the residues are named rather than omitted.

The capability latches ONCE at broker start from `RtlGetVersion` — not `VerifyVersionInfoW`, which the
compatibility shim makes under-report — and publishes what it latched: `relayCapable` and
`relayOsBuild` are readable in the broker's shared section, so "did it engage" is answerable without a
rebuild. A silent off was a real failure once and is now visible.

## What changed

Windows that WGC cannot capture used to fall to a polled `PrintWindow` path: a pull API rendered
synchronously on the captured application's own UI thread, measured at p50 31–49 ms per render. Those
windows now get a DWM thumbnail of themselves relayed into a destination the broker owns and captures
— arrival-driven, like any other WGC channel. The polled path remains only as the last rung of the
ladder (WGC → RELAY → PrintWindow); these classes no longer live there.

A second change was needed to make it stick. The demotion rule that moves a channel down the ladder
read "damage was signalled and no frame followed" as a dead feed. The agent derives damage from
**desktop** dirty rects, so that fires whenever anything repaints inside a window's screen rectangle —
a passing cursor, an overlapping window — whether or not the window's own content moved. A healthy
relay on a **static** window satisfied it continuously and was demoted for ever (measured: PokeSeq
11,772 against FramesArrived 56). Demotion now requires an unbroken run of three measured source
changes with no frame in between, where a change is established by rendering the source and comparing
it, not by a poke.

## The four classes, each with its own verdict

Measured on a German Windows 11 25H2 guest (26200.8037), release build `44092a8`, installed binary
hashes verified against the release medium before every measurement.

| class | detected by | route | delivered pixels |
|---|---|---|---|
| override-redirect | `IsPopup`; confirmed as `ovr=1` in the agent's own protocol trace | RELAY, 3/3 censuses | **MAD 1.5 / 255** |
| `WS_EX_NOREDIRECTIONBITMAP` | style | RELAY, 3/3 | **MAD 0.0 / 255** |
| ULW-layered (per-pixel alpha) | `GetLayeredWindowAttributes` fails | RELAY, 3/3 | **MAD 1.5 / 255** |
| `LWA_COLORKEY` | layered attributes report a colour key | RELAY, 3/3 | **MAD 0.0 / 255** |

Windows Terminal, which is `WS_EX_NOREDIRECTIONBITMAP` in practice, also measured MAD 0.0.
**Zero slots remained on the polled fallback in any census.** Routes passed seven census sets of three
across two builds, including one taken after a **cold boot** with the agent restart skipped, so the
graded agent was the instance the boot produced rather than one restarted under it.

"Delivered pixels" means: the broker publishes a 32×32 grid of per-tile mean RGB for the frame it
ACTUALLY delivered, the guest computes the same reduction of the window's own composited render, and
the two are compared over the central 24×24 (576 tiles) as a mean absolute difference. Both sides
normalise to the same grid because the guest measures the whole window while the broker publishes the
content it was handed — they differ by the window frame. The limit is 12/255, set by driving the
check: a blank delivered frame scores 104, a channel swap 44, a six-tile shift 20; a one-tile frame
offset scores 2.7.

**Liveness was tested separately**, because no static comparison can distinguish a live frame from a
stale one: the per-pixel-alpha window's content was changed on purpose and the delivered frame both
moved (20.6) and matched the source's new content (1.4).

## Residues, named

- **Transient surfaces are not gradeable by this instrument.** A toast is a live, changing surface —
  its own colour count moved 28 → 36 between two censuses — so the guest and the broker necessarily
  sample it at different instants. Its frames are delivered (it sits on an arrival-driven route and
  the broker publishes for it), but the fidelity comparison for it is not meaningful and is recorded
  as open rather than claimed.
- **Per-pixel alpha is not carried by the protocol.** Two classes measured pixels that are not fully
  pre-blended: Windows Terminal at `alphaMin=102, partial=193/8680`, and the COLORKEY fixture at
  `alphaMin=102, partial=64/1014`. Everything else measured a uniform 255. Those pixels reach dom0
  composited against whatever the relay destination held. This is a protocol limitation, not something
  introduced here, and it is why those two classes are called out by name.
- **The comparison is per-tile mean RGB, not per-pixel identity**, and alpha is excluded from it by
  design, since the two sides need not agree on a channel the protocol does not carry.
- Measured on one guest, one build, German, 4 vCPUs.
