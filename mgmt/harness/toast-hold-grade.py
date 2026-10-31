#!/usr/bin/env python3
"""toast-hold-grade.py - the GRADER (and the fire/pull recorder) for mgmt/harness/toast-hold-test.sh.

WHAT IT DECIDES. For every toast the harness fired, exactly ONE class, from the guest's own logs joined on the
guest's clock and on per-toast identity (docs/ADR-toasts.md 10; the owner's rule since 2026-09-13: no doubles,
nothing lost; an occasional ~3 s delay on a first toast is fine, a flash is not):

  OK-BRIDGED   the bridge delivered it to dom0 (FWD_RTT ... ok=1 / SENT ...: OK / HOLD verdict=forwarded for its
               notification id) AND the agent never mapped its banner - not even a MAP followed by an UNMAP.
  OK-WINDOW    not delivered AND the agent mapped its banner within WINDOW_BOUND_MS of first examining it.
               The bound is TH_HOLD_BOUND_MS (3000, toasthold-core.h: "no verdict within 3 s = mapped") plus one
               TH_HOLD_RECHECK_MS (500): ToastHoldSweep moves an expired deadline forward by one recheck interval
               instead of clearing it (toasthold.c, review #14), so the latest a bounded hold can release is
               3000 + 500 ms after the banner's first examination.
  LATE-WINDOW  not delivered, mapped, but later than the bound (nothing lost, the ~3 s rule broken).
  DOUBLE       delivered AND the banner was mapped at any time while this toast's content was displayed - a
               full double or a flash (mapped when the content arrived in place, unmapped afterwards).
  LOST         neither delivered nor mapped, with evidence that a banner existed (the agent examined one for this
               toast, or the harness saw the shell's banner window visible in the guest during the scenario).
  NO-BANNER    neither delivered nor mapped and NO evidence a banner ever existed: the stimulus produced no
               banner (banners off for that app, do-not-disturb, an unsuitable AUMID). Ungraded, never a PASS.
  Non-seamless (the agent publishes Seamless=0; the bridge forwards nothing): OK-WINDOW-NS when the bridge took the
  window path by mode and nothing was forwarded or mapped; FORWARDED-NS when a toast was forwarded in that mode
  (the 4.3.34/35 behaviour); MAPPED-IN-NS when a banner window was mapped while non-seamless.

MISSING DATA FAILS. No FIRED line -> the row is INSTRUMENT (a toast that never fired cannot banner - a0 lesson,
2026-09-05). No bridge record / no SENT / no skip for the toast -> UNLISTED (INSTRUMENT). No agent log coverage
(the clock probe's CREATE line absent, the log file replaced mid-run) -> the whole run is INSTRUMENT. Nothing here
ever reads as OK by default.

THE JOIN. toastfire's title is the per-toast identity: the grader computes the SAME FNV-1a-64 the two binaries
compute (TiNormalize + TiHashUnits, toastident.h - ported below and checked in --selftest against vectors produced
by compiling toastident.h with gcc) and finds the bridge's `HOLD id=N ... t=<hash>` record; the agent's
QGATOASTHOLD lines carry `id=N` (and `t=<hash>` on the hold-start / content-changed / fail-open lines), which
names the banner HWND; QGAPROTO MAP / DESTROY and the hold's own `unmapped a MAPPED banner` line for that HWND
give its mapped state over time (NOT `Unmapping window`, which is LogDebug and absent at the shipped level - see
is_unmap(); an ordinary unmap that destroys nothing is invisible at level 3, and a banner always destroys).
On a package WITHOUT the hold (the control) there are no HOLD lines: the id comes from `SENT ... title='<slug>'`
or from the `skip id=N aumid=<toastfire aumid>` lines in fire order, the banner window from the agent's
QGAHELDDEFER class=Windows.UI.Core.CoreWindow / QGAHELDMAP toast=1 / `toast card in` lines, and "mapped" means a
MAP of such a window within CONTROL_BANNER_WINDOW_S of the fire (the control's fires are spaced for that).

ONE CLOCK, AND IT IS THE GUEST'S. The bridge logs GetLocalTime (HH:MM:SS, no date); toast-hold-fire.ps1 stamps
Get-Date (local, ms). The agent log's timestamp ([YYYYMMDD.HHMMSS.mmm-pid-tid]) is tied to that clock by the
harness's CLOCK PROBE: charmap's window, whose HWND the probe knows, must produce a QGAPROTO CREATE within the
probe's own [t_start, t_seen] window; the offset between the two clocks is taken as the nearest multiple of 15
minutes (time zones), and the residual must be small. No CREATE -> ProtoTrace is off or the agent log is not the
live one -> INSTRUMENT. bridge.log's DATE comes from the capture's own instant on the guest's clock (meta.json
pull_now, else --ref-now, else the clock probe's stamps, else the last fire) - never from this process's clock,
which is in a different phase (see the comment over parse_bridge). No such instant -> CLOCK-REF INSTRUMENT.

EXPECTATIONS are keyed by (hold build, scenario label) - see EXPECT. On the hold build every row is gating and must
read OK-*. On the pre-hold CONTROL the gating rows are the ones the defect PREDICTS: S0/S1a/S4 = DOUBLE (the first
toast of a classifier-routed or allowlisted app shows twice) and S2 = LOST (the ShowBanner=0 switch hides the
interactive toast). A control run whose gating rows do not show the defect means the DETECTORS are unproven, and
that is a FAIL of the harness, never a pass of the product.

Modes:
  --record-fire --out DIR --labels L1[,L2] --mode seamless|nonseamless --attempt N   < toast-hold-fire output
  --decode-pull --out DIR PULLFILE          writes DIR/agent.log, DIR/bridge.log after verifying counts + sha256
  --grade --out DIR [--ref-now TS]          appends LABEL|TEXT rows to DIR/verdicts.txt, writes DIR/grade.json,
                                            prints the GRADED verdict line; exit 0 only when nothing failed.
                                            --ref-now '<yyyy-mm-dd HH:MM:SS[.fff]>' is the GUEST's clock at the
                                            pull, for a dir whose own `THC now=` stamp was lost
  --selftest                                synthetic fixtures for every class (each detector seen to fire AND
                                            seen to stay silent) plus the identity-hash vectors
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import sys
import tempfile
from typing import Dict, List, Optional, Tuple

HOLD_BOUND_MS = 3000
HOLD_RECHECK_MS = 500
WINDOW_BOUND_MS = HOLD_BOUND_MS + HOLD_RECHECK_MS       # 3500: the latest a bounded hold can release the banner
CONTENT_WINDOW_S = 20.0                                  # how long one banner content can be on screen (5 s banner + queueing slack)
CONTROL_BANNER_WINDOW_S = 10.0                           # pre-hold build: banner activity attributable to a fire
RECORD_SLACK_S = 5.0                                     # a record may be stamped slightly before the fire wrapper's t0 (clock grain)
CLOCK_RESIDUAL_S = 6.0                                   # charmap CREATE must land within this of the probe's window
BANNER_CLASS = "Windows.UI.Core.CoreWindow"
TOASTFIRE_AUMID_PREFIX = "QubesToastfire."
SLUG_PREFIX = "THT-"

# label -> expected class, per build kind. INFO rows are recorded, not gating.
EXPECT = {
    1: {  # the hold build (candidate): everything must be OK
        "S0": "OK-BRIDGED", "S1a": "OK-BRIDGED", "S1b": "OK-BRIDGED", "S2": "OK-WINDOW",
        "S3i-1": "OK-BRIDGED", "S3i-2": "OK-WINDOW", "S3ii-1": "OK-WINDOW", "S3ii-2": "OK-BRIDGED",
        "S3iii-1": "OK-WINDOW", "S3iii-2": "OK-WINDOW",
        "S4": "OK-BRIDGED", "S5a": "OK-WINDOW-NS", "S5c": "OK-BRIDGED",
    },
    0: {  # the pre-hold build (control): what the defect predicts; these rows are the detectors' seen-to-fail proof
        "S0": "DOUBLE", "S1a": "DOUBLE", "S2": "LOST", "S4": "OK-BRIDGED",   # S4: the pre-hold bridge pre-arms ShowBanner=0 for allowlisted apps BEFORE their first toast (measured on the control 2026-10-06)
    },
}
GATING = {1: set(EXPECT[1]), 0: {"S0", "S1a", "S2"}}
# classes the control's non-gating rows are expected-ish to show (reported for the reader, never graded)
CONTROL_INFO_HINT = {"S1b": "OK-BRIDGED", "S3i-1": "OK-BRIDGED", "S3i-2": "LOST", "S3ii-1": "OK-WINDOW",
                     "S3ii-2": "DOUBLE/OK-BRIDGED", "S5a": "FORWARDED-NS", "S5c": "OK-BRIDGED"}


# --------------------------------------------------------------------------------------------- identity (toastident.h)
def _ti_is_space(c: int) -> bool:
    return c in (0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000) \
        or 0x2000 <= c <= 0x200B


def _ti_is_dropped(c: int) -> bool:
    return c in (0x200E, 0x200F, 0xFEFF, 0xAD, 0x200C, 0x200D) or 0x202A <= c <= 0x202E or 0x2066 <= c <= 0x2069


def _ti_fold(c: int) -> int:
    if 0x41 <= c <= 0x5A:
        return c + 32
    if 0xC0 <= c <= 0xDE and c != 0xD7:
        return c + 32
    return c


def _utf16_units(s: str) -> List[int]:
    b = s.encode("utf-16-le", "surrogatepass")
    return [b[i] | (b[i + 1] << 8) for i in range(0, len(b), 2)]


def ti_normalize(s: str, cap: int = 512) -> List[int]:
    out: List[int] = []
    pending = False
    for c in _utf16_units(s or ""):
        if _ti_is_dropped(c):
            continue
        if _ti_is_space(c):
            pending = len(out) > 0
            continue
        if pending:
            if len(out) < cap:
                out.append(0x20)
            pending = False
        if len(out) < cap:
            out.append(_ti_fold(c))
        if len(out) >= cap:
            break
    return out


def _fnv_units(h: int, units: List[int]) -> int:
    for u in units:
        h ^= u & 0xFF
        h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        h ^= u >> 8
        h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h


def ti_hash_units(units: List[int]) -> int:
    if not units:
        return 0
    h = _fnv_units(1469598103934665603, units)
    return h if h else 1


def ti_ident(sender: str, title: str, message: str) -> Dict[str, int]:
    s, t, m = ti_normalize(sender), ti_normalize(title), ti_normalize(message)
    out = {"s": ti_hash_units(s), "t": ti_hash_units(t), "m": ti_hash_units(m),
           "p": ti_hash_units(m[:24])}
    if not s and not t and not m:
        out["c"] = 0
        return out
    h = 1469598103934665603
    h = _fnv_units(h, s)
    h ^= 0x1F; h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    h = _fnv_units(h, t)
    h ^= 0x1F; h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    h = _fnv_units(h, m)
    out["c"] = h if h else 1
    return out


def title_hash_hex(title: str) -> str:
    return "%016x" % ti_hash_units(ti_normalize(title))


# gcc-compiled toastident.h, 2026-10-06 (scratchpad tivec.c): the vectors the port must reproduce exactly.
HASH_VECTORS = [
    ("toastfire-QubesToastfire.StartShortcut", "THT-s1a-ab12cd", "demo body",
     "7cf10a74d413e3c8", "f3e1b9fae7a1eb87", "2bd57346cf758e00", "c9135f03f769a141"),
    ("toastfire", "demo toast", "demo body",
     "036df80782897d66", "ed1d4483d5635885", "2bd57346cf758e00", "6a4125a421bac78d"),
    ("", "Microsoft Defender summary", "x",
     "0000000000000000", "027788d3c0139744", "9c00e300c6a33433", "6374d3f7bdee6a1c"),
    ("", "A  B\tC", "",
     "0000000000000000", "6716c6ca018f9a3b", "0000000000000000", "5b582a67e1dd4f71"),
    ("", "ÄBC", "",
     "0000000000000000", "039b5b98bd5b84b6", "0000000000000000", "f0eeb0a333e54a42"),
    ("", "", "",
     "0000000000000000", "0000000000000000", "0000000000000000", "0000000000000000"),
]


# --------------------------------------------------------------------------------------------- parsing
TS_FMT = "%Y-%m-%d %H:%M:%S.%f"
AGENT_RE = re.compile(r"^\[(\d{4})(\d{2})(\d{2})\.(\d{2})(\d{2})(\d{2})\.(\d{3})[^\]]*\]\s*(.*)$")
# THE WRITER DECLARES A LEVEL NOW, AND THIS PARSER ANCHORED WHERE THE TEXT USED TO START.
# qtb_shared.h's BLog/BLogW/BLogE prefix every bridge line with "[INFO] " / "[WARN] " /
# "[ERROR] " so a sweep can read severity from the writer. This regex captured everything
# after the timestamp as the message, so msg became "[INFO] connected (server version 1.0)"
# and EVERY msg.startswith(...) below missed. MEASURED 2026-10-16 on the win11r-thold evidence:
# parse_bridge returned ZERO events from a 470-line log - no CONNECTED, no HOLDLIVE, no ARMED -
# so the BRIDGE precondition read "the bridge never logged connected ... nothing could be
# forwarded", HOLD-IPC read "FAIL ... `HOLD records live` absent - mixed install" about a line
# sitting at line 19 of that same file, and 12 of the suite's 21 rows went ungraded. A suite
# grading under a third of itself is not a measurement, and this is why.
# The level is OPTIONAL so a pre-prefix capture still parses.
BRIDGE_RE = re.compile(r"^(\d{2}):(\d{2}):(\d{2}) (?:\[(?:ERROR|WARN|WARNING|INFO|DEBUG)\] )?(.*)$")
KV_RE = re.compile(r"\b([A-Za-z_]+)=([0-9A-Za-z._:/\\-]+)")
HEX_RE = r"0x([0-9a-fA-F]+)"


# --------------------------------------------------------------------------------------- the clock (ONE instant each)
# EVERY INSTANT HERE IS THE GUEST'S, AND THIS PROCESS'S CLOCK IS NOT A REFERENCE FOR ANY OF THEM.
# The two are not in phase. MEASURED, the harness's own log line for the win11r-thold evidence - the
# bracketed stamp is this qube's `date`, the THC stamp is the guest's own:
#   [16:11:38] toast-hold[win11r-thold]: ... THC now=2026-10-06 19:11:39.705 tz=00:00:00
# the guest THREE HOURS AHEAD of this qube, guest zone UTC and this qube on UTC+3. The same pairing is
# recorded in tools/tests/clock-sync-selftest.sh ("the guest clock was 3 h ahead of the host with its
# own zone set to UTC") and in tools/log-sweep.py ("on 2026-10-14 every cell's guest ran three hours
# ahead at boot, 2249 lines were shifted back"); a run's health.json carries "boot_skew_s": -10720.
# So guest timestamps are parsed into instants carrying the guest's UTC offset (the collector prints it
# as `tz=<offset>`), and comparisons are between absolute instants. A naive host datetime finding its
# way back into one of these comparisons raises TypeError instead of quietly answering.
GUEST_ZONE_ASSUMED = dt.timezone.utc     # offset unknown: ONE placeholder zone for every guest source in the
                                         # capture, so the comparisons between them are unchanged. Not a claim
                                         # about the guest's zone - nothing prints or derives one from it.


class NoBridgeReference(Exception):
    """bridge.log has lines, and the capture offered no instant on the guest's clock to date them from."""


def parse_utc_offset(s: Optional[str]) -> Optional[dt.timezone]:
    """A .NET TimeSpan as the collector prints it (`tz=00:00:00`, `tz=03:00:00`, `tz=-05:00:00`) -> a fixed zone."""
    m = re.match(r"^(-)?(?:(\d+)\.)?(\d{1,2}):(\d{2})(?::(\d{2}))?$", (s or "").strip())
    if not m:
        return None
    d = dt.timedelta(days=int(m.group(2) or 0), hours=int(m.group(3)), minutes=int(m.group(4)),
                     seconds=int(m.group(5) or 0)) * (-1 if m.group(1) else 1)
    return dt.timezone(d) if abs(d) <= dt.timedelta(hours=18) else None


def parse_ts(s: str, tz: Optional[dt.tzinfo] = None) -> dt.datetime:
    """A guest stamp (`yyyy-MM-dd HH:mm:ss.fff`) -> an instant in the guest's zone. A trailing `tz=<offset>` is
    NOT part of the stamp: the collector's `where` mode prints `THC now=<ts> tz=<offset>`, and that one token used
    to make strptime raise - which the caller read as "no reference" and answered with this process's clock."""
    s = re.sub(r"\s+tz=\S+$", "", (s or "").strip())
    for fmt in (TS_FMT, "%Y-%m-%d %H:%M:%S"):
        try:
            t = dt.datetime.strptime(s, fmt)
        except ValueError:
            continue
        return t if tz is None else t.replace(tzinfo=tz)
    raise ValueError(f"not a guest timestamp: {s!r}")


class Ev:
    __slots__ = ("t", "idx", "kind", "hwnd", "kv", "msg")

    def __init__(self, t, idx, kind, hwnd, kv, msg):
        self.t, self.idx, self.kind, self.hwnd, self.kv, self.msg = t, idx, kind, hwnd, kv, msg

    def key(self):
        return (self.t, self.idx)


def is_unmap(e: "Ev") -> bool:
    """Did this line take a MAPPED banner off dom0's screen?

    THE UNMAP THE SHIPPED LOG LEVEL CARRIES IS NOT `Unmapping window`. send.c:819 writes that one at
    LogDebug, and has since 2026-10-08 (owner: "ok for debug but not for regular operation"); the
    product ships LogLevel 3, so a guest capture holds ZERO of them. The line the unmap DOES write at
    INFO is main.c:10058, immediately after SendWindowUnmap, for exactly this case - the hold taking
    back a banner it had already mapped (a pre-emption, or new content held for its own verdict).

    MEASURED, run 40407378739 on win11r-thold 2026-10-27: the hold unmapped the mapped banner at
    04:57:49.339 (both the QGATOASTPREEMPT line and main.c's) and `grep -c 'Unmapping window'` over the
    whole capture is 0. So mapped_timeline never left MAP, and id=13 - forwarded, and never mapped -
    graded DOUBLE=flash on mapped_at_exam=1, 4.47 s AFTER the window came down. The grader's own
    self-test did not catch it because its `preempt_ok` fixture hand-wrote the DEBUG line beside the
    pre-emption, i.e. a capture the product cannot produce.

    The DEBUG line stays accepted, for a capture taken at level 4."""
    return e.kind == "UNMAP" or (e.kind == "TH" and e.kv.get("state") == "unmapped-mapped")


def parse_agent(lines: List[str], offset: dt.timedelta, tz: Optional[dt.tzinfo] = None) -> List[Ev]:
    """Agent lines -> events on the GUEST LOCAL clock (agent timestamp minus the probe-derived offset)."""
    evs: List[Ev] = []
    for idx, line in enumerate(lines):
        m = AGENT_RE.match(line)
        if not m:
            continue
        y, mo, d, hh, mm, ss, ms, msg = m.groups()
        t = dt.datetime(int(y), int(mo), int(d), int(hh), int(mm), int(ss), int(ms) * 1000, tzinfo=tz) - offset
        kind, hwnd, kv = None, None, {}
        mm_ = re.search(r"QGAPROTO,msg=(CREATE|MAP|DESTROY),hwnd=" + HEX_RE, msg)
        if mm_:
            kind, hwnd = mm_.group(1), mm_.group(2).lower()
        elif re.search(r"Unmapping window " + HEX_RE, msg):
            kind = "UNMAP"; hwnd = re.search(r"Unmapping window " + HEX_RE, msg).group(1).lower()
        elif "QGATOASTHOLDLATE hwnd=" in msg:
            kind = "LATE"; hwnd = re.search(r"QGATOASTHOLDLATE hwnd=" + HEX_RE, msg).group(1).lower()
            kv = dict(KV_RE.findall(msg))
            mh = re.search(r"after (\d+) ms", msg)
            if mh:
                kv["held_ms"] = mh.group(1)
        elif msg.startswith("QGATOASTHOLD bridge down") or "QGATOASTHOLD bridge down" in msg:
            kind = "BRIDGEDOWN"
        elif "QGATOASTHOLD gate:" in msg or "QGATOASTHOLD INERT" in msg:
            kind = "GATE"
            kv["gate"] = ("ACTIVE" if "gate: ACTIVE" in msg else "INERT" if "INERT" in msg
                          else "OFF" if "gate: OFF" in msg else "inactive")
        elif "QGATOASTHOLD hwnd=" in msg:
            kind = "TH"; hwnd = re.search(r"QGATOASTHOLD hwnd=" + HEX_RE, msg).group(1).lower()
            kv = dict(KV_RE.findall(msg))
            if "content changed in place" in msg:
                kv["state"] = "content-changed"
            elif "unmapped a MAPPED banner" in msg:
                kv["state"] = "unmapped-mapped"
            elif "re-announced its buffer before the re-map" in msg:
                kv["state"] = "reannounced"
            elif "could not re-announce its buffer" in msg:
                kv["state"] = "reannounce-failed"
            elif "is re-mapped detached" in msg:
                kv["state"] = "remap-detached"
            ma = re.search(r"after (\d+) ms suppressed", msg)
            if ma:
                kv["held_ms"] = ma.group(1)
        elif "QGATOASTGATE hwnd=" in msg:
            # The gate TRANSITION family (toasthold.c). Note the space: the per-frame drop line is
            # QGATOASTGATEDROP, which this does not match and which is pure volume, not a state change.
            kind = "GATE"; hwnd = re.search(r"QGATOASTGATE hwnd=" + HEX_RE, msg).group(1).lower()
            kv["what"] = "gated" if " frames gated" in msg else "resumed"
        elif "QGATOASTREPAINT hwnd=" in msg:
            # The gate release's repaint DEBT and its settlement (agent bcd7bda). Three shapes:
            # `owed=deferred feed=slice`, `frame=seen owed_ms=N`, `paid=immediate|paid=region after N ms`.
            # A release is NOT a repaint: for a slice-fed banner - which every toast banner is - the payment
            # rides the next capture frame, and measured on run 41161440735 none arrived in the 5.9 s before
            # the window was destroyed, so dom0 kept the PREVIOUS toast's frame. Only `paid` says the pixels
            # went out, which is why this is parsed rather than skipped by the else below.
            kind = "REPAINT"; hwnd = re.search(r"QGATOASTREPAINT hwnd=" + HEX_RE, msg).group(1).lower()
            kv = dict(KV_RE.findall(msg))
        elif "QGATOASTPREEMPT hwnd=" in msg:
            kind = "PREEMPT"; hwnd = re.search(r"QGATOASTPREEMPT hwnd=" + HEX_RE, msg).group(1).lower()
            # " unmapped:" means a WITHDRAWAL and nothing else - it is what the PREEMPTED verdict below
            # keys on. Since swap-edge gating (ADR-toasts 10) the normal pre-emption HOLDS THE FRAMES and
            # the banner stays mapped, which is not a withdrawal and must not be graded as one; only the
            # rule-5 fallback (no frame-gate slot free) still unmaps, and its line still says "unmapped:".
            # Named here rather than left to fall into the "re-mapped" bucket, so a future reword cannot
            # quietly turn a hold into a withdrawal or the other way round.
            kv["what"] = ("unmapped" if " unmapped:" in msg
                          else "frames-held" if " frames held:" in msg
                          else "frames-resumed" if " frames resumed after" in msg
                          else "re-mapped")
            kv.update(dict(KV_RE.findall(msg)))
        elif "QGATOASTIDENT hwnd=" in msg:
            kind = "IDENT"; hwnd = re.search(r"QGATOASTIDENT hwnd=" + HEX_RE, msg).group(1).lower()
            kv = dict(KV_RE.findall(msg))
            kv["what"] = ("partial" if "PARTIAL match" in msg else "not-banner" if "not a toast banner" in msg
                          else "unreadable" if "card not readable" in msg else "other")
        elif "QGAHELDDEFER hwnd=" in msg:
            kind = "HELDDEFER"; hwnd = re.search(r"QGAHELDDEFER hwnd=" + HEX_RE, msg).group(1).lower()
            kv = dict(KV_RE.findall(msg))
        elif "QGAHELDMAP hwnd=" in msg:
            kind = "HELDMAP"; hwnd = re.search(r"QGAHELDMAP hwnd=" + HEX_RE, msg).group(1).lower()
            kv = dict(KV_RE.findall(msg))
        elif re.search(HEX_RE + r": toast card in", msg):
            kind = "CARD"; hwnd = re.search(HEX_RE + r": toast card in", msg).group(1).lower()
        elif "Seamless mode changed to" in msg:
            kind = "MODE"; kv["seamless"] = re.search(r"Seamless mode changed to (\d)", msg).group(1)
        elif re.search(r"RESREQ (\d+)x(\d+)|New resolution: (\d+) x (\d+)", msg):
            kind = "RES"; mr = re.search(r"RESREQ (\d+)x(\d+)|New resolution: (\d+) x (\d+)", msg)
            kv["w"] = mr.group(1) or mr.group(3); kv["h"] = mr.group(2) or mr.group(4)
        elif "window 0 announced at" in msg:
            kind = "W0ANNOUNCE"
        else:
            continue
        evs.append(Ev(t, idx, kind, hwnd, kv, msg))
    return evs


def parse_bridge(lines: List[str], ref_now: Optional[dt.datetime], tz: Optional[dt.tzinfo] = None) -> List[Ev]:
    """bridge.log lines (`16:32:22 [INFO] ...` - a time of day on the GUEST's clock and NO date) -> events with a
    date. The LAST line is dated to the instant NEAREST ref_now with that time of day; earlier lines walk
    backwards, a day down at each midnight wrap (time of day jumping up by more than 12 h going backwards).

    ref_now IS THE CAPTURE'S OWN INSTANT, ON THE GUEST'S CLOCK, AND IT IS REQUIRED.
    It used to default to dt.datetime.now() - THIS process's local clock - with the guest's time of day compared
    against the host's, under the rule "later than now, so it was yesterday". With the measured pairing (guest 3 h
    ahead; see GUEST_ZONE_ASSUMED above) every bridge line is "later than now", so that branch fires for the WHOLE
    log and dates it ONE DAY EARLY: no bridge record is then within RECORD_SLACK_S of any fire, every toast reads
    UNLISTED, and a grader that correlated nothing reports an ungraded run instead of a broken instrument - the
    TOASTHOLDPARSERBLIND shape (findings/issues.md: 12 of 21 rows ungraded, and the cause was in the parser).
    In the other direction - this process's calendar day AHEAD of the guest's - the error is +1 day, and then the
    `e.t >= t0 - RECORD_SLACK_S` test that BINDS a bridge record to its fire is vacuously true for every record in
    the log: one stamped a minute BEFORE its toast was fired is credited to it, which grades as OK-BRIDGED, i.e.
    PASS. Both directions are in tools/tests/toasthold-grade-clock-selftest.sh, each seen to fail without this.
    """
    rows: List[Tuple[int, int, str]] = []       # (idx, seconds-of-day, msg)
    for idx, line in enumerate(lines):
        m = BRIDGE_RE.match(line.rstrip("\r"))
        if not m:
            continue
        hh, mm, ss, msg = m.groups()
        rows.append((idx, int(hh) * 3600 + int(mm) * 60 + int(ss), msg))
    if not rows:
        return []
    if ref_now is None:
        raise NoBridgeReference("bridge.log carries a time of day and no date, and no instant on the guest's "
                                "clock was given to date it from")
    # The nearest instant, not "today unless it looks later than now": the reference may be stamped slightly
    # BEFORE the last line (the clock probe's, a fire's) as well as after it (the pull's). Correct whenever the
    # reference is within 12 h of the line, which every stamp this capture carries is - and with the pull's own
    # stamp it is the same answer the +60 s rule gave, so a run whose sources share one phase does not move.
    anchor = dt.datetime.combine(ref_now.date(), dt.time(0)).replace(tzinfo=ref_now.tzinfo) \
        + dt.timedelta(seconds=rows[-1][1])
    day = min((anchor + dt.timedelta(days=k) for k in (-1, 0, 1)), key=lambda t: abs(t - ref_now)).date()
    dates = [None] * len(rows)
    dates[-1] = day
    for i in range(len(rows) - 2, -1, -1):
        if rows[i][1] > rows[i + 1][1] + 12 * 3600:
            day = day - dt.timedelta(days=1)
        dates[i] = day
    evs: List[Ev] = []
    for (idx, sod, msg), d in zip(rows, dates):
        t = dt.datetime.combine(d, dt.time(0)).replace(tzinfo=tz) + dt.timedelta(seconds=sod)
        kind, kv = None, {}
        if msg.startswith("HOLD id=") and " seq=" in msg:
            kind = "HOLDPUB"; kv = dict(KV_RE.findall(msg))
        elif msg.startswith("HOLD id=") and " verdict=" in msg:
            kind = "HOLDV"; kv = dict(KV_RE.findall(msg)); kv["classifier"] = "1" if "classifier" in msg else "0"
        elif msg.startswith("HOLD records live"):
            kind = "HOLDLIVE"
        elif msg.startswith("HOLD "):
            kind = "HOLDOTHER"
        elif msg.startswith("SENT id="):
            ms = re.match(r"SENT id=(\d+) app='(.*)' title='(.*)': (OK|FAIL)", msg)
            if not ms:
                continue
            kind = "SENT"; kv = {"id": ms.group(1), "app": ms.group(2), "title": ms.group(3), "ok": ms.group(4)}
        elif msg.startswith("SENT coalesced"):
            kind = "SENTCOAL"; kv = {"ok": "OK" if ": OK" in msg else "FAIL"}
        elif msg.startswith("FWD_RTT "):
            kind = "FWD"; kv = dict(KV_RE.findall(msg))
        elif msg.startswith("skip id="):
            ms = re.match(r"skip id=(\d+) aumid=(\S+) \(window path; ([^)]*)\)", msg)
            if not ms:
                continue
            kind = "SKIP"; kv = {"id": ms.group(1), "aumid": ms.group(2), "reason": ms.group(3)}
        elif msg.startswith("route id="):
            kind = "ROUTE"; kv = dict(KV_RE.findall(msg))
        elif msg.startswith("await id="):
            kind = "AWAIT"; kv = dict(KV_RE.findall(msg))
        elif msg.startswith("GIVE UP id="):
            kind = "GIVEUP"; kv = dict(KV_RE.findall(msg))
        elif msg.startswith("MODE "):
            kind = "MODE"; kv["seamless"] = "0" if msg.startswith("MODE non-seamless") else "1"
        elif msg.startswith("BRIDGE armed allow=["):
            kind = "ARMED"; kv["allow"] = msg[len("BRIDGE armed allow=["):].rstrip("]")
        elif msg.startswith("connected (server version"):
            kind = "CONNECTED"
        elif msg.startswith("connection down"):
            kind = "CONNDOWN"
        elif msg.startswith("BRIDGE stopped"):
            kind = "STOPPED"
        elif msg.startswith("CLASSIFY id="):
            kind = "CLASSIFY"; kv = dict(KV_RE.findall(msg))
        else:
            continue
        evs.append(Ev(t, idx, kind, None, kv, msg))
    return evs


# --------------------------------------------------------------------------------------------- the grader
class Grader:
    def __init__(self, out: str, ref_now_arg: Optional[str] = None):
        self.out = out
        self.rows: List[Tuple[str, str]] = []
        self.meta = self._load_json("meta.json", {})
        self.fires = self._load_jsonl("fires.jsonl")
        self.waits = self._load_jsonl("waits.jsonl")
        self.hold_build = int(self.meta.get("hold_build", -1))
        self.agent_lines = self._load_lines("agent.log")
        self.bridge_lines = self._load_lines("bridge.log")
        self.sync_txt = self._load_text("sync.txt")
        self.where_txt = self._load_text("where.txt")
        # The guest's own UTC offset, where the capture records it (the collector's `THC now=<ts> tz=<offset>`).
        self.guest_tz = parse_utc_offset(self.meta.get("guest_utc_offset"))
        self.guest_tz_src = "meta.json guest_utc_offset" if self.guest_tz else ""
        if self.guest_tz is None:
            m = re.search(r"THC now=\S+ \S+ tz=(\S+)", self.where_txt or "")
            if m:
                self.guest_tz = parse_utc_offset(m.group(1))
                self.guest_tz_src = "where.txt tz=" + m.group(1) if self.guest_tz else ""
        if self.guest_tz is None:
            self.guest_tz = GUEST_ZONE_ASSUMED
        self.ref_now_arg = ref_now_arg
        self.ref_now: Optional[dt.datetime] = None
        self.ref_src = ""
        self.ref_tag = "unresolved"
        self.ref_bad: List[str] = []
        self.offset = dt.timedelta(0)
        self.agent: List[Ev] = []
        self.bridge: List[Ev] = []
        self.fatal = False

    # -- io
    def _p(self, name):
        return os.path.join(self.out, name)

    def _load_json(self, name, default):
        try:
            with open(self._p(name), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return default

    def _load_jsonl(self, name):
        rows = []
        try:
            with open(self._p(name), encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        rows.append(json.loads(line))
        except OSError:
            pass
        return rows

    def _load_lines(self, name):
        try:
            with open(self._p(name), encoding="utf-8", errors="replace") as f:
                return [ln.rstrip("\r\n") for ln in f]
        except OSError:
            return None

    def _load_text(self, name):
        try:
            with open(self._p(name), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    def row(self, label: str, text: str):
        self.rows.append((label, text))

    # -- clock: the instant bridge.log's times of day are dated from (the guest's, from THIS capture)
    def _ref_candidates(self) -> List[Tuple[dt.datetime, str, bool, str]]:
        """(instant, source, authoritative, short tag) for every instant on the guest's clock this capture carries."""
        out: List[Tuple[dt.datetime, str, bool, str]] = []
        if self.ref_now_arg:
            out.append((parse_ts(self.ref_now_arg, self.guest_tz), "--ref-now (named by the operator)", True, "ref-now"))
        pn = self.meta.get("pull_now")
        if pn:
            try:
                out.append((parse_ts(pn, self.guest_tz), "meta.json pull_now (the collector's `THC now=` at the pull)",
                            True, "pull_now"))
            except ValueError:
                self.ref_bad.append(f"meta.json pull_now={pn!r} is not a guest timestamp")
        for fld in ("t_closed", "t_close", "t_seen", "t_start"):
            m = re.search(r"THC sync [^\n]*\b" + fld + r"=(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)", self.sync_txt or "")
            if m:
                out.append((parse_ts(m.group(1), self.guest_tz), f"sync.txt {fld} (the clock probe)", False, "sync:" + fld))
        fts: List[Tuple[dt.datetime, str]] = []
        for f in self.fires:
            for fld in ("t1", "t0"):
                if f.get(fld):
                    try:
                        fts.append((parse_ts(f[fld], self.guest_tz), f"fires.jsonl {f.get('label', '?')} {fld}"))
                    except ValueError:
                        self.ref_bad.append(f"fires.jsonl {f.get('label', '?')} {fld}={f[fld]!r} is not a guest timestamp")
        if fts:
            t, src = max(fts, key=lambda x: x[0])
            out.append((t, src, False, ("fire:" + src.split()[-2]) if len(src.split()) > 2 else "fire"))
        return out

    def clock_reference(self) -> bool:
        """Settle self.ref_now. False = nothing in this capture can date bridge.log, so nothing is graded."""
        cands = self._ref_candidates()
        bad = ("; " + ", ".join(self.ref_bad)) if self.ref_bad else ""
        zone = self.guest_tz_src or f"zone not recorded in the capture, one assumed for all of it ({self.guest_tz})"
        if not cands:
            self.ref_tag = "none"
            self.row("CLOCK-REF", "INSTRUMENT bridge.log carries a time of day and no date, and this capture carries "
                                  "no instant on the guest's clock to date it from (no meta.json pull_now, no sync.txt "
                                  "probe stamp, no fire timestamp) - re-grade with --ref-now '<yyyy-mm-dd "
                                  f"HH:MM:SS.fff>' from the run's own record. This process's clock is not a reference{bad}")
            return False
        auth = [c for c in cands if c[2]]
        pick = auth[0] if auth else max(cands, key=lambda c: c[0])
        capture = [c[0] for c in cands if not c[1].startswith("--ref-now")]
        spread = (max(capture) - min(capture)) if capture else dt.timedelta(0)
        if spread > dt.timedelta(hours=12):
            self.ref_tag = "disagree"
            self.row("CLOCK-REF", f"INSTRUMENT the capture's own guest instants span {spread} (a run is under an hour) - "
                                  f"this directory mixes runs, or the guest's clock moved mid-run; a log with no date "
                                  f"cannot be dated from it{bad}")
            return False
        self.ref_now, self.ref_src, self.ref_tag = pick[0], pick[1], pick[3]
        stamp = pick[0].strftime(TS_FMT)[:-3]
        if pick[2]:
            self.row("CLOCK-REF", f"PASS bridge.log dated on the guest's clock from {pick[1]} = {stamp} "
                                  f"(guest {zone}; {len(cands)} capture instant(s), spread {spread}){bad}")
        else:
            # A FALLBACK FIRING IS AN ANOMALY, AND IT IS SAID OUT LOUD. The pull's own stamp is the datum the
            # design asks for; without it the rows below still grade (the probe's / the fire's stamp is the same
            # guest clock), but the RUN is not closed - re-pull, or re-grade with --ref-now.
            self.row("CLOCK-REF", f"INSTRUMENT the pull's own `THC now=` stamp is absent from meta.json - bridge.log "
                                  f"dated from {pick[1]} = {stamp} instead (guest {zone}; spread {spread}). The rows "
                                  f"below are graded on that; the RUN is NOT closed: re-pull, or re-grade with "
                                  f"--ref-now{bad}")
        return True

    def tie_clock(self) -> bool:
        """The CLOCK PROBE: charmap's CREATE in the agent log vs the probe's own local stamps."""
        m = re.search(r"THC sync t_start=(\S+ \S+) t_seen=(\S+ \S+) hwnd=0x([0-9a-fA-F]+)", self.sync_txt or "")
        if not m:
            self.row("CLOCK", "INSTRUMENT the clock probe produced no window (sync.txt has no t_seen/hwnd) - the agent "
                              "log's clock cannot be tied to the guest clock; nothing below is joinable")
            return False
        t_start, t_seen = parse_ts(m.group(1), self.guest_tz), parse_ts(m.group(2), self.guest_tz)
        hwnd = m.group(3).lower()
        raw = parse_agent(self.agent_lines or [], dt.timedelta(0), self.guest_tz)
        creates = [e for e in raw if e.kind == "CREATE" and e.hwnd == hwnd]
        if not creates:
            self.row("CLOCK", f"INSTRUMENT no QGAPROTO CREATE for the probe window 0x{hwnd} in the agent log - "
                              f"ProtoTrace is off, or the pulled log is not the live agent's; no MAP/UNMAP line can "
                              f"be trusted to exist, so no toast can be graded")
            return False
        c = creates[0]
        raw_off = (c.t - t_seen).total_seconds()
        quarter = 900.0
        off = round(raw_off / quarter) * quarter
        residual = raw_off - off
        lo = -((t_seen - t_start).total_seconds() + 1.0)
        if not (lo <= residual <= CLOCK_RESIDUAL_S):
            self.row("CLOCK", f"INSTRUMENT the probe window's CREATE sits {raw_off:+.3f} s from the probe's t_seen - "
                              f"not within [{lo:.1f}, +{CLOCK_RESIDUAL_S:.0f}] s of any 15-minute offset "
                              f"(nearest {off:+.0f} s, residual {residual:+.3f} s): the two clocks do not join")
            return False
        self.offset = dt.timedelta(seconds=off)
        gone = [e for e in raw if e.kind in ("DESTROY", "UNMAP") and e.hwnd == hwnd and e.t > c.t]
        self.row("CLOCK", f"PASS agent-log clock = guest clock {off:+.0f} s (probe CREATE residual {residual:+.3f} s); "
                          f"window-gone detector {'fired (' + gone[0].kind + ')' if gone else 'did NOT fire for the closed probe window'}")
        return True

    # -- helpers over events
    def mapped_timeline(self, hwnd: str) -> List[Ev]:
        return sorted([e for e in self.agent if e.hwnd == hwnd
                       and (e.kind in ("MAP", "DESTROY", "GATE") or is_unmap(e))], key=Ev.key)

    def mapped_at(self, hwnd: str, when: dt.datetime, idx: Optional[int] = None) -> bool:
        """Was this banner window showing ITS OWN current content in dom0 at that instant?

        MAPPED IS NO LONGER THE WHOLE ANSWER. Since swap-edge gating (ADR-toasts 10) the agent keeps a
        banner window mapped while holding back its frames, so dom0 goes on displaying the frame it
        already had - the PREVIOUS toast - while the shared window is repainted underneath with the next
        one. A window that is mapped but gated is therefore not showing the toast that just took it, and
        counting it as shown turns every correctly-held swap into a DOUBLE: measured here, this predicate
        graded the fixed shape of run 40407378739 as DOUBLE=flash over a 20 ms interval in which dom0 was
        provably holding the other toast's pixels.

        The gate's two ends are the QGATOASTGATE pair, from the only two places that move it - the
        tracking pass and the swap edge on the hook thread. Nothing is inferred: a window counts as gated
        only between a `frames gated` line and the next `frames resumed` for that same hwnd.
        """
        state, gated = False, False
        for e in self.mapped_timeline(hwnd):
            if (e.t, e.idx) > (when, idx if idx is not None else 10 ** 9):
                break
            if e.kind == "GATE":
                gated = e.kv.get("what") == "gated"
            else:
                state = e.kind == "MAP"
        return state and not gated

    def repaint_paid(self, hwnd: str, after: Tuple, until: Tuple) -> bool:
        """Did dom0 actually RECEIVE this window's current content after a gate release in that span?

        The release only records a debt (`owed=deferred`); the pixels go out when the tracking pass pays it
        (`paid=region after N ms`), or at once for a window on its own per-window capture (`paid=immediate`).
        For a slice-fed banner the payment rides the next capture frame, and on run 41161440735 the gate
        released after holding 3 frames, the debt was recorded, and NO frame arrived in the 5.9 s before the
        window was destroyed: `frame=seen` 0, `paid=` 0. dom0 kept the previous toast's banner. So a resume
        without a payment inside the toast's own segment is NOT this toast reaching the screen.
        """
        return any(e.kind == "REPAINT" and e.hwnd == hwnd and "paid" in e.kv and after < e.key() <= until
                   for e in self.agent)

    def banner_hwnds(self) -> set:
        s = set()
        for e in self.agent:
            if e.kind == "HELDDEFER" and e.kv.get("class") == BANNER_CLASS:
                s.add(e.hwnd)
            elif e.kind == "HELDMAP" and e.kv.get("toast") == "1":
                s.add(e.hwnd)
            elif e.kind in ("CARD", "TH", "LATE", "PREEMPT"):
                s.add(e.hwnd)
        s.discard("0")
        return s

    def delivered(self, nid: str) -> Tuple[bool, str]:
        for e in self.bridge:
            if e.kind == "FWD" and e.kv.get("guest_id") == nid and e.kv.get("ok") == "1":
                return True, "FWD_RTT ok=1"
        for e in self.bridge:
            if e.kind == "SENT" and e.kv.get("id") == nid and e.kv.get("ok") == "OK":
                return True, "SENT OK"
        for e in self.bridge:
            if e.kind == "HOLDV" and e.kv.get("id") == nid and e.kv.get("verdict") == "forwarded":
                return True, "HOLD verdict=forwarded"
        return False, "-"

    def final_verdict(self, nid: str, pub: Optional[Ev]) -> str:
        v = pub.kv.get("verdict", "?") if pub else "-"
        for e in self.bridge:
            if e.kind == "HOLDV" and e.kv.get("id") == nid and (pub is None or e.key() > pub.key()):
                v = e.kv.get("verdict", v)
        return v

    def guest_banner_seen(self, label: str) -> bool:
        for w in self.waits:
            if label in (w.get("labels") or []) and w.get("guest_banner_seen"):
                return True
        return False

    # -- per toast
    def grade_fire(self, f: dict) -> Tuple[str, str]:
        label, slug = f["label"], f.get("slug", "")
        if not f.get("fired"):
            return "INSTRUMENT", f"no FIRED line for {slug or label} (attempt {f.get('attempt')}) - the stimulus never confirmed; nothing to grade"
        t0 = parse_ts(f["t0"], self.guest_tz)
        t1 = parse_ts(f["t1"], self.guest_tz) if f.get("t1") else t0 + dt.timedelta(seconds=2)
        aumid = f.get("aumid", "")
        mode_ns = f.get("mode") == "nonseamless"
        th = title_hash_hex(slug)
        notes: List[str] = []

        # 1. the bridge's record / id
        pub = None
        for e in self.bridge:
            if e.kind == "HOLDPUB" and e.kv.get("t") == th and e.t >= t0 - dt.timedelta(seconds=RECORD_SLACK_S):
                pub = e
                break
        nid = pub.kv.get("id") if pub else None
        if nid is None:
            for e in self.bridge:
                if e.kind == "SENT" and e.kv.get("title") == slug and e.t >= t0 - dt.timedelta(seconds=RECORD_SLACK_S):
                    nid = e.kv["id"]; notes.append("id by SENT title"); break
        if nid is None:
            nid = self._claim_skip(f, t0)
            if nid:
                notes.append("id by skip aumid order")
        if nid is None:
            return "UNLISTED", (f"the bridge never listed {slug} (no HOLD record with t={th}, no SENT title, no skip for "
                                f"{aumid} after {f['t0']}) - INSTRUMENT: the toast did not reach the bridge, nothing to grade")
        deliv, how = self.delivered(nid)
        fv = self.final_verdict(nid, pub)
        skip = next((e for e in self.bridge if e.kind == "SKIP" and e.kv.get("id") == nid), None)

        # 2. the agent's view
        if self.hold_build == 1:
            cls, detail = self._grade_hold(f, nid, th, t0, t1, deliv, pub)
        else:
            cls, detail = self._grade_control(f, nid, t0, t1, deliv)
        notes.append(detail)

        # 3. non-seamless rows: the bridge's mode path is the fact that matters
        if mode_ns:
            ns_path = bool(skip and "non-seamless" in skip.kv.get("reason", ""))
            mapped_any = self._any_banner_map(t0, t0 + dt.timedelta(seconds=CONTROL_BANNER_WINDOW_S))
            if deliv:
                cls = "FORWARDED-NS"
            elif mapped_any:
                cls = "MAPPED-IN-NS"
            elif ns_path or fv == "window":
                cls = "OK-WINDOW-NS"
            else:
                cls = "LOST"
            notes.append(f"ns_path={int(ns_path)}")
        text = f"{cls} id={nid} delivered={int(deliv)}({how}) verdict={fv} {' ; '.join(n for n in notes if n)}"
        return cls, text

    def _claim_skip(self, f: dict, t0: dt.datetime) -> Optional[str]:
        """Control-build fallback: the k-th unclaimed `skip id= aumid=<this aumid>` after the fire, in fire order."""
        if not hasattr(self, "_claimed"):
            self._claimed = set()
        for e in self.bridge:
            if e.kind == "SKIP" and e.kv.get("aumid", "").lower() == f.get("aumid", "").lower() \
               and e.t >= t0 - dt.timedelta(seconds=RECORD_SLACK_S) and e.kv["id"] not in self._claimed:
                self._claimed.add(e.kv["id"])
                return e.kv["id"]
        return None

    def _any_banner_map(self, a: dt.datetime, b: dt.datetime) -> bool:
        B = self.banner_hwnds()
        return any(e.kind == "MAP" and e.hwnd in B and a <= e.t <= b for e in self.agent)

    @staticmethod
    def _held_start(e: "Ev") -> Tuple:
        """Where the agent's hold of the content a line names began, as an event key. ThCoreStartHold sets HoldSince on a hold
        start AND on an in-place content change, so a decision's held_ms counts from the moment THAT toast's content arrived
        in the window - in the ONE shared banner window a later toast arrives seconds after the window was created."""
        if e.kind == "TH" and e.kv.get("state") in ("hold", "content-changed"):
            return e.key()
        hm = e.kv.get("held_ms")
        if hm and hm.isdigit():
            return (e.t - dt.timedelta(milliseconds=int(hm)), -1)
        return e.key()

    def _segment_end(self, h: str, after: Tuple, nid: str, th: str, cap: dt.datetime) -> Tuple:
        """The end of a toast's time in window h: the next OTHER toast's content arriving there (a decision or a content
        change naming another id / title hash - from its own held start), the window's DESTROY, or the cap. A pre-emption
        does not end it: the guest keeps showing the displayed toast until the shell swaps the queued one in."""
        end = (cap, 10 ** 9)
        for e in self.agent:
            if e.hwnd != h or e.key() <= after:
                continue
            if e.kind == "DESTROY":
                end = min(end, e.key())
            elif e.kind in ("TH", "LATE"):
                eid, et = e.kv.get("id"), e.kv.get("t")
                other_id = eid not in (None, "0") and eid != nid
                other_t = e.kv.get("state") == "content-changed" and et not in (None, th)
                if other_id or other_t:
                    end = min(end, max(self._held_start(e), after))
        return end

    def _grade_hold(self, f, nid, th, t0, t1, deliv, pub) -> Tuple[str, str]:
        label = f["label"]
        mine = [e for e in self.agent if e.kind in ("TH", "LATE", "IDENT") and e.t >= t0 - dt.timedelta(seconds=1)
                and (e.kv.get("id") not in (None, "0") and e.kv.get("id") == nid or e.kv.get("t") == th)]
        hwnds = {e.hwnd for e in mine}
        if len(hwnds) > 1:
            return "AMBIGUOUS", f"agent lines for id={nid}/t={th} name {len(hwnds)} windows {sorted(hwnds)} - cannot attribute"
        if not hwnds:
            # Named only by a PRE-EMPTION: this toast was queued behind a displayed window-path banner, which the agent
            # unmapped so the swap could not paint into dom0. Its content arrives after that line, in that window - the
            # question is whether the window was mapped again while it could be showing this toast.
            pre = sorted([e for e in self.agent if e.kind == "PREEMPT" and e.kv.get("what") == "unmapped" and e.kv.get("id") == nid
                          and e.t >= t0 - dt.timedelta(seconds=1)], key=Ev.key)
            if pre:
                p = pre[0]
                end = self._segment_end(p.hwnd, p.key(), nid, th, p.t + dt.timedelta(seconds=CONTENT_WINDOW_S))
                remaps = [e for e in self.agent if e.hwnd == p.hwnd and e.kind == "MAP" and p.key() < e.key() < end]
                detail = (f"queued behind the displayed banner in hwnd=0x{p.hwnd}, pre-empted {p.t.strftime('%H:%M:%S.%f')[:-3]}; "
                          f"re-maps before another toast or the window's end: {len(remaps)}")
                if deliv:
                    return ("DOUBLE", detail + " double=after-preempt") if remaps else ("OK-BRIDGED", detail)
                if remaps:
                    return "OK-WINDOW", detail
                return "LOST", detail + " (window path, never mapped)"
            # Named only by a FRAME-GATED pre-emption - the NORMAL pre-emption since swap-edge gating (ADR-toasts 10),
            # and a shape this path was blind to: it only consulted the `unmapped:` withdrawal above. The agent holds
            # THIS toast's frames instead of withdrawing the window, so the window stays mapped with the OTHER toast's
            # pixels in it, and this toast reaches dom0 only if its frames are RELEASED while its content is in the
            # window - a gate resume or a fresh MAP, before another toast's content takes the window.
            # Measured, run 41154092416 S3ii-2 (id=24, hwnd=0x20240): the window's only MAP is the displayed toast's
            # own (`state=show ... id=23` at 04:05:53.624), the gate closed 720 ms later and the window was DESTROYED
            # at 04:06:04.404 with no resume - dom0 never got a frame of id=24. The fall-through below has no
            # segmentation at all (any banner MAP in a flat 10 s window), so it counted the other toast's banner as
            # this toast's and graded DOUBLE over a hold that worked. Run 1's same shape (id=13) escaped only because
            # that window survived long enough for the toast to be examined, which takes the owned path below.
            held = sorted([e for e in self.agent if e.kind == "PREEMPT" and e.kv.get("what") == "frames-held"
                           and e.kv.get("id") == nid and e.t >= t0 - dt.timedelta(seconds=1)], key=Ev.key)
            if held:
                p = held[0]
                end = self._segment_end(p.hwnd, p.key(), nid, th, p.t + dt.timedelta(seconds=CONTENT_WINDOW_S))
                # A RELEASE THAT WAS NEVER PAID PUT NOTHING ON THE SCREEN, and a bare MAP is not this
                # toast's: counting one cost a FALSE DOUBLE on run 41161440735 S3ii-2, where the only MAP in
                # id=13's segment (07:10:03.519) was the DISPLAYED toast id=12's own first map, 6167 ms late
                # by its own row. id=13's gate never resumed at all before the window died, so dom0 never had
                # its pixels. The MAP term was a stand-in from when no resume line existed; the resume does
                # exist now (agent 8440f75), so the release signal is the resume, and the repaint must land.
                resumes = [e for e in self.agent if e.hwnd == p.hwnd and e.kind == "GATE"
                           and e.kv.get("what") == "resumed" and p.key() < e.key() < end]
                # A MAP still counts, but only a RE-map: one with an UNMAP before it in this segment. That is
                # the shape the MAP term was for - a window withdrawn and brought back with the queued toast's
                # content in it, which emits no resume - and requiring the unmap is what stops the DISPLAYED
                # toast's own first map being billed here. Under frames-held gating the window stays mapped by
                # design, so a map with no unmap before it cannot be a re-exposure of this toast.
                segunmaps = [e for e in self.agent if e.hwnd == p.hwnd and is_unmap(e) and p.key() < e.key() < end]
                remaps = [e for e in self.agent if e.hwnd == p.hwnd and e.kind == "MAP" and p.key() < e.key() < end
                          and any(u.key() < e.key() for u in segunmaps)]
                shown = [r for r in resumes if self.repaint_paid(p.hwnd, r.key(), end)] + remaps
                detail = (f"queued behind the displayed banner in hwnd=0x{p.hwnd}, frames gated "
                          f"{p.t.strftime('%H:%M:%S.%f')[:-3]}; gate resumes before another toast takes the window "
                          f"or it ends: {len(resumes)}, re-maps after an unmap: {len(remaps)}, reached dom0: {len(shown)}")
                if deliv:
                    return ("DOUBLE", detail + " double=after-gated-preempt") if shown else ("OK-BRIDGED", detail)
                if shown:
                    return "OK-WINDOW", detail
                return "LOST", detail + " (window path, frames never released)"
            # The hold never examined a banner for this toast. Did a banner window get mapped anyway (a window the
            # hold did not own)? Did the guest show a banner at all?
            mapped_any = self._any_banner_map(t0, t0 + dt.timedelta(seconds=CONTROL_BANNER_WINDOW_S))
            seen = self.guest_banner_seen(label)
            if deliv and not mapped_any:
                return "OK-BRIDGED", "no banner examined by the hold, no banner window mapped" + (" (guest showed a banner)" if seen else "")
            if deliv and mapped_any:
                return "DOUBLE", "a banner window was MAPPED without a hold decision for this toast"
            if mapped_any:
                return "OK-WINDOW", "mapped without a hold decision (bound not measurable)"
            if seen:
                return "LOST", "the guest showed a banner (harness probe) but the agent never examined or mapped one"
            return "NO-BANNER", "no hold lines, no banner MAP, no banner seen in the guest"
        h = hwnds.pop()
        # Where THIS toast's examination began: the latest `state=hold` / `content changed` line on this window at or before
        # the first line that names the toast, but never before the toast's own held start (decision time minus held_ms) -
        # in the shared banner window the window's creation is the FIRST toast's start, not a later one's.
        naming = sorted([e for e in mine if e.kind in ("TH", "LATE") and (e.kv.get("t") == th or e.kv.get("id") == nid)], key=Ev.key)
        anchor = naming[0]
        prior = [e for e in self.agent if e.hwnd == h and e.kind == "TH" and e.kv.get("state") in ("hold", "content-changed")
                 and e.key() <= anchor.key()]
        k_exam = max([self._held_start(anchor)] + ([max(prior, key=Ev.key).key()] if prior else []))
        t_exam = k_exam[0]
        # ...until another toast's content takes the window (review #5: a reading with OUR hash completes this toast).
        w_end = self._segment_end(h, anchor.key(), nid, th, t_exam + dt.timedelta(seconds=CONTENT_WINDOW_S))
        in_win = [e for e in self.agent if e.hwnd == h and k_exam <= e.key() < w_end]
        decisions = [e for e in in_win if e.kind in ("TH", "LATE") and e.kv.get("state") in ("suppress", "show") or e.kind == "LATE"]
        suppress = [e for e in decisions if e.kv.get("state") == "suppress"]
        late = [e for e in in_win if e.kind == "LATE"]
        mapped_at_exam = self.mapped_at(h, k_exam[0], k_exam[1])   # idx -1: the state just before the content arrived
        maps = [e for e in in_win if e.kind == "MAP"]
        unmaps = [e for e in in_win if is_unmap(e)]
        preempts = [e for e in in_win if e.kind == "PREEMPT" and e.kv.get("what") == "unmapped"]
        # UNDER SWAP-EDGE GATING THE SECOND TOAST IN A SHARED WINDOW GETS NO MAP OF ITS OWN: the window is
        # already mapped, and what reaches dom0 is the gate release plus the repaint it forces. So a release
        # whose repaint was PAID inside this toast's segment is this toast being shown, and one that was not
        # is the window frozen on the previous toast's frame (run 41161440735 id=15: resumed after 3 held,
        # owed=deferred, then no frame and no payment in the 5.9 s before the destroy - a real loss).
        releases = [e for e in in_win if e.kind == "GATE" and e.kv.get("what") == "resumed"
                    and self.repaint_paid(h, e.key(), w_end)]
        shown_ev = min(maps + releases, key=Ev.key) if (maps or releases) else None
        mapped = mapped_at_exam or shown_ev is not None
        delay_ms = 0 if mapped_at_exam else (int((shown_ev.t - t_exam).total_seconds() * 1000) if shown_ev else None)
        reasons = ",".join(sorted({e.kv.get("reason", "?") for e in late})) if late else "-"
        detail = (f"hwnd=0x{h} examined={t_exam.strftime('%H:%M:%S.%f')[:-3]} decisions="
                  f"{'/'.join((e.kv.get('state') or 'late') for e in decisions) or 'none'} mapped_at_exam={int(mapped_at_exam)} "
                  f"maps={len(maps)} repainted_releases={len(releases)} unmaps={len(unmaps)} "
                  f"map_delay_ms={delay_ms if delay_ms is not None else '-'} failopen={reasons}")
        if deliv and not mapped:
            return "OK-BRIDGED", detail
        if deliv and mapped:
            kind = "flash" if (mapped_at_exam or unmaps) else "full"
            return "DOUBLE", detail + f" double={kind}"
        if mapped:
            if delay_ms is not None and delay_ms > WINDOW_BOUND_MS:
                return "LATE-WINDOW", detail + f" bound={WINDOW_BOUND_MS}"
            shown_at = None if mapped_at_exam else shown_ev
            pre = [e for e in preempts if shown_at is None or e.key() > shown_at.key()]
            if pre:
                # The owner's rule (ADR-toasts 10's Why): a flash is not fine, nothing is lost. A displayed window-path banner
                # unmapped while its content is still the guest's banner loses the rest of its dom0 display.
                p = pre[0]
                shown_ms = int((p.t - (shown_at.t if shown_at else t_exam)).total_seconds() * 1000)
                remapped = any(e.key() > p.key() for e in maps)
                return "PREEMPTED", detail + (f" preempted_after_ms={shown_ms} for id={p.kv.get('id', '?')}"
                                               f" remapped={int(remapped)} (shown, then withdrawn while still the guest's banner)")
            return "OK-WINDOW", detail
        if suppress or decisions or self.guest_banner_seen(label):
            return "LOST", detail + " (a banner existed and was never mapped)"
        return "NO-BANNER", detail

    def _grade_control(self, f, nid, t0, t1, deliv) -> Tuple[str, str]:
        label = f["label"]
        B = self.banner_hwnds()
        a, b = t0 - dt.timedelta(seconds=0.5), t0 + dt.timedelta(seconds=CONTROL_BANNER_WINDOW_S)
        maps = [e for e in self.agent if e.kind == "MAP" and e.hwnd in B and a <= e.t <= b]
        unmaps = [e for e in self.agent if e.kind == "UNMAP" and e.hwnd in B and a <= e.t <= b]
        creates = [e for e in self.agent if e.kind in ("CREATE", "HELDDEFER", "CARD") and e.hwnd in B and a <= e.t <= b]
        # another fire within the attribution window makes "whose MAP is this" undecidable
        others = [g for g in self.fires if g is not f and g.get("fired") and abs((parse_ts(g["t0"], self.guest_tz) - t0).total_seconds()) < CONTROL_BANNER_WINDOW_S]
        amb = " ambiguous-attribution" if others else ""
        mapped = bool(maps)
        delay_ms = int((maps[0].t - t0).total_seconds() * 1000) if maps else None
        detail = (f"banners={sorted(B) or '-'} maps={len(maps)} unmaps={len(unmaps)} banner_events={len(creates)} "
                  f"map_delay_from_fire_ms={delay_ms if delay_ms is not None else '-'}{amb}")
        if deliv and not mapped:
            return "OK-BRIDGED", detail
        if deliv and mapped:
            return "DOUBLE", detail + (" double=flash" if unmaps else " double=full")
        if mapped:
            return "OK-WINDOW", detail
        if creates or self.guest_banner_seen(label):
            return "LOST", detail + " (banner activity without a MAP)"
        return "LOST", detail + " (no banner at all - on this build the suppression hides the banner entirely)"

    # -- run-level
    def run_level(self):
        gate = [e for e in self.agent if e.kind == "GATE"]
        g = gate[0].kv.get("gate") if gate else None
        if self.hold_build == 1:
            if g == "ACTIVE":
                self.row("HOLD-GATE", "PASS QGATOASTHOLD gate: ACTIVE on this boot")
            else:
                self.row("HOLD-GATE", f"FAIL the hold is {g or 'absent from the agent log'} on a hold build - every bridged toast shows twice (precondition)")
        elif self.hold_build == 0:
            if g is None:
                self.row("HOLD-GATE", "PASS pre-hold package: no QGATOASTHOLD lines, as the reference binary predicted")
            else:
                self.row("HOLD-GATE", f"FAIL the package was classified pre-hold but the agent logs QGATOASTHOLD gate {g} - the build discriminator lied")
        else:
            self.row("HOLD-GATE", "INSTRUMENT meta.json carries no hold_build")
        live = any(e.kind == "HOLDLIVE" for e in self.bridge)
        conn = any(e.kind == "CONNECTED" for e in self.bridge)
        armed = [e for e in self.bridge if e.kind == "ARMED"]
        if not conn:
            self.row("BRIDGE", "INSTRUMENT the bridge never logged `connected (server version` in the pulled slice - nothing could be forwarded")
        else:
            self.row("BRIDGE", f"PASS connected; armed allow=[{armed[-1].kv.get('allow', '?') if armed else '?'}]"
                               + ("; HOLD records live" if live else ("; NO `HOLD records live` (mixed install?)" if self.hold_build == 1 else "")))
        if self.hold_build == 1 and not live:
            self.row("HOLD-IPC", "FAIL hold build but the bridge never opened the records section (`HOLD records live` absent) - mixed install")
        first_fire = min((parse_ts(f["t0"], self.guest_tz) for f in self.fires if f.get("fired")), default=None)
        if first_fire:
            restarts = [e for e in self.bridge if e.kind in ("ARMED", "STOPPED") and e.t > first_fire]
            if restarts:
                self.row("BRIDGE-RESTART", f"INSTRUMENT the bridge restarted/stopped {len(restarts)}x after the first fire ({restarts[0].msg[:60]}) - the environment changed mid-run")
            downs = [e for e in self.agent if e.kind == "BRIDGEDOWN" and e.t > first_fire]
            if downs:
                self.row("BRIDGE-DOWN", f"INSTRUMENT the agent saw the bridge go down {len(downs)}x during the scenarios")
        late = [e for e in self.agent if e.kind == "LATE" and (first_fire is None or e.t >= first_fire)]
        noident = [e for e in late if e.kv.get("reason") == "no-identity"]
        if noident:
            self.row("IDENT-FAILOPEN", f"FAIL {len(noident)} QGATOASTHOLDLATE reason=no-identity - the card's Title block was not readable on this build; "
                                       f"every bridged toast would show twice (ADR-toasts 10: must not ship)")
        elif late:
            self.row("IDENT-FAILOPEN", f"PASS no no-identity fail-open; {len(late)} other fail-open(s): " + ",".join(sorted({e.kv.get('reason', '?') for e in late})))
        elif self.hold_build == 1:
            self.row("IDENT-FAILOPEN", "PASS no QGATOASTHOLDLATE at all during the scenarios")
        # RE-MAP: dom0 drops a window's image on MSG_UNMAP (gui-daemon release_mapped_mfns), so a banner the hold unmapped after
        # it was shown must have its buffer re-announced before it is mapped again, or it comes back with no image (2026-10-06).
        remaps = ok_remaps = 0
        bad: List[str] = []
        for u in [e for e in self.agent if e.kind == "TH" and e.kv.get("state") == "unmapped-mapped"]:
            later = sorted([e for e in self.agent if e.hwnd == u.hwnd and e.key() > u.key()
                            and (e.kind in ("MAP", "DESTROY") or (e.kind == "TH" and e.kv.get("state") == "unmapped-mapped"))], key=Ev.key)
            if not later or later[0].kind != "MAP":
                continue   # destroyed or unmapped again before any re-map: nothing was shown without its buffer
            m = later[0]
            remaps += 1
            dumps = [e for e in self.agent if e.hwnd == u.hwnd and e.kind == "TH" and u.key() < e.key() < m.key()
                     and e.kv.get("state") == "reannounced"]
            if dumps:
                ok_remaps += 1
            else:
                bad.append(f"0x{u.hwnd}@{m.t.strftime('%H:%M:%S.%f')[:-3]}")
        if bad:
            self.row("REMAP-DUMP", f"FAIL {len(bad)} of {remaps} banner re-map(s) without the buffer re-announced first ({','.join(bad[:4])}) - shown with no image in dom0")
        elif remaps:
            self.row("REMAP-DUMP", f"PASS {ok_remaps} banner re-map(s), each after its buffer was re-announced")
        elif self.hold_build == 1:
            self.row("REMAP-DUMP", "INFO no banner the hold had unmapped after showing it was re-mapped in this run (the path was not exercised)")
        # NON-SEAMLESS SIZE (owner rule 2026-08-27, regression measured 2026-10-06): while the guest is non-seamless its desktop
        # must stay at the windowed size - a resize to (nearly) the host size is the desktop covering the screen. Host size = the
        # CREATE of window 0 at agent start; "covering" = the entry guard's own test (>= 95% width and >= 90% height).
        hostc = [e for e in self.agent if e.kind == "CREATE" and e.hwnd == "0"]
        hw = hh = 0
        if hostc:
            mh = re.search(r"w=(\d+),h=(\d+)", hostc[0].msg)
            if mh: hw, hh = int(mh.group(1)), int(mh.group(2))
        # A span runs from the switch to non-seamless until window 0 leaves dom0's screen (its UNMAP): leaving, the agent
        # unmaps window 0 FIRST and then restores the host resolution for seamless - that restore is not on the screen.
        ns_spans, cur = [], None
        for e in sorted([e for e in self.agent if e.kind == "MODE" or (e.kind == "UNMAP" and e.hwnd == "0")], key=Ev.key):
            if e.kind == "MODE" and e.kv.get("seamless") == "0" and cur is None: cur = e
            elif cur is not None and (e.kind == "UNMAP" or e.kv.get("seamless") == "1"): ns_spans.append((cur, e)); cur = None
        if cur is not None: ns_spans.append((cur, None))
        if ns_spans and hw and hh:
            big = []
            for a, b in ns_spans:
                for e in self.agent:
                    if e.kind == "RES" and e.key() > a.key() and (b is None or e.key() < b.key()):
                        w, h = int(e.kv["w"]), int(e.kv["h"])
                        if w * 100 >= hw * 95 and h * 100 >= hh * 90:
                            big.append(f"{w}x{h}@{e.t.strftime('%H:%M:%S')}")
            ann = [e for e in self.agent if e.kind == "W0ANNOUNCE"]
            if big:
                self.row("NS-SIZE", f"FAIL the non-seamless desktop was resized to cover the {hw}x{hh} host: {','.join(sorted(set(big)))}")
            else:
                self.row("NS-SIZE", f"PASS no resize to host size while non-seamless ({len(ns_spans)} span(s))"
                                    + (f"; window 0 announced before the map: {ann[0].msg.split('announced at ')[-1][:24]}" if ann else ""))
        elif ns_spans:
            self.row("NS-SIZE", "INSTRUMENT a non-seamless span but no window-0 CREATE with the host size in the pulled log")
        # stray toasts: THT- titles the bridge saw that no fire record names (a retry whose output was lost but fired)
        slugs = {f.get("slug") for f in self.fires}
        strays = sorted({e.kv["title"] for e in self.bridge if e.kind == "SENT" and e.kv.get("title", "").startswith(SLUG_PREFIX) and e.kv["title"] not in slugs})
        if strays:
            self.row("STRAY", f"INSTRUMENT {len(strays)} toast(s) with a THT- title the fire records do not name: {','.join(strays)} - a fire attempt whose output was lost; attribution and first-toast status are suspect")
        if self.meta.get("agent_log_final") and self.meta.get("agent_log") and self.meta["agent_log_final"] != self.meta["agent_log"]:
            self.row("AGENT-LOG", f"INSTRUMENT the newest agent log changed from {self.meta['agent_log']} to {self.meta['agent_log_final']} - the agent restarted mid-run; coverage is broken")

    def grade(self) -> int:
        if self.hold_build not in (0, 1):
            self.row("GRADED", "INSTRUMENT meta.json has no hold_build (0/1) - the package kind is unknown; nothing graded")
            return self._finish()
        if self.agent_lines is None or self.bridge_lines is None:
            self.row("GRADED", f"INSTRUMENT missing {'agent.log ' if self.agent_lines is None else ''}{'bridge.log' if self.bridge_lines is None else ''} in {self.out} - no coverage, nothing graded")
            return self._finish()
        if not self.fires:
            self.row("GRADED", "INSTRUMENT fires.jsonl is empty - no toast was recorded as fired; nothing graded")
            return self._finish()
        if not self.clock_reference():
            self.row("GRADED", "INSTRUMENT bridge.log cannot be dated - see CLOCK-REF; nothing graded")
            return self._finish()
        clock_ok = self.tie_clock()
        self.agent = parse_agent(self.agent_lines, self.offset, self.guest_tz)
        self.bridge = parse_bridge(self.bridge_lines, self.ref_now, self.guest_tz)
        self.run_level()
        summary = []
        for f in self.fires:
            label = f["label"]
            cls, text = self.grade_fire(f) if clock_ok else ("INSTRUMENT", "clock not tied - see CLOCK")
            exp = EXPECT[self.hold_build].get(label)
            gating = label in GATING[self.hold_build]
            if cls in ("INSTRUMENT", "UNLISTED", "NO-BANNER", "AMBIGUOUS"):
                self.row(label, f"INSTRUMENT {text}")
            elif gating:
                if exp is None:
                    self.row(label, f"INSTRUMENT no expectation for label {label} on hold_build={self.hold_build}: {text}")
                elif cls == exp:
                    self.row(label, f"PASS {text} (expected {exp})")
                else:
                    self.row(label, f"FAIL {text} (expected {exp})")
            else:
                self.row(label, f"INFO {text} (hint {CONTROL_INFO_HINT.get(label, '-')})")
            summary.append(f"{label}={cls}")
        if self.hold_build == 0:
            missing = [l for l in GATING[0] if l not in {f['label'] for f in self.fires}]
            bad = [l for (l, t) in self.rows if l in GATING[0] and not t.startswith("PASS")]
            if missing:
                self.row("DETECTORS", f"INSTRUMENT control gating rows missing: {','.join(sorted(missing))} - the detectors were not all exercised")
            elif bad:
                self.row("DETECTORS", f"FAIL DETECTOR UNPROVEN: {','.join(sorted(bad))} did not show the defect the pre-hold package carries - a candidate PASS would be decoration")
            else:
                self.row("DETECTORS", "PASS every detector fired on the pre-hold package: DOUBLE on S0/S1a, LOST on S2 (seen to fail)")
        return self._finish(summary)

    def _finish(self, summary=None) -> int:
        fails = [l for (l, t) in self.rows if t.startswith("FAIL")]
        ungraded = [l for (l, t) in self.rows if t.startswith(("INSTRUMENT", "INVALID"))]
        role = "CANDIDATE (hold build)" if self.hold_build == 1 else "CONTROL (pre-hold build)" if self.hold_build == 0 else "UNKNOWN"
        verdict = "PASS" if not fails and not ungraded else ("FAIL" if fails else "UNGRADED")
        if self.hold_build == 0 and verdict == "PASS":
            verdict = "PASS (the defect reproduced as predicted - the detectors are proven)"
        line = (f"GRADED run={self.meta.get('run_id', '?')} package_version={self.meta.get('package_version', '?')} "
                f"driver_repo_commit={str(self.meta.get('driver_repo_commit', '?'))[:12]} hold_build={self.hold_build} role={role} "
                f"subject={self.meta.get('subject', '?')} clock_ref={self.ref_tag}: {' '.join(summary or [])} "
                f"fails={len(fails)} ungraded={len(ungraded)} -> {verdict}")
        self.row("GRADED", line)
        os.makedirs(self.out, exist_ok=True)
        with open(self._p("verdicts.txt"), "a", encoding="utf-8") as f:
            for l, t in self.rows:
                f.write(f"{l}|{t}\n")
        with open(self._p("grade.json"), "w", encoding="utf-8") as f:
            json.dump({"rows": self.rows, "verdict": verdict, "fails": fails, "ungraded": ungraded,
                       "clock_offset_s": self.offset.total_seconds(), "hold_build": self.hold_build,
                       "clock_ref": (self.ref_now.strftime(TS_FMT)[:-3] if self.ref_now else None),
                       "clock_ref_source": self.ref_src or None,
                       "guest_utc_offset_s": self.guest_tz.utcoffset(None).total_seconds(),
                       "guest_utc_offset_source": self.guest_tz_src or None}, f, indent=2)
        for l, t in self.rows:
            print(f"{l}|{t}")
        return 0 if verdict.startswith("PASS") else 1


# --------------------------------------------------------------------------------------------- recorders
def record_fire(out: str, labels: List[str], mode: str, attempt: int, text: str) -> int:
    """Parse toast-hold-fire.ps1 output (through run-as-user) into fires.jsonl rows, one per FIRE step, in order.
    Rows are appended ONLY for steps that produced a FIRED line (a toast exists in the guest); an attempt with no
    FIRED line at all is reported and NOT recorded, so the harness's retry can stand in for it."""
    steps: Dict[int, dict] = {}
    cur = None
    for line in text.splitlines():
        line = line.rstrip("\r")
        m = re.match(r"THF step=(\d+) kind=(\w+) t0=(\S+ \S+) args=(.*)$", line)
        if m:
            cur = int(m.group(1))
            steps[cur] = {"kind": m.group(2), "t0": m.group(3), "args": m.group(4), "lines": []}
            continue
        m = re.match(r"THF step=(\d+) rc=(-?\d+) t1=(\S+ \S+)$", line)
        if m and int(m.group(1)) in steps:
            steps[int(m.group(1))]["rc"] = int(m.group(2))
            steps[int(m.group(1))]["t1"] = m.group(3)
            cur = None
            continue
        if cur is not None:
            steps[cur]["lines"].append(line)
    fires = [s for k, s in sorted(steps.items()) if s["kind"] == "fire"]
    rows = []
    for i, s in enumerate(fires):
        fired = next((ln for ln in s["lines"] if ln.startswith("FIRED method=")), None)
        kv = dict(KV_RE.findall(fired)) if fired else {}
        argv = s["args"].split("+")
        slug = argv[argv.index("--title") + 1] if "--title" in argv and argv.index("--title") + 1 < len(argv) else ""
        label = labels[i] if i < len(labels) else f"EXTRA{i}"
        rows.append({"label": label, "slug": slug, "aumid": kv.get("aumid", ""), "cls": kv.get("class", ""),
                     "tag": kv.get("tag", ""), "payload_sha256": kv.get("payload_sha256", ""),
                     "t0": s["t0"], "t1": s.get("t1"), "rc": s.get("rc"), "fired": fired is not None,
                     "mode": mode, "attempt": attempt,
                     "error": next((ln for ln in s["lines"] if ln.startswith("ERROR")), None)})
    nfired = sum(1 for r in rows if r["fired"])
    if nfired:
        with open(os.path.join(out, "fires.jsonl"), "a", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
    print(f"RECORDED fired={nfired} expected={len(labels)} steps={len(fires)} slugs={','.join(r['slug'] for r in rows)}"
          + (" rc=" + ",".join(str(r['rc']) for r in rows) if rows else ""))
    return 0 if nfired == len(labels) and len(fires) == len(labels) else 1


def decode_pull(out: str, pullfile: str) -> int:
    with open(pullfile, encoding="utf-8", errors="replace") as f:
        lines = [ln.rstrip("\r\n") for ln in f]
    now = None
    guest_tz = None
    blocks: Dict[str, dict] = {}
    cur = None
    for ln in lines:
        if ln.startswith("THC now="):
            now = ln[len("THC now="):].strip()
            # `THC now=<ts>` in pull mode, `THC now=<ts> tz=<offset>` in where mode (toast-hold-collect.ps1):
            # keep them apart, because the suffixed shape used to make parse_ts raise and the grader then
            # answered the question with THIS process's clock instead of saying it had no reference.
            mtz = re.match(r"^(.*?)\s+tz=(\S+)$", now)
            if mtz:
                now, guest_tz = mtz.group(1), mtz.group(2)
        m = re.match(r"THC PULL name=(\w+) lines=(\d+) bytes=(\d+) sha256=([0-9a-f]{64}) b64lines=(\d+)", ln)
        if m:
            cur = m.group(1)
            blocks[cur] = {"lines": int(m.group(2)), "bytes": int(m.group(3)), "sha": m.group(4), "b64n": int(m.group(5)), "b64": []}
            continue
        if ln.startswith("THC B|") and cur:
            blocks[cur]["b64"].append(ln[len("THC B|"):])
            continue
        m = re.match(r"THC PULLEND name=(\w+) b64lines=(\d+)", ln)
        if m:
            if cur == m.group(1):
                blocks[cur]["end_n"] = int(m.group(2))
            cur = None
    rc = 0
    for name in ("agent", "bridge"):
        b = blocks.get(name)
        if not b:
            print(f"DECODE {name}: MISSING block"); rc = 1; continue
        if len(b["b64"]) != b["b64n"] or b.get("end_n") != b["b64n"]:
            print(f"DECODE {name}: base64 line count {len(b['b64'])} != announced {b['b64n']} / end {b.get('end_n')} - TRUNCATED transfer"); rc = 1; continue
        try:
            data = base64.b64decode("".join(b["b64"]), validate=True)
        except (ValueError, base64.binascii.Error) as e:
            print(f"DECODE {name}: base64 invalid ({e})"); rc = 1; continue
        if len(data) != b["bytes"] or hashlib.sha256(data).hexdigest() != b["sha"]:
            print(f"DECODE {name}: bytes/sha mismatch ({len(data)} vs {b['bytes']})"); rc = 1; continue
        text = data.decode("utf-8", errors="replace")
        n = len(text.split("\n")) if text else 0
        if n != b["lines"] and not (b["lines"] == 0 and text == ""):
            print(f"DECODE {name}: {n} lines decoded, {b['lines']} announced"); rc = 1; continue
        with open(os.path.join(out, f"{name}.log"), "w", encoding="utf-8") as f:
            f.write(text + ("\n" if text and not text.endswith("\n") else ""))
        print(f"DECODE {name}: OK lines={b['lines']} bytes={b['bytes']} sha256={b['sha'][:12]}")
    if now:
        mp = os.path.join(out, "meta.json")
        try:
            with open(mp, encoding="utf-8") as f:
                meta = json.load(f)
        except (OSError, ValueError):
            meta = {}
        meta["pull_now"] = now
        if guest_tz:
            meta["guest_utc_offset"] = guest_tz
        with open(mp, "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2)
        print(f"DECODE now: OK {now}" + (f" tz={guest_tz}" if guest_tz else ""))
    else:
        # bridge.log has no dates, so this stamp IS the date. Losing it does not break the transfer the
        # counts and the hash verify, which is exactly why it has to be said here: without it the grader
        # has to date the bridge from a secondary stamp and the run does not close (CLOCK-REF).
        print("DECODE now: MISSING - the pull carried no `THC now=` stamp; bridge.log's date has no primary source")
    return rc


# --------------------------------------------------------------------------------------------- self-test
class Fx:
    """A synthetic evidence directory: agent/bridge lines are written with explicit guest-local times; the agent
    clock is offset by +1 h to prove the probe-derived offset is applied."""
    AGENT_OFF = dt.timedelta(hours=1)

    def __init__(self, hold_build: int, base: Optional[dt.datetime] = None):
        self.d = tempfile.mkdtemp(prefix="thgrade-")
        self.hold = hold_build
        self.agent: List[Tuple[dt.datetime, str]] = []
        self.bridge: List[Tuple[dt.datetime, str]] = []
        self.fires: List[dict] = []
        self.waits: List[dict] = []
        # The guest's wall clock at the fixture's t=0. A caller passes one to put the run at a chosen place on
        # the guest's clock (tools/tests/toasthold-grade-clock-selftest.sh: a skew against the host, a midnight).
        self.base = base or dt.datetime(2026, 10, 6, 12, 0, 0)
        self.guest_tz_txt = "00:00:00"            # what where.txt records as the guest's offset
        # the probe window: charmap at 11:59:50
        self.sync_hwnd = "7a0e2"
        ts = self.t(-10.0)
        self.sync = f"THC sync t_start={self.fmt(ts)} t_seen={self.fmt(self.t(-9.4))} hwnd=0x{self.sync_hwnd} pid=4242\nTHC sync t_close={self.fmt(self.t(-7.9))} t_closed={self.fmt(self.t(-7.2))}\n"
        self.a(-9.6, f"QGAPROTO,msg=CREATE,hwnd=0x{self.sync_hwnd},x=10,y=10,w=600,h=400,ovr=0,style=0x14cf0000,ex=0x00000100")
        self.a(-9.5, f"QGAPROTO,msg=MAP,hwnd=0x{self.sync_hwnd},ovr=0,transient=0x0,style=0x14cf0000,ex=0x00000100,vis=1,w=600,h=400")
        self.a(-7.8, f"Unmapping window 0x{self.sync_hwnd}")
        self.a(-7.7, f"QGAPROTO,msg=DESTROY,hwnd=0x{self.sync_hwnd}")
        if hold_build == 1:
            self.a(-60, "QGATOASTHOLD gate: ACTIVE (bridge gate on, ToastHoldDisable=0, UIA worker up, IPC up) - a toast banner is mapped only after its verdict")
        self.b(-50, "BRIDGE armed allow=[QubesToastfire.ComActivator]")
        self.b(-49, "connected (server version 1.0)")
        if hold_build == 1:
            self.b(-49, "HOLD records live (32 slots) - the agent holds each toast's banner until its record's verdict")
        self.nid = 100

    def t(self, s: float) -> dt.datetime:
        return self.base + dt.timedelta(seconds=s)

    @staticmethod
    def fmt(t: dt.datetime) -> str:
        return t.strftime(TS_FMT)[:-3]

    def a(self, s: float, msg: str):
        self.agent.append((self.t(s) + self.AGENT_OFF, msg))

    def b(self, s: float, msg: str):
        self.bridge.append((self.t(s), msg))

    def fire(self, label: str, s: float, cls="informational", aumid="QubesToastfire.StartShortcut", mode="seamless", fired=True):
        slug = f"THT-abc123-{label}-t1"
        self.fires.append({"label": label, "slug": slug, "aumid": aumid, "cls": cls, "tag": label, "payload_sha256": "00",
                           "t0": self.fmt(self.t(s)), "t1": self.fmt(self.t(s + 0.4)), "rc": 0, "fired": fired, "mode": mode, "attempt": 1})
        return slug

    def hold_pub(self, s: float, slug: str, verdict: str, sender="toastfire-QubesToastfire.StartShortcut", msg="demo body") -> Tuple[str, str]:
        self.nid += 1
        nid = str(self.nid)
        ident = ti_ident(sender, slug, msg)
        self.b(s, f"HOLD id={nid} seq={self.nid - 100} verdict={verdict} ident={ident['c']:016x} s={ident['s']:016x} t={ident['t']:016x} m={ident['m']:016x} flags=0x0")
        return nid, "%016x" % ident["c"]

    def write(self) -> str:
        with open(os.path.join(self.d, "agent.log"), "w", encoding="utf-8") as f:
            for t, msg in sorted(self.agent, key=lambda x: x[0]):
                f.write(f"[{t.strftime('%Y%m%d.%H%M%S.%f')[:-3]}-1234-5678] gui-agent: {msg}\n")
        with open(os.path.join(self.d, "bridge.log"), "w", encoding="utf-8") as f:
            for t, msg in sorted(self.bridge, key=lambda x: x[0]):
                # THE LEVEL THE REAL WRITER EMITS. qtb_shared.h's BLog prefixes every bridge line
                # with "[INFO] " (BLogW/BLogE for W/E), and this fixture wrote the PRE-PREFIX shape -
                # so the selftest stayed CLEAN while BRIDGE_RE captured "[INFO] connected (server
                # version 1.0)" as the message and every startswith() in parse_bridge missed.
                # MEASURED 2026-10-16: zero events parsed from a real 470-line bridge.log, 12 of 21
                # rows ungraded, and a HOLD-IPC "FAIL" about a line present in that same file.
                # A fixture has to come from a CAPTURE, not from a memory of the format.
                f.write(f"{t.strftime('%H:%M:%S')} [INFO] {msg}\r\n")
        with open(os.path.join(self.d, "fires.jsonl"), "w", encoding="utf-8") as f:
            for r in self.fires:
                f.write(json.dumps(r) + "\n")
        with open(os.path.join(self.d, "waits.jsonl"), "w", encoding="utf-8") as f:
            for r in self.waits:
                f.write(json.dumps(r) + "\n")
        with open(os.path.join(self.d, "sync.txt"), "w", encoding="utf-8") as f:
            f.write(self.sync)
        # where.txt AS THE HARNESS WRITES IT (toast-hold-test.sh: `printf '%s\n' "$where" > "$OUT/where.txt"`),
        # carrying the guest's own UTC offset. The real line, win11r-thold 2026-10-06, was
        #   THC now=2026-10-06 19:11:39.705 tz=00:00:00      while this qube's `date` read 16:11:38.
        with open(os.path.join(self.d, "where.txt"), "w", encoding="utf-8") as f:
            f.write(f"THC where=C:\\Users\\user\\Documents\\QubesIncoming\\win-idd-mgmt\n"
                    f"THC logdir=Q:\\Qubes Logs agentlog=gui-agent-20261006-191122-1512.log agentlines=2512\n"
                    f"THC bridgelog=Q:\\Qubes Logs\\bridge.log exists=1 bridgelines=470\n"
                    f"THC now={self.fmt(self.t(-20))} tz={self.guest_tz_txt}\n")
        with open(os.path.join(self.d, "meta.json"), "w", encoding="utf-8") as f:
            json.dump({"hold_build": self.hold, "run_id": "selftest", "package_version": "4.3.35+agent.selftest",
                       "driver_repo_commit": "deadbeef", "subject": "fixture", "pull_now": self.fmt(self.t(600))}, f)
        return self.d


def _grade_quiet(d: str) -> Grader:
    g = Grader(d)
    real = sys.stdout
    sys.stdout = open(os.devnull, "w")
    try:
        g.grade()
    finally:
        sys.stdout.close()
        sys.stdout = real
    return g


def _row(g: Grader, label: str) -> str:
    return next((t for (l, t) in g.rows if l == label), "MISSING")


def selftest() -> int:
    fails = 0

    def check(name: str, cond: bool, detail: str = ""):
        nonlocal fails
        print(f"{'ok  ' if cond else 'FAIL'} {name}{(' - ' + detail) if detail else ''}")
        if not cond:
            fails += 1

    # 1. the identity hash port against the gcc-compiled header
    for sender, title, msg, es, et, em, ec in HASH_VECTORS:
        i = ti_ident(sender, title, msg)
        got = ("%016x" % i["s"], "%016x" % i["t"], "%016x" % i["m"], "%016x" % i["c"])
        check(f"hash vector {title!r}", got == (es, et, em, ec), f"got {got}")

    # 2. hold build: one banner window, a toast per class
    H = "4038e"

    def hold_case(name, expect_cls, build):
        fx = Fx(1)
        build(fx)
        g = _grade_quiet(fx.write())
        r = _row(g, name)
        cls = r.split(" ", 1)[1].split(" ", 1)[0] if " " in r else r
        return g, r, cls

    # OK-BRIDGED: hold -> suppress on the record; FWD ok=1; never mapped
    def ok_bridged(fx):
        s = fx.fire("S1a", 0)
        fx.a(0.8, f"QGAPROTO,msg=CREATE,hwnd=0x{H},x=1000,y=800,w=396,h=152,ovr=1,style=0x96000000,ex=0x08200088")
        fx.a(0.8, f"QGAHELDDEFER hwnd=0x{H} class={BANNER_CLASS} w=396 h=152 t=1 slicefed=1 brokerslot=0")
        fx.a(0.9, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-identity ident=0000000000000000 s=0000000000000000 t=0000000000000000 m=0000000000000000 bridgeUp=1 (banner withheld)")
        nid, c = fx.hold_pub(1, s, "pending")
        fx.b(2, f"HOLD id={nid} verdict=bridge (classifier, was pending)")
        fx.a(2.1, f"QGATOASTHOLD hwnd=0x{H} state=suppress ident={c} id={nid} verdict=bridge held_ms=1200 (forwarded to dom0)")
        fx.b(3, f"FWD_RTT guest_id={nid} seq=1 ms=9 ok=1")
        fx.b(3, f"SENT id={nid} app='toastfire' title='{s}': OK")
        fx.b(3, f"HOLD id={nid} verdict=forwarded")
    g, r, cls = hold_case("S1a", "OK-BRIDGED", ok_bridged)
    check("hold OK-BRIDGED", cls == "OK-BRIDGED" and r.startswith("PASS"), r[:120])
    check("hold CLOCK offset applied (+1 h agent clock)", _row(g, "CLOCK").startswith("PASS") and abs(g.offset.total_seconds() - 3600) < 1, _row(g, "CLOCK")[:100])
    check("hold run verdict PASS", _row(g, "GRADED").endswith("-> PASS"), _row(g, "GRADED")[-60:])

    # OK-WINDOW: verdict window at 1.3 s -> show -> MAP
    def ok_window(fx):
        s = fx.fire("S2", 0, cls="realchoice")
        fx.a(0.8, f"QGAHELDDEFER hwnd=0x{H} class={BANNER_CLASS} w=396 h=193 t=1 slicefed=1 brokerslot=0")
        fx.a(0.9, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-record ident=0000000000000000 s=0 t=0 m=0 bridgeUp=1 (x)")
        nid, c = fx.hold_pub(1, s, "pending")
        fx.b(2, f"HOLD id={nid} verdict=window (classifier, was pending)")
        fx.b(2, f"skip id={nid} aumid=QubesToastfire.StartShortcut (window path; classifier verdict)")
        fx.a(2.2, f"QGATOASTHOLD hwnd=0x{H} state=show ident={c} id={nid} held_ms=1300 (verdict=window: the banner is the toast)")
        fx.a(2.3, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x96000000,ex=0x08200088,vis=1,w=396,h=193")
    g, r, cls = hold_case("S2", "OK-WINDOW", ok_window)
    check("hold OK-WINDOW", cls == "OK-WINDOW" and r.startswith("PASS"), r[:120])

    # LATE-WINDOW: the same but the MAP comes 4.1 s after the examination
    def late_window(fx):
        s = fx.fire("S2", 0, cls="realchoice")
        fx.a(0.9, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-record ident=0000000000000000 s=0 t=0 m=0 bridgeUp=1 (x)")
        nid, c = fx.hold_pub(1, s, "pending")
        fx.b(4, f"HOLD id={nid} verdict=window (classifier, was pending)")
        fx.b(4, f"skip id={nid} aumid=QubesToastfire.StartShortcut (window path; classifier verdict)")
        fx.a(5.0, f"QGATOASTHOLDLATE hwnd=0x{H} mapped FAIL-OPEN after 4100 ms: reason=verdict-pending ident={c} s=0 t={title_hash_hex(s)} m=0 id={nid} lastRead=ok bridgeUp=1 records=1 - x")
        fx.a(5.0, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x0,ex=0x0,vis=1,w=396,h=193")
    g, r, cls = hold_case("S2", "LATE-WINDOW", late_window)
    check("hold LATE-WINDOW (bound 3500 ms)", cls == "LATE-WINDOW" and r.startswith("FAIL"), r[:120])

    # DOUBLE (full): forwarded, and the banner mapped by a no-record fail-open
    def double_full(fx):
        s = fx.fire("S1a", 0)
        fx.a(0.9, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-record ident=0000000000000000 s=0 t=0 m=0 bridgeUp=1 (x)")
        nid, c = fx.hold_pub(1, s, "pending")
        fx.b(2, f"HOLD id={nid} verdict=bridge (classifier, was pending)")
        fx.b(3, f"FWD_RTT guest_id={nid} seq=1 ms=9 ok=1")
        fx.b(3, f"HOLD id={nid} verdict=forwarded")
        fx.a(3.95, f"QGATOASTHOLDLATE hwnd=0x{H} mapped FAIL-OPEN after 3050 ms: reason=no-record ident=1 s=2 t={title_hash_hex(s)} m=3 id=0 lastRead=ok bridgeUp=1 records=1 - x")
        fx.a(3.96, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x0,ex=0x0,vis=1,w=396,h=152")
    g, r, cls = hold_case("S1a", "DOUBLE", double_full)
    check("hold DOUBLE (full, via no-record fail-open)", cls == "DOUBLE" and r.startswith("FAIL") and "double=full" in r, r[:140])

    # DOUBLE (flash): a shown window-path banner is still mapped when the bridged toast's content arrives in place
    def double_flash(fx):
        s = fx.fire("S3ii-2", 0)
        fx.a(-3.0, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-record ident=0000000000000000 s=0 t=0 m=0 bridgeUp=1 (x)")
        fx.a(-2.0, f"QGATOASTHOLD hwnd=0x{H} state=show ident=aaaaaaaaaaaaaaaa id=77 held_ms=900 (verdict=window)")
        fx.a(-1.9, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x0,ex=0x0,vis=1,w=396,h=152")
        nid, c = fx.hold_pub(1, s, "bridge")
        fx.a(5.0, f"QGATOASTHOLD hwnd=0x{H} content changed in place: new ident={c} s=1 t={title_hash_hex(s)} m=2 - held again")
        fx.a(5.05, f"QGATOASTHOLD hwnd=0x{H} state=suppress ident={c} id={nid} verdict=bridge held_ms=50 (forwarded to dom0)")
        # main.c:10058, not `Unmapping window` (LogDebug, absent at the shipped level - see is_unmap)
        fx.a(5.3, f"UpdateWindowData: QGATOASTHOLD hwnd=0x{H} unmapped a MAPPED banner: the hold governs it again")
        fx.b(2, f"FWD_RTT guest_id={nid} seq=2 ms=11 ok=1")
        fx.b(2, f"HOLD id={nid} verdict=forwarded")
    g, r, cls = hold_case("S3ii-2", "DOUBLE", double_flash)
    check("hold DOUBLE (flash: mapped when the content arrived)", cls == "DOUBLE" and "double=flash" in r, r[:140])

    # the pre-emption working: the shown banner is unmapped BEFORE the bridged content arrives -> OK-BRIDGED
    def preempt_ok(fx):
        s = fx.fire("S3ii-2", 0)
        fx.a(-2.0, f"QGATOASTHOLD hwnd=0x{H} state=show ident=aaaaaaaaaaaaaaaa id=77 held_ms=900 (verdict=window)")
        fx.a(-1.9, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x0,ex=0x0,vis=1,w=396,h=152")
        nid, c = fx.hold_pub(1, s, "bridge")
        fx.a(1.2, f"QGATOASTPREEMPT hwnd=0x{H} unmapped: a bridge-bound or still-pending toast (id={nid}) is queued behind the displayed banner")
        # WHAT THE PRODUCT WRITES AT LogLevel 3. This fixture used to hand-write `Unmapping window 0x..`
        # (send.c, LogDebug since 2026-10-08) and so passed on a capture no shipped guest can produce -
        # which is why DOUBLE on a working pre-emption survived to the rig. See is_unmap().
        fx.a(1.2, f"UpdateWindowData: QGATOASTHOLD hwnd=0x{H} unmapped a MAPPED banner: the hold governs it again")
        fx.a(5.0, f"QGATOASTHOLD hwnd=0x{H} content changed in place: new ident={c} s=1 t={title_hash_hex(s)} m=2 - held again")
        fx.a(5.05, f"QGATOASTHOLD hwnd=0x{H} state=suppress ident={c} id={nid} verdict=bridge held_ms=50 (forwarded to dom0)")
        fx.b(2, f"FWD_RTT guest_id={nid} seq=2 ms=11 ok=1")
        fx.b(2, f"HOLD id={nid} verdict=forwarded")
    g, r, cls = hold_case("S3ii-2", "OK-BRIDGED", preempt_ok)
    check("hold pre-emption before the swap -> OK-BRIDGED", cls == "OK-BRIDGED" and r.startswith("PASS"), r[:140])

    # THE SHARED BANNER WINDOW (measured 2026-10-04 and in run 37499041570, 2026-10-06): the shell shows queued banners one at
    # a time, FIFO, in ONE window; a second toast arrives in place ~6.8 s after the first. Each toast is graded on its own
    # time in the window - from its own held start (decision time minus held_ms) to the next toast's arrival.
    def shared_bridge_then_window(fx):
        s1 = fx.fire("S3i-1", 0)
        s2 = fx.fire("S3i-2", 0.7, cls="realchoice")
        fx.a(0.8, f"QGAPROTO,msg=CREATE,hwnd=0x{H},x=5120,y=1392,w=396,h=152,ovr=1,style=0x94000000,ex=0x00200008")
        fx.a(0.8, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-identity ident=0000000000000000 s=0000000000000000 t=0000000000000000 m=0000000000000000 bridgeUp=1 (banner withheld)")
        fx.a(0.8, f"QGAHELDDEFER hwnd=0x{H} class={BANNER_CLASS} w=396 h=152 t=1 slicefed=1 brokerslot=1")
        n1, c1 = fx.hold_pub(1.0, s1, "bridge")
        n2, c2 = fx.hold_pub(1.6, s2, "window")
        fx.a(1.144, f"QGATOASTHOLD hwnd=0x{H} state=suppress ident={c1} id={n1} verdict=bridge held_ms=344 (forwarded to dom0)")
        fx.b(2, f"FWD_RTT guest_id={n1} seq=1 ms=9 ok=1")
        fx.b(2, f"HOLD id={n1} verdict=forwarded")
        fx.b(2, f"skip id={n2} aumid=QubesToastfire.StartShortcut (window path; classifier verdict)")
        fx.a(7.606, f"QGATOASTHOLD hwnd=0x{H} state=show ident={c2} id={n2} held_ms=0 (verdict=window: the banner is the toast)")
        fx.a(7.606, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x94000000,ex=0x00200008,vis=1,w=364,h=109")
        fx.a(13.578, f"Unmapping window 0x{H}")
        fx.a(13.578, f"QGAPROTO,msg=DESTROY,hwnd=0x{H}")
    g, r, cls = hold_case("S3i-1", "OK-BRIDGED", shared_bridge_then_window)
    check("shared window: the bridged first toast is not charged with the second toast's MAP -> OK-BRIDGED",
          cls == "OK-BRIDGED" and r.startswith("PASS"), r[:170])
    r2 = _row(g, "S3i-2")
    check("shared window: the second toast is timed from its own arrival (held 0 ms), not the window's creation -> OK-WINDOW",
          r2.startswith("PASS OK-WINDOW"), r2[:170])

    # PRE-EMPTION OF A DISPLAYED WINDOW-PATH TOAST (run 37499041570, S3ii): shown, then unmapped 20 ms later because a
    # forwarded toast was queued behind it - the guest keeps showing it for seconds, dom0 does not: a flash and a lost
    # display (the owner's rule, ADR-toasts 10's Why: a flash is not fine). The queued toast itself is cleanly bridged.
    def window_then_preempted(fx):
        s1 = fx.fire("S3ii-1", 0, cls="realchoice")
        s2 = fx.fire("S3ii-2", 0.7)
        fx.a(0.8, f"QGAPROTO,msg=CREATE,hwnd=0x{H},x=5120,y=1392,w=396,h=152,ovr=1,style=0x94000000,ex=0x00200008")
        fx.a(0.8, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-identity ident=0000000000000000 s=0000000000000000 t=0000000000000000 m=0000000000000000 bridgeUp=1 (banner withheld)")
        fx.a(0.8, f"QGAHELDDEFER hwnd=0x{H} class={BANNER_CLASS} w=396 h=152 t=1 slicefed=1 brokerslot=1")
        n1, c1 = fx.hold_pub(0.9, s1, "window")
        fx.b(1, f"skip id={n1} aumid=QubesToastfire.StartShortcut (window path; classifier verdict)")
        fx.a(1.019, f"QGATOASTHOLD hwnd=0x{H} state=show ident={c1} id={n1} held_ms=219 (verdict=window: the banner is the toast)")
        fx.a(1.019, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x94000000,ex=0x00200008,vis=1,w=364,h=109")
        n2, c2 = fx.hold_pub(1.03, s2, "bridge")
        fx.a(1.039, f"QGATOASTPREEMPT hwnd=0x{H} unmapped: a bridge-bound or still-pending toast (id={n2}) is queued behind the displayed banner and would paint into this window in place; the displayed window-path banner loses the rest of its dom0 display")
        fx.a(1.039, f"Unmapping window 0x{H}")
        fx.b(2, f"FWD_RTT guest_id={n2} seq=2 ms=9 ok=1")
        fx.b(2, f"HOLD id={n2} verdict=forwarded")
        fx.a(13.254, f"Unmapping window 0x{H}")
        fx.a(13.256, f"QGAPROTO,msg=DESTROY,hwnd=0x{H}")
    g, r, cls = hold_case("S3ii-1", "PREEMPTED", window_then_preempted)
    check("a window-path toast withdrawn 20 ms after its MAP by a pre-emption -> PREEMPTED (FAIL)",
          cls == "PREEMPTED" and r.startswith("FAIL"), r[:200])
    r2 = _row(g, "S3ii-2")
    check("the bridged toast queued behind it, the window never re-mapped -> OK-BRIDGED", r2.startswith("PASS OK-BRIDGED"), r2[:170])

    # THE SAME CAPTURE WITH SWAP-EDGE GATING (ADR-toasts 10), on the measured timings of run 40407378739.
    # The pre-emption fires on the mere EXISTENCE of a newer unconsumed record (1.039), but the shared banner
    # window is not repainted until Windows actually shows that toast - which in that capture was 4.47 s
    # later. Rule 5 unmapped at 1.039 and the banner never came back: 680 ms of display. Gating holds the
    # window's frames instead, so the banner keeps its display until the queued toast genuinely takes the
    # window at 5.50, and the hold expires by its own 3 s bound at 4.045 (ungate and repaint - the repaint is
    # a no-op here, since nothing has changed yet, which is the point: an expired gate cannot freeze a window).
    #
    # TWO THINGS ARE ASSERTED. That a frame hold is not graded as a withdrawal, and - the sharper one - that
    # the toast queued behind the held frames is still OK-BRIDGED and NOT a DOUBLE. The banner window stays
    # MAPPED across the forward now, which under rule 5 it never did; what keeps it from being a double is
    # that dom0 is holding the previous toast's frame, so the forwarded toast is on screen exactly once.
    def window_then_frames_held(fx):
        s1 = fx.fire("S3ii-1", 0, cls="realchoice")
        s2 = fx.fire("S3ii-2", 0.7)
        fx.a(0.8, f"QGAPROTO,msg=CREATE,hwnd=0x{H},x=5120,y=1392,w=396,h=152,ovr=1,style=0x94000000,ex=0x00200008")
        fx.a(0.8, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-identity ident=0000000000000000 s=0000000000000000 t=0000000000000000 m=0000000000000000 bridgeUp=1 (banner withheld)")
        fx.a(0.8, f"QGAHELDDEFER hwnd=0x{H} class={BANNER_CLASS} w=396 h=152 t=1 slicefed=1 brokerslot=1")
        n1, c1 = fx.hold_pub(0.9, s1, "window")
        fx.b(1, f"skip id={n1} aumid=QubesToastfire.StartShortcut (window path; classifier verdict)")
        fx.a(1.019, f"QGATOASTHOLD hwnd=0x{H} state=show ident={c1} id={n1} held_ms=219 (verdict=window: the banner is the toast)")
        fx.a(1.019, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x94000000,ex=0x00200008,vis=1,w=364,h=109")
        n2, c2 = fx.hold_pub(1.03, s2, "bridge")
        fx.a(1.039, f"QGATOASTPREEMPT hwnd=0x{H} frames held: a bridge-bound or still-pending toast (id={n2}) is queued behind the displayed banner and would paint into this window in place; the banner stays mapped showing the toast dom0 was told it carries")
        fx.a(1.039, f"QGATOASTGATE hwnd=0x{H} frames gated reason=preempt: a newer toast's record is queued behind this shown banner")
        fx.b(2, f"FWD_RTT guest_id={n2} seq=2 ms=9 ok=1")
        fx.b(2, f"HOLD id={n2} verdict=forwarded")
        # the 3 s bound lapses with the swap still pending: ungate and repaint (a no-op repaint - nothing
        # has changed yet), which is what keeps an expired gate from freezing a live window
        fx.a(4.045, f"QGATOASTPREEMPT hwnd=0x{H} frames resumed after 3006 ms: the queued toast resolved to window (or its window passed)")
        fx.a(4.045, f"QGATOASTGATE hwnd=0x{H} frames resumed: the window carries a window-path toast again and has been repainted in full")
        # ...and the swap itself, 1.5 s later: the hook thread closes the gate before the tracking pass
        # has decided anything, which is the only reason the forwarded toast below is not a double
        fx.a(5.495, f"QGATOASTGATE hwnd=0x{H} frames gated at the swap edge: this shown banner's window changed")
        fx.a(5.50, f"QGATOASTHOLD hwnd=0x{H} content changed in place: new ident={c2} s=1 t={title_hash_hex(s2)} m=2 - held again")
        fx.a(5.52, f"QGATOASTHOLD hwnd=0x{H} state=suppress ident={c2} id={n2} verdict=bridge held_ms=20 (forwarded to dom0)")
        fx.a(5.52, f"Unmapping window 0x{H}")
        fx.a(13.256, f"QGAPROTO,msg=DESTROY,hwnd=0x{H}")
    g, r, cls = hold_case("S3ii-1", "OK-WINDOW", window_then_frames_held)
    check("frames HELD instead of the banner unmapped -> the displayed toast keeps its display, not PREEMPTED",
          cls != "PREEMPTED" and r.startswith("PASS"), f"cls={cls} {r[:170]}")
    r2 = _row(g, "S3ii-2")
    check("and the toast forwarded while the frames were held is NOT a double -> OK-BRIDGED",
          r2.startswith("PASS OK-BRIDGED"), r2[:170])

    # RE-MAP of a banner the hold unmapped after showing it: the buffer must be re-announced first (REMAP-DUMP)
    def remap_case(with_dump):
        def build(fx):
            s1 = fx.fire("S3iii-1", 0, cls="realchoice")
            s2 = fx.fire("S3iii-2", 0.7, cls="realchoice")
            fx.a(0.8, f"QGAPROTO,msg=CREATE,hwnd=0x{H},x=5120,y=1392,w=396,h=152,ovr=1,style=0x94000000,ex=0x00200008")
            fx.a(0.8, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-identity ident=0000000000000000 s=0000000000000000 t=0000000000000000 m=0000000000000000 bridgeUp=1 (banner withheld)")
            n1, c1 = fx.hold_pub(0.9, s1, "window")
            fx.b(1, f"skip id={n1} aumid=Windows.SystemToast.SecurityAndMaintenance (window path; window-only app - its click is its action)")
            fx.a(1.0, f"QGATOASTHOLD hwnd=0x{H} state=show ident={c1} id={n1} held_ms=200 (verdict=window: the banner is the toast)")
            fx.a(1.0, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x94000000,ex=0x00200008,vis=1,w=364,h=109")
            n2, c2 = fx.hold_pub(1.6, s2, "window")
            fx.b(2, f"skip id={n2} aumid=Windows.SystemToast.SecurityAndMaintenance (window path; window-only app - its click is its action)")
            fx.a(7.5, f"QGATOASTHOLD hwnd=0x{H} content changed in place: new ident={c2} s=1 t={title_hash_hex(s2)} m=2 - held again")
            fx.a(7.5, f"Unmapping window 0x{H}")
            fx.a(7.5, f"QGATOASTHOLD hwnd=0x{H} unmapped a MAPPED banner: the hold governs it again (re-mapped when it says show)")
            fx.a(7.7, f"QGATOASTHOLD hwnd=0x{H} state=show ident={c2} id={n2} held_ms=200 (verdict=window: the banner is the toast)")
            if with_dump:
                fx.a(7.7, f"QGATOASTHOLD hwnd=0x{H} re-announced its buffer before the re-map")
            fx.a(7.7, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x94000000,ex=0x00200008,vis=1,w=364,h=109")
            fx.a(13.7, f"Unmapping window 0x{H}")
            fx.a(13.7, f"QGAPROTO,msg=DESTROY,hwnd=0x{H}")
        return build
    g, r, cls = hold_case("S3iii-2", "OK-WINDOW", remap_case(True))
    check("window->window pair, buffer re-announced before the re-map -> REMAP-DUMP PASS", _row(g, "REMAP-DUMP").startswith("PASS"), _row(g, "REMAP-DUMP")[:120])
    check("window->window pair: the second toast OK-WINDOW", r.startswith("PASS OK-WINDOW"), r[:120])
    g, r, cls = hold_case("S3iii-2", "OK-WINDOW", remap_case(False))
    check("window->window pair re-mapped WITHOUT the re-announce -> REMAP-DUMP FAIL", _row(g, "REMAP-DUMP").startswith("FAIL"), _row(g, "REMAP-DUMP")[:120])

    # NON-SEAMLESS SIZE: the 2026-10-06 regression shape (shrunk, then re-grown to 5120x1384 by the WM clamp) must FAIL
    def ns_case(regrow):
        def build(fx):
            fx.a(-30, "SendWindowCreateInternal: QGAPROTO,msg=CREATE,hwnd=0x0,x=0,y=0,w=5120,h=1440,ovr=0,style=0x00000000,ex=0x00000000")
            s = fx.fire("S1a", 0)
            fx.a(0.8, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-identity ident=0000000000000000 s=0000000000000000 t=0000000000000000 m=0000000000000000 bridgeUp=1 (x)")
            nid, c = fx.hold_pub(1, s, "bridge")
            fx.a(1.2, f"QGATOASTHOLD hwnd=0x{H} state=suppress ident={c} id={nid} verdict=bridge held_ms=400 (x)")
            fx.b(2, f"FWD_RTT guest_id={nid} seq=1 ms=9 ok=1")
            fx.a(40, "SetVideoMode: RESREQ 1280x800 src=non-seamless-entry")
            fx.a(40.5, "SetVideoModeInternal: New resolution: 1280 x 800")
            if not regrow:
                fx.a(41, "SetSeamlessMode: QGAFSFLASH window 0 announced at 1280x800 before the map")
            fx.a(41.2, "SetSeamlessMode: Seamless mode changed to 0")
            if regrow:
                fx.a(43, "SetVideoMode: RESREQ 5120x1384 src=dom0")
                fx.a(43.2, "SetVideoModeInternal: New resolution: 5120 x 1384")
            fx.a(129, "SendWindowUnmap: Unmapping window 0x0")
            fx.a(130, "SetVideoModeInternal: New resolution: 5120 x 1440")
            fx.a(131, "SetSeamlessMode: Seamless mode changed to 1")
        return build
    g, r, cls = hold_case("S1a", "OK-BRIDGED", ns_case(True))
    check("non-seamless desktop re-grown to 5120x1384 -> NS-SIZE FAIL", _row(g, "NS-SIZE").startswith("FAIL"), _row(g, "NS-SIZE")[:120])
    g, r, cls = hold_case("S1a", "OK-BRIDGED", ns_case(False))
    check("non-seamless desktop kept at 1280x800 -> NS-SIZE PASS", _row(g, "NS-SIZE").startswith("PASS"), _row(g, "NS-SIZE")[:120])

    # LOST: window verdict, examined, never mapped
    def lost(fx):
        s = fx.fire("S2", 0, cls="realchoice")
        fx.a(0.9, f"QGATOASTHOLD hwnd=0x{H} state=hold reason=no-record ident=0000000000000000 s=0 t=0 m=0 bridgeUp=1 (x)")
        nid, c = fx.hold_pub(1, s, "pending")
        fx.b(2, f"HOLD id={nid} verdict=window (classifier, was pending)")
        fx.b(2, f"skip id={nid} aumid=QubesToastfire.StartShortcut (window path; classifier verdict)")
        fx.a(2.2, f"QGATOASTHOLD hwnd=0x{H} state=suppress ident={c} id={nid} verdict=bridge held_ms=1300 (x)")
    g, r, cls = hold_case("S2", "LOST", lost)
    check("hold LOST (examined, never mapped)", cls == "LOST" and r.startswith("FAIL"), r[:120])

    # NO-BANNER: nothing on the agent side, nothing seen in the guest -> ungraded, never a pass
    def no_banner(fx):
        s = fx.fire("S2", 0, cls="realchoice")
        nid, c = fx.hold_pub(1, s, "window")
        fx.b(2, f"skip id={nid} aumid=QubesToastfire.StartShortcut (window path; classifier verdict)")
    g, r, cls = hold_case("S2", "NO-BANNER", no_banner)
    check("hold NO-BANNER -> INSTRUMENT (not PASS, not LOST)", r.startswith("INSTRUMENT") and "NO-BANNER" in r, r[:120])

    # ... but a banner the harness SAW in the guest turns the same evidence into LOST
    def no_banner_but_seen(fx):
        no_banner(fx)
        fx.waits.append({"labels": ["S2"], "guest_banner_seen": True})
    g, r, cls = hold_case("S2", "LOST", no_banner_but_seen)
    check("hold guest-seen banner without agent evidence -> LOST", cls == "LOST" and r.startswith("FAIL"), r[:120])

    # not FIRED -> INSTRUMENT
    def not_fired(fx):
        fx.fire("S1a", 0, fired=False)
    g, r, cls = hold_case("S1a", "INSTRUMENT", not_fired)
    check("not FIRED -> INSTRUMENT row", r.startswith("INSTRUMENT"), r[:100])

    # no-identity fail-open -> run-level FAIL
    def noident(fx):
        ok_bridged(fx)
        fx.a(30.0, f"QGATOASTHOLDLATE hwnd=0x{H} mapped FAIL-OPEN after 3010 ms: reason=no-identity ident=0 s=0 t=0 m=0 id=0 lastRead=no-title bridgeUp=1 records=2 - x")
    g, r, cls = hold_case("S1a", "OK-BRIDGED", noident)
    check("no-identity fail-open -> IDENT-FAILOPEN FAIL", _row(g, "IDENT-FAILOPEN").startswith("FAIL"), _row(g, "IDENT-FAILOPEN")[:100])

    # clock probe without a CREATE -> INSTRUMENT, nothing graded
    fx = Fx(1); ok_bridged(fx)
    fx.agent = [(t, m) for (t, m) in fx.agent if "CREATE,hwnd=0x" + fx.sync_hwnd not in m]
    g = _grade_quiet(fx.write())
    check("probe CREATE absent -> CLOCK INSTRUMENT and S1a ungraded", _row(g, "CLOCK").startswith("INSTRUMENT") and _row(g, "S1a").startswith("INSTRUMENT"), _row(g, "CLOCK")[:100])

    # THE INSTANT bridge.log IS DATED FROM. The fixture's guest clock is 2026-10-06 and this process's is
    # not, so a grader that reaches for dt.datetime.now() dates the whole bridge log to TODAY and every
    # toast reads UNLISTED - no skewed zone needed to show it here. The same cases with a real 3 h phase
    # difference, and the direction in which the same error reads as PASS, are in
    # tools/tests/toasthold-grade-clock-selftest.sh, each seen to fail against the pre-fix file.
    def _meta_edit(d, mutate):
        with open(os.path.join(d, "meta.json"), encoding="utf-8") as f:
            m = json.load(f)
        mutate(m)
        with open(os.path.join(d, "meta.json"), "w", encoding="utf-8") as f:
            json.dump(m, f)
        return d

    def _cls(g, label):
        parts = _row(g, label).split(" ", 2)
        return parts[1] if len(parts) > 1 else "?"

    fx = Fx(1); ok_bridged(fx); GUEST_DAY = fx.base.date(); g_ref = _grade_quiet(fx.write())
    fx = Fx(1); ok_bridged(fx)
    g_lost = _grade_quiet(_meta_edit(fx.write(), lambda m: m.pop("pull_now", None)))
    check("pull stamp lost -> dated from the capture's other guest instants, class unchanged",
          _cls(g_lost, "S1a") == _cls(g_ref, "S1a") == "OK-BRIDGED", f"{_cls(g_lost, 'S1a')} vs {_cls(g_ref, 'S1a')}")
    # THE PROPERTY ITSELF, not a proxy for it: the DAY the dateless lines were given. A class can come
    # out right for the wrong reason - this process's clock LATER than the capture makes the window that
    # binds a record to its fire vacuously true, and then the row still reads OK-BRIDGED.
    for nm, gg in (("present", g_ref), ("lost", g_lost)):
        days = sorted({e.t.date() for e in gg.bridge})
        check(f"pull stamp {nm} -> bridge.log dated on the guest's day ({GUEST_DAY}), not this process's",
              days == [GUEST_DAY], f"{len(gg.bridge)} event(s) on {days}")
    check("pull stamp lost -> CLOCK-REF INSTRUMENT (a fallback is said out loud; the run does not close)",
          _row(g_lost, "CLOCK-REF").startswith("INSTRUMENT") and "absent" in _row(g_lost, "CLOCK-REF")
          and _row(g_lost, "GRADED").endswith("-> UNGRADED"), _row(g_lost, "CLOCK-REF")[:110])
    check("pull stamp present -> CLOCK-REF PASS naming it", _row(g_ref, "CLOCK-REF").startswith("PASS")
          and "pull_now" in _row(g_ref, "CLOCK-REF") and _row(g_ref, "GRADED").endswith("-> PASS"),
          _row(g_ref, "CLOCK-REF")[:110])
    # `THC now=<ts> tz=<offset>` is what the collector's `where` mode prints; that suffix used to make
    # strptime raise, and the swallowed exception read as "no reference" - i.e. the host clock, silently.
    fx = Fx(1); ok_bridged(fx)
    g_tz = _grade_quiet(_meta_edit(fx.write(), lambda m: m.__setitem__("pull_now", m["pull_now"] + " tz=03:00:00")))
    check("pull stamp with a tz= suffix is a stamp, not a parse failure",
          _row(g_tz, "CLOCK-REF").startswith("PASS") and _cls(g_tz, "S1a") == "OK-BRIDGED", _row(g_tz, "CLOCK-REF")[:110])
    # No instant anywhere in the capture: a refusal, not a guess.
    fx = Fx(1); ok_bridged(fx); d = _meta_edit(fx.write(), lambda m: m.pop("pull_now", None))
    open(os.path.join(d, "sync.txt"), "w").close()
    rows = [json.loads(l) for l in open(os.path.join(d, "fires.jsonl"), encoding="utf-8") if l.strip()]
    for r in rows:
        r["t0"] = r["t1"] = ""
    with open(os.path.join(d, "fires.jsonl"), "w", encoding="utf-8") as f:
        f.write("".join(json.dumps(r) + "\n" for r in rows))
    g_none = _grade_quiet(d)
    check("no guest instant at all -> CLOCK-REF INSTRUMENT and nothing graded",
          "no instant on the guest's clock" in _row(g_none, "CLOCK-REF") and _row(g_none, "GRADED").startswith("INSTRUMENT"),
          _row(g_none, "CLOCK-REF")[:130])
    try:
        parse_bridge(["16:32:22 [INFO] connected (server version 1.0)"], None)
        check("parse_bridge without a reference raises", False, "it returned events instead")
    except NoBridgeReference:
        check("parse_bridge without a reference raises NoBridgeReference", True)

    # hold gate INERT on a hold build -> FAIL
    fx = Fx(1); ok_bridged(fx)
    fx.agent = [(t, m) for (t, m) in fx.agent if "QGATOASTHOLD gate" not in m]
    fx.a(-60, "QGATOASTHOLD INERT with the bridge gate ON: uiaWorker=0 ipc=1 - every bridged toast will show TWICE on this run")
    g = _grade_quiet(fx.write())
    check("hold INERT -> HOLD-GATE FAIL", _row(g, "HOLD-GATE").startswith("FAIL"), _row(g, "HOLD-GATE")[:100])

    # 3. the CONTROL (pre-hold) build: the defect's predictions, and the detectors proven
    def control_all(fx):
        # S0 warm-up: forwarded + banner mapped -> DOUBLE
        s0 = fx.fire("S0", 0, aumid="QubesToastfire.Warmup")
        fx.a(0.7, f"QGAPROTO,msg=CREATE,hwnd=0x{H},x=1000,y=800,w=396,h=152,ovr=1,style=0x0,ex=0x0")
        fx.a(0.7, f"QGAHELDDEFER hwnd=0x{H} class={BANNER_CLASS} w=396 h=152 t=1 slicefed=1 brokerslot=0")
        fx.a(1.4, f"QGAHELDMAP hwnd=0x{H} class={BANNER_CLASS} w=396 h=152 held_ms=700 reason=crop menu=0 toast=1")
        fx.a(1.4, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x0,ex=0x0,vis=1,w=396,h=152")
        fx.b(2, f"FWD_RTT guest_id=201 seq=1 ms=9 ok=1")
        fx.b(2, f"SENT id=201 app='toastfire' title='{s0}': OK")
        fx.a(6.5, f"Unmapping window 0x{H}")
        # S1a: the same, from the main app -> DOUBLE
        s1 = fx.fire("S1a", 30)
        fx.a(31.4, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x0,ex=0x0,vis=1,w=396,h=152")
        fx.b(32, f"FWD_RTT guest_id=202 seq=2 ms=9 ok=1")
        fx.b(32, f"SENT id=202 app='toastfire' title='{s1}': OK")
        fx.a(36.5, f"Unmapping window 0x{H}")
        # S1b: ShowBanner=0 now -> no banner, forwarded -> OK-BRIDGED (informational on the control)
        s2 = fx.fire("S1b", 60)
        fx.b(62, f"FWD_RTT guest_id=203 seq=3 ms=9 ok=1")
        fx.b(62, f"SENT id=203 app='toastfire' title='{s2}': OK")
        # S2: real-choice -> skip (window path) and NO banner anywhere -> LOST
        fx.fire("S2", 90, cls="realchoice")
        fx.b(92, "skip id=204 aumid=QubesToastfire.StartShortcut (window path; classifier verdict)")
        # S4: allowlisted first toast -> DOUBLE
        s4 = fx.fire("S4", 120, aumid="QubesToastfire.ComActivator")
        fx.a(121.4, f"QGAPROTO,msg=MAP,hwnd=0x{H},ovr=1,transient=0x0,style=0x0,ex=0x0,vis=1,w=396,h=152")
        fx.b(122, f"FWD_RTT guest_id=205 seq=4 ms=9 ok=1")
        fx.b(122, f"SENT id=205 app='toastfire' title='{s4}': OK")
    fx = Fx(0); control_all(fx)
    g = _grade_quiet(fx.write())
    for lbl, want in (("S0", "DOUBLE"), ("S1a", "DOUBLE"), ("S2", "LOST")):
        r = _row(g, lbl)
        check(f"control {lbl} -> {want} (PASS: predicted)", r.startswith("PASS " + want), r[:100])
    check("control S1b informational OK-BRIDGED", _row(g, "S1b").startswith("INFO OK-BRIDGED"), _row(g, "S1b")[:100])
    check("control DETECTORS proven", _row(g, "DETECTORS").startswith("PASS"), _row(g, "DETECTORS")[:100])
    check("control run verdict PASS (defect reproduced)", "-> PASS" in _row(g, "GRADED"), _row(g, "GRADED")[-80:])

    # a control whose S1a did NOT double -> DETECTOR UNPROVEN, FAIL
    fx = Fx(0); control_all(fx)
    fx.agent = [(t, m) for (t, m) in fx.agent if not (m.startswith("QGAPROTO,msg=MAP") and (fx.base + dt.timedelta(seconds=31) + Fx.AGENT_OFF) <= t <= (fx.base + dt.timedelta(seconds=32) + Fx.AGENT_OFF))]
    g = _grade_quiet(fx.write())
    check("control S1a without a MAP -> FAIL + DETECTOR UNPROVEN", _row(g, "S1a").startswith("FAIL OK-BRIDGED") and _row(g, "DETECTORS").startswith("FAIL"), _row(g, "DETECTORS")[:100])

    # 4. non-seamless rows on the hold build
    def ns_ok(fx):
        s = fx.fire("S5a", 0, mode="nonseamless")
        nid, c = fx.hold_pub(1, s, "window")
        fx.b(1, f"skip id={nid} aumid=QubesToastfire.StartShortcut (window path; non-seamless mode)")
    g, r, cls = hold_case("S5a", "OK-WINDOW-NS", ns_ok)
    check("hold non-seamless window path -> OK-WINDOW-NS", r.startswith("PASS OK-WINDOW-NS"), r[:120])

    def ns_forwarded(fx):
        s = fx.fire("S5a", 0, mode="nonseamless")
        nid, c = fx.hold_pub(1, s, "bridge")
        fx.b(2, f"FWD_RTT guest_id={nid} seq=1 ms=9 ok=1")
        fx.b(2, f"HOLD id={nid} verdict=forwarded")
    g, r, cls = hold_case("S5a", "FORWARDED-NS", ns_forwarded)
    check("hold non-seamless forwarded -> FORWARDED-NS FAIL", r.startswith("FAIL FORWARDED-NS"), r[:120])

    # 5. the pull decoder refuses a truncated transfer
    d = tempfile.mkdtemp(prefix="thpull-")
    payload = "line one\nline two".encode()
    b64 = base64.b64encode(payload).decode()
    good = (f"THC now=2026-10-06 12:00:00.000\nTHC PULL name=agent lines=2 bytes={len(payload)} sha256={hashlib.sha256(payload).hexdigest()} b64lines=1\n"
            f"THC B|{b64}\nTHC PULLEND name=agent b64lines=1\n"
            f"THC PULL name=bridge lines=2 bytes={len(payload)} sha256={hashlib.sha256(payload).hexdigest()} b64lines=1\nTHC B|{b64}\nTHC PULLEND name=bridge b64lines=1\n")
    with open(os.path.join(d, "good.txt"), "w") as f:
        f.write(good)
    with open(os.path.join(d, "trunc.txt"), "w") as f:
        f.write(good.replace(f"THC B|{b64}\nTHC PULLEND name=bridge", "THC PULLEND name=bridge"))
    real = sys.stdout; sys.stdout = open(os.devnull, "w")
    try:
        rc_good = decode_pull(d, os.path.join(d, "good.txt"))
        rc_trunc = decode_pull(d, os.path.join(d, "trunc.txt"))
    finally:
        sys.stdout.close(); sys.stdout = real
    check("decode_pull accepts a complete transfer", rc_good == 0)
    check("decode_pull refuses a truncated transfer", rc_trunc != 0)

    # 6. the fire recorder: FIRED-confirmed rows only, labels in step order, usage error not a fire
    d2 = tempfile.mkdtemp(prefix="thfire-")
    wrapper_out = ("RUNASUSER lastresult=0\nUSEROUT_BEGIN\n"
                   "THF step=1 kind=fire t0=2026-10-06 12:00:00.000 args=--fire+--method+start-shortcut+--class+informational+--title+THT-x-S3i-1-t1+--tag+a\n"
                   "FIRED method=start-shortcut aumid=QubesToastfire.StartShortcut class=informational tag=a group=toastfire row=6 payload_sha256=ab12\n"
                   "THF step=1 rc=0 t1=2026-10-06 12:00:00.400\n"
                   "THF step=2 kind=gap ms=700 t0=2026-10-06 12:00:00.410\nTHF step=2 rc=0 t1=2026-10-06 12:00:01.110\n"
                   "THF step=3 kind=fire t0=2026-10-06 12:00:01.120 args=--fire+--method+bare+--aumid+Windows.SystemToast.SecurityAndMaintenance+--class+informational+--title+THT-x-S3i-2-t1+--tag+b\n"
                   "FIRED method=bare aumid=Windows.SystemToast.SecurityAndMaintenance class=informational tag=b group=toastfire row=6 payload_sha256=cd34\n"
                   "THF step=3 rc=0 t1=2026-10-06 12:00:01.500\nTHF done steps=3\nUSEROUT_END\n")
    real = sys.stdout; sys.stdout = open(os.devnull, "w")
    try:
        rc_rec = record_fire(d2, ["S3i-1", "S3i-2"], "seamless", 1, wrapper_out)
        rc_bad = record_fire(d2 + "x" if os.makedirs(d2 + "x", exist_ok=True) is None else d2, ["S1a"], "seamless", 1,
                             "USEROUT_BEGIN\nTHF step=1 kind=fire t0=2026-10-06 12:00:00.000 args=--fire\nERROR unknown argument: --x\nUsage: FIRED prints payload_sha256\nTHF step=1 rc=1 t1=2026-10-06 12:00:00.100\nUSEROUT_END\n")
    finally:
        sys.stdout.close(); sys.stdout = real
    rows = [json.loads(l) for l in open(os.path.join(d2, "fires.jsonl"))]
    check("record_fire: two FIRED steps -> two rows in label order", rc_rec == 0 and [r["label"] for r in rows] == ["S3i-1", "S3i-2"] and rows[1]["slug"] == "THT-x-S3i-2-t1", str([r["label"] for r in rows]))
    check("record_fire: a usage error (bare 'FIRED' in Usage) is NOT a fire", rc_bad != 0 and not os.path.exists(os.path.join(d2 + "x", "fires.jsonl")))

    print(f"\nSELFTEST {'CLEAN' if fails == 0 else f'FAILED: {fails} check(s)'}")
    return 0 if fails == 0 else 1


# --------------------------------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out")
    ap.add_argument("--grade", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--record-fire", action="store_true")
    ap.add_argument("--labels", default="")
    ap.add_argument("--mode", default="seamless")
    ap.add_argument("--attempt", type=int, default=1)
    ap.add_argument("--decode-pull", metavar="PULLFILE")
    ap.add_argument("--ref-now", metavar="TS", default=None,
                    help="the GUEST's clock at the pull ('yyyy-mm-dd HH:MM:SS[.fff]'), for a dir whose own "
                         "`THC now=` stamp was lost. bridge.log has no dates; this process's clock is not a "
                         "reference for them.")
    a = ap.parse_args()
    if a.ref_now is not None:
        try:
            parse_ts(a.ref_now)
        except ValueError as e:
            print(f"--ref-now: {e}", file=sys.stderr); return 2
    if a.selftest:
        return selftest()
    if a.record_fire:
        if not a.out or not a.labels:
            print("--record-fire needs --out and --labels", file=sys.stderr); return 2
        return record_fire(a.out, a.labels.split(","), a.mode, a.attempt, sys.stdin.read())
    if a.decode_pull:
        if not a.out:
            print("--decode-pull needs --out", file=sys.stderr); return 2
        return decode_pull(a.out, a.decode_pull)
    if a.grade:
        if not a.out:
            print("--grade needs --out", file=sys.stderr); return 2
        return Grader(a.out, ref_now_arg=a.ref_now).grade()
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
