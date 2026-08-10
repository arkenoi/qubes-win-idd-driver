#!/bin/bash
# Run IN DOM0. Installs local.WinResize: resizes the dom0 window of win-idd-test to a
# requested size, so the dev qube can drive the T2 resolution-follows-window experiments
# (PLAN-trackb-t2-modes.md §6.3 — D5 acceptance is unreachable without this).
#
# v2: windows are selected by the _QUBES_VMNAME X property (set by dom0's gui-daemon,
# unforgeable from inside a VM), NOT by window title — WM_NAME never contains "[vm]"
# (that text is WM decoration drawn from _QUBES_VMNAME), and titles are guest-controlled.
# Same selection + X-session bootstrap as local.WinScreenshot (04-install-*.sh).
#
# Scope and safety:
# - acts ONLY on windows whose _QUBES_VMNAME equals the target qube;
# - resize only (no move, no focus, no input, no reads beyond geometry);
# - callable only by the dev qube per the policy line this script installs.
#
# Protocol: qrexec arg carries the request, e.g.  local.WinResize+1600x1000
#   - "WxH"   resize the LARGEST target-qube window so its client area is WxH
#   - "query" no resize, just report geometry
# stdout, one line:  GEOM ok=<0|1> x=<x> y=<y> w=<w> h=<h> [err=...]
#   w/h are read back AFTER the WM settled — the harness must treat the readback, not the
#   request, as the result (the WM may clamp).
#
# Usage: ./10-install-resize-service.sh <dev-qube> [test-qube]
# Remove: rm /etc/qubes-rpc/local.WinResize /etc/qubes/policy.d/31-win-idd-resize.policy
set -euo pipefail

DEV="${1:?usage: $0 <dev-qube>}"
SVC=/etc/qubes-rpc/local.WinResize
POLICY=/etc/qubes/policy.d/31-win-idd-resize.policy

for tool in xdotool xwininfo xprop; do
    command -v "$tool" >/dev/null || {
        echo "Missing '$tool' in dom0 — install with: sudo qubes-dom0-update xdotool xorg-x11-utils" >&2
        exit 1
    }
done

cat > "$SVC" <<EOF
#!/bin/bash
# Resize the dom0 window of $VM. qubes-win-idd kit (10-install-resize-service.sh v2).
# Arg: WxH (client area) or "query". Output: one GEOM line. Selects by _QUBES_VMNAME.
set -u
REQ="\${QREXEC_SERVICE_ARGUMENT:-\${1#*+}}"
# Resolve the target at RUNTIME to the single RUNNING qube tagged win-idd-testbed, so a
# deleted/renamed guest never silently breaks this (the old build baked win-idd-test in). The
# arg here carries the GEOMETRY, not a VM, so the target cannot come from it.
VM=""
for c in \$(qvm-ls --running --raw-list 2>/dev/null); do
    qvm-tags "\$c" list 2>/dev/null | grep -qx win-idd-testbed && VM="\${VM:+\$VM }\$c"
done
n=0; for x in \$VM; do n=\$((n+1)); done
if [ "\$n" -eq 0 ]; then echo "GEOM ok=0 err=no_running_testbed_guest"; exit 0; fi
if [ "\$n" -gt 1 ]; then echo "GEOM ok=0 err=multiple_testbed_guests:\$VM"; exit 0; fi

# Locate the live graphical session (same bootstrap as local.WinScreenshot).
DOMUSER=\$(getent passwd 1000 | cut -d: -f1)
DISP="\${DISPLAY:-:0}"
XA=""
for c in "/run/lightdm/\$DOMUSER/xauthority" "/home/\$DOMUSER/.Xauthority" \\
         /run/user/\$(id -u "\$DOMUSER" 2>/dev/null)/xauth_* ; do
    [ -r "\$c" ] || continue
    if sudo -u "\$DOMUSER" env DISPLAY="\$DISP" XAUTHORITY="\$c" \\
           xprop -root -notype _NET_SUPPORTED >/dev/null 2>&1; then XA="\$c"; break; fi
done
if [ -z "\$XA" ]; then echo "GEOM ok=0 err=no_x_session"; exit 0; fi
X() { sudo -u "\$DOMUSER" env DISPLAY="\$DISP" XAUTHORITY="\$XA" "\$@"; }

geom() {  # \$1 = wid -> sets gx gy gw gh (client-area geometry)
    eval "\$(X xwininfo -id "\$1" 2>/dev/null | awk '
        /Absolute upper-left X:/ {print "gx="\$4}
        /Absolute upper-left Y:/ {print "gy="\$4}
        /Width:/  {print "gw="\$2}
        /Height:/ {print "gh="\$2}')"
}

best=""; besta=0
for wid in \$(X xprop -root _NET_CLIENT_LIST 2>/dev/null \\
              | sed 's/.*# *//' | tr -d ' ' | tr ',' '\\n' | grep '^0x'); do
    owner=\$(X xprop -id "\$wid" _QUBES_VMNAME 2>/dev/null \\
            | sed -n 's/^_QUBES_VMNAME(STRING) = "\\(.*\\)"\$/\\1/p')
    [ "\$owner" = "\$VM" ] || continue
    gx=""; gy=""; gw=""; gh=""; geom "\$wid"
    [ -n "\$gw" ] || continue
    a=\$((gw*gh))
    if [ "\$a" -gt "\$besta" ]; then besta=\$a; best=\$wid; fi
done
if [ -z "\$best" ]; then echo "GEOM ok=0 err=no_window"; exit 0; fi

if [ "\$REQ" != "query" ]; then
    W="\${REQ%x*}"; H="\${REQ#*x}"
    case "\$W\$H" in *[!0-9]*) echo "GEOM ok=0 err=bad_request"; exit 0;; esac
    if [ "\$W" -lt 100 ] || [ "\$H" -lt 100 ] || [ "\$W" -gt 16384 ] || [ "\$H" -gt 6144 ]; then
        echo "GEOM ok=0 err=out_of_range"; exit 0
    fi
    # v3: a maximized/fullscreen window silently ignores windowsize (measured:
    # a host-size boot left the window stuck at 5120x1440). Clear those states
    # first; harmless when not set.
    X xdotool windowstate --remove MAXIMIZED_VERT "\$best" 2>/dev/null
    X xdotool windowstate --remove MAXIMIZED_HORZ "\$best" 2>/dev/null
    X xdotool windowstate --remove FULLSCREEN "\$best" 2>/dev/null
    X xdotool windowsize "\$best" "\$W" "\$H"
    sleep 0.5   # let the WM apply/clamp before reading back
    # v4: windowsize never moves the window, so a stale position can leave the
    # FRAME (client minus extents) clipped off-screen - measured: client at x=0
    # put the 5px left border at x=-5. Nudge the frame fully on-screen using
    # _NET_FRAME_EXTENTS and the work area.
    fx=\$(X xprop -id "\$best" -notype _NET_FRAME_EXTENTS 2>/dev/null | sed 's/.*= //; s/,//g')
    read -r efl efr eft efb <<< "\${fx:-0 0 0 0}"
    wa=\$(X xprop -root -notype _NET_WORKAREA 2>/dev/null | sed 's/.*= //; s/,//g')
    read -r wax way _ _ <<< "\${wa:-0 0 0 0}"
    geom() { X xwininfo -id "\$best" 2>/dev/null | awk '/Absolute upper-left X:/{x=\$4} /Absolute upper-left Y:/{y=\$4} END{print x, y}'; }
    read -r cx cy <<< "\$(geom)"
    nx=\$cx; ny=\$cy
    [ "\$((cx - efl))" -lt "\$wax" ] && nx=\$((wax + efl))
    [ "\$((cy - eft))" -lt "\$way" ] && ny=\$((way + eft))
    if [ "\$nx" != "\$cx" ] || [ "\$ny" != "\$cy" ]; then
        # xdotool windowmove positions the CLIENT for most WMs
        X xdotool windowmove "\$best" "\$nx" "\$ny"
        sleep 0.3
    fi
fi

gx=""; gy=""; gw=""; gh=""; geom "\$best"
echo "GEOM ok=1 x=\$gx y=\$gy w=\$gw h=\$gh"
EOF
chmod 755 "$SVC"

cat > "$POLICY" <<EOF
# IDD driver dev: $DEV may resize the running win-idd-testbed guest's dom0 window. 10-install-resize-service.sh
local.WinResize  *  $DEV  dom0  allow
EOF

echo "Installed $SVC and $POLICY (dev qube: $DEV, target: the running win-idd-testbed guest)."
echo "Test from $DEV:  qrexec-client-vm dom0 local.WinResize+query"
