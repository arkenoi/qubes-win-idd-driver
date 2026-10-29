#!/usr/bin/env bash
# window-grade-lib.sh - "did a guest window reach dom0 as PIXELS?", the mission check, shared.
#
# WHY THIS IS A LIBRARY (2026-10-28). The check existed only as grade_appvm_window() inside
# matrix.sh, so the SHORT CYCLE could not run it: quick-upgrade.sh graded the installer, the agent
# hash and process liveness, took one ungraded `qtest shot` for evidence, and never opened a window
# at all. Owner, this run: "but the smoke test never opened a window". A seamless guest with nothing
# open maps NO window (burst-quiet-ab.sh:42 measured NOWINDOW for 300 s on a healthy guest), so the
# smoke's capture was an empty desktop by construction and no verdict could have come from it -
# grading those pixels would have graded a blank screen forever. The body below is matrix.sh's,
# moved here unchanged in behaviour; matrix.sh keeps grade_appvm_window() as a wrapper so its
# campaign log still reads exactly as before.
#
# CALLER CONTRACT - source from the REPO ROOT, with the per-VM lock already held, AFTER
# mgmt/harness/lifecycle-lib.sh (ctl_start/ctl_stop). Nothing else is required.
#
# grade_mapped_window <vm> <artifact-base>
#   Opens notepad BY HANDLE, polls dom0 for a capture, counts the PNGs, then closes the control
#   window by the identity it recorded. <artifact-base> names the tar and the PNG dir:
#   <base>.tar and <base>-png/.
#   rc 0  window(s) mapped, none fullscreen-sized          WG_W = how many
#      1  a FULLSCREEN-SIZED window was mapped             (Mode 1 is unconditionally off)
#      2  INVALID-INSTRUMENT: the guest HAS a top-level window but dom0 returned none
#         AND the agent still has a GUI client, so the capture is the thing that failed
#      3  notepad opened and dom0 got no window            WG_GUEST = guest-side count
#   WG_GUI is set whenever the guest-side count is taken: client | noclient | unknown.
#   Always sets WG_CTLSTOP_OUT / WG_CTLSTOP_RC - the control window's close. THE CALLER MUST
#   BRANCH ON WG_CTLSTOP_RC: a control window that did not close stays on the desktop and any
#   later window grading in the same cell counts it as the product's (lifecycle-lib.sh CTL-STOP-RC-A).
WG_W=0; WG_GUEST=""; WG_CTLSTOP_OUT=""; WG_CTLSTOP_RC=0; WG_GUI=""

# ---- THE CAPTURE PRIMITIVES. One reader of a PNG's IHDR. This was copied into SIX harnesses in
# FIVE output formats ('W H', 'WxH', 'WxH:<sha>') - p5-run.sh, sg1-u2-coldboot.sh, gate-preflight.sh,
# rnd-shell-surfaces.sh, rnd8-resolution.sh and the window check itself - each with its own inline
# python. They are dependency-free: a harness may source this file for these alone.
wg_png_dims(){ # <png> -> "<w> <h>" on stdout; nothing at all when the file is unreadable or not a PNG
  python3 -c "
import struct,sys
b=open(sys.argv[1],'rb').read(24); w,h=struct.unpack('>II',b[16:24]); print(w,h)" "$1" 2>/dev/null
}

wg_png_wxh(){ # <png> -> "<w>x<h>"; rc 1 when unreadable, so a caller can print NOWIN instead
  local w h; read -r w h < <(wg_png_dims "$1")
  [ -n "${w:-}" ] || return 1
  printf '%sx%s\n' "$w" "$h"
}

wg_png_id(){ # <png> -> "<w>x<h>:<sha256[:16]>" - the dimensions plus a content fingerprint, so two
             # captures of the same window can be compared without keeping the pixels
  python3 -c "
import struct,hashlib,sys
b=open(sys.argv[1],'rb').read(); w,h=struct.unpack('>II',b[16:24])
print(f'{w}x{h}:{hashlib.sha256(b).hexdigest()[:16]}')" "$1" 2>/dev/null
}

_wg_say(){ if declare -F say >/dev/null 2>&1; then say "$@"; else log "$@"; fi; }

# The guest-side half of the INVALID-INSTRUMENT discrimination, implemented HERE rather than via
# e2e-wait.sh's g_probe so the library depends only on lifecycle-lib.sh and tools/qtest - stability-e2e.sh
# does not source e2e-wait.sh, and a shared check must not force its callers to adopt one.
# Same mechanics as g_probe: base64 UTF-16LE -EncodedCommand (no quoting survives the VMShell hop),
# the script Write-Hosts "NPWIN=<n>", and only a line matching ^NPWIN= is read.
_wg_npwin(){ # <vm> -> count of notepad processes owning a top-level window, empty when unreadable
  local b64
  b64=$(python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" \
    'Write-Host ("NPWIN=" + ((Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Measure-Object).Count))') || return 1
  QTEST_VM=$1 timeout -k 5 60 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64" 2>/dev/null \
    | tr -d '\r' | grep -aoE '^NPWIN=.*' | head -1 | sed 's/^NPWIN=//'
}

# THE DISCRIMINATOR THIS CHECK WAS MISSING (2026-10-29). "Guest has a window, dom0 captured
# none" was attributed, unconditionally, to "a dom0 desktop switch or capture fault" - the check
# blamed its own instrument. In acceptance run rel-40817518835 cell win11de-uc that attribution
# was WRONG and it hid the most severe failure this product can have: the agent's GUI channel was
# dead, so no window was ever mapped and the dom0 capture was CORRECT to return nothing. Measured:
# the agent logged "A vchan client has connected" at 08:51:39, lost it by 08:52:00, restarted, and
# the replacement sat at "Awaiting for a vchan client" through the check at 08:53:03. The same
# signature is in rel-39678937221 (10-22) and rel-39880114972 (10-23).
# The agent's own log decides it, and the log already says which state it is in: compare the LAST
# "connected" against the LAST "Awaiting". Reading it costs one qrexec call and only on the path
# that was about to grade itself INVALID. Log-reading idiom is stability-e2e.sh:108's, unchanged.
# unknown (log unreadable) keeps the old INVALID-INSTRUMENT verdict - this must not turn an
# unreadable log into a product failure.
_wg_guiclient(){ # <vm> -> client | noclient | unknown
  local L body conn await
  L=$(QTEST_VM=$1 timeout -k 5 90 ./tools/qtest run 'cmd /c dir /b /o-d "Q:\Qubes Logs\gui-agent-*.log"' 2>/dev/null \
      | tr -d '\r' | grep -a '^gui-agent' | head -1)
  [ -n "$L" ] || { echo unknown; return 0; }
  body=$(QTEST_VM=$1 timeout -k 5 90 ./tools/qtest run \
      "cmd /c findstr /c:\"A vchan client has connected\" /c:\"Awaiting for a vchan client\" \"Q:\\Qubes Logs\\$L\"" \
      2>/dev/null | tr -d '\r')
  conn=$(printf '%s\n' "$body"  | grep -a 'A vchan client has connected' | tail -1 | grep -aoE '[0-9]{8}\.[0-9]{6}\.[0-9]{3}' | head -1)
  await=$(printf '%s\n' "$body" | grep -a 'Awaiting for a vchan client'  | tail -1 | grep -aoE '[0-9]{8}\.[0-9]{6}\.[0-9]{3}' | head -1)
  # No "Awaiting" at all means this agent never even announced: not something this check can read
  # as a dead client, so it stays unknown unless a connect is on record.
  [ -n "$await" ] || { if [ -n "$conn" ]; then echo client; else echo unknown; fi; return 0; }
  [ -n "$conn" ]  || { echo noclient; return 0; }
  # Both are "YYYYMMDD.HHMMSS.mmm", fixed width, so dropping the dots gives a 17-digit integer
  # (max ~9.9e16, well inside bash's 64-bit arithmetic) and the compare is a plain time compare -
  # no locale collation involved.
  if [ "${await//./}" -gt "${conn//./}" ]; then echo noclient; else echo client; fi
}

grade_mapped_window(){ # $1=vm $2=artifact-base
  local app=$1 base=$2
  local full_w=${WG_FULL_W:-5120} full_h=${WG_FULL_H:-1440}
  WG_W=0; WG_GUEST=""
  # Pixels, not logs: open notepad and require a mapped, non-fullscreen window.
  local nppid npstart; read -r _ nppid npstart <<< "$(QTEST_VM=$app T=45 ctl_start notepad)"   # by handle (lifecycle-lib.sh)
  local try f w h big=0
  for try in 1 2 3 4 5 6; do
    sleep 7
    rm -f "$base.tar"
    QTEST_VM=$app timeout -k 8 120 ./tools/qtest shot "$base.tar" >/dev/null 2>&1
    [ -s "$base.tar" ] && [ "$(tar tf "$base.tar" 2>/dev/null | grep -c '\.png$')" -gt 0 ] && break
  done
  rm -rf "$base-png"; mkdir -p "$base-png"
  tar xf "$base.tar" -C "$base-png" 2>/dev/null
  for f in "$base-png"/*.png; do
    [ -e "$f" ] || continue
    WG_W=$((WG_W+1)); read -r w h < <(wg_png_dims "$f")
    [ -z "${w:-}" ] && continue
    _wg_say "    $(basename "$f") ${w}x${h}"
    [ "$w" -ge $(( full_w * 99 / 100 )) ] && [ "$h" -ge $(( full_h * 99 / 100 )) ] && big=1
  done
  # AN EMPTY dom0 CAPTURE IS NOT "NO WINDOW" (memory rule, and measured 2026-09-11: campaign
  # 34594988407 graded WIN11-appvm boot 2 a product FAIL on six empty tars while qrexec answered
  # and the guest took an orderly ACPI shutdown 58 s later - the owner was switching dom0
  # desktops, and the screenshot service returns only windows on the CURRENT one). So before
  # grading, ask the GUEST whether notepad has a top-level window. Guest window present + dom0
  # capture empty = INVALID-INSTRUMENT (ungraded), never a product verdict. Probed BEFORE the
  # taskkill, or there is nothing left to ask about.
  if [ "$WG_W" -eq 0 ]; then
    WG_GUEST=$(_wg_npwin "$app")
    WG_GUI=$(_wg_guiclient "$app")
  fi
  WG_CTLSTOP_OUT=$(QTEST_VM=$app T=45 ctl_stop "${nppid:-0}" "${npstart:-0}"); WG_CTLSTOP_RC=$?
  [ "$big" = 1 ] && return 1
  [ "$WG_W" -gt 0 ] && return 0
  # A guest window that dom0 did not capture is INVALID-INSTRUMENT only while the agent still has
  # a GUI client. With no client there is nothing to deliver over, the empty capture is the
  # correct answer, and this is the product failing - rc 3, same as any other undelivered window.
  if [ "${WG_GUEST:-x}" -ge 1 ] 2>/dev/null; then
    [ "$WG_GUI" = noclient ] && return 3
    return 2
  fi
  return 3
}
