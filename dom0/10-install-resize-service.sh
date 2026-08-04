#!/bin/bash
# Run IN DOM0. Installs local.WinResize: resizes the dom0 window of win-idd-test to a
# requested size, so the dev qube can drive the T2 resolution-follows-window experiments
# (PLAN-trackb-t2-modes.md §6.3 — D5 acceptance is unreachable without this).
#
# Scope and safety, same isolation pattern as local.WinScreenshot (04-install-*.sh):
# - acts ONLY on windows titled "[<test-qube>]" — never on any other qube's or dom0's windows;
# - resize only (no move, no focus, no input);
# - callable only by the dev qube per the policy line this script installs.
#
# Protocol: qrexec arg carries the request, e.g.  local.WinResize+1600x1000
#   - "WxH"   resize the largest matching window so its CLIENT area is WxH
#   - "query" no resize, just report geometry
# stdout, one line:  GEOM ok=<0|1> x=<x> y=<y> w=<w> h=<h> [err=...]
#   w/h are the CLIENT area (what the guest can use), read back AFTER the WM settled —
#   the harness must treat the readback, not the request, as the result (the WM may clamp).
#
# Usage: ./10-install-resize-service.sh <dev-qube> [test-qube]
# Remove: rm /etc/qubes-rpc/local.WinResize /etc/qubes/policy.d/31-win-idd-resize.policy
set -euo pipefail

DEV="${1:?usage: $0 <dev-qube> [test-qube]}"
VM="${2:-win-idd-test}"
SVC=/etc/qubes-rpc/local.WinResize
POLICY=/etc/qubes/policy.d/31-win-idd-resize.policy

for tool in xdotool xwininfo; do
    command -v "$tool" >/dev/null || {
        echo "Missing '$tool' in dom0 — install with: sudo qubes-dom0-update xdotool xorg-x11-utils" >&2
        exit 1
    }
done

cat > "$SVC" <<EOF
#!/bin/bash
# Resize the dom0 window of $VM. qubes-win-idd kit (10-install-resize-service.sh).
# Arg: WxH (client area) or "query". Output: one GEOM line. Refuses non-$VM windows.
REQ="\${1#*+}"

# Largest window whose title marks it as belonging to $VM (guid title prefix).
best=""; besta=0
for id in \$(xdotool search --name '^\[$VM\]' 2>/dev/null); do
    eval "\$(xwininfo -id "\$id" 2>/dev/null | awk '
        /Width:/  {print "w="\$2}
        /Height:/ {print "h="\$2}
        /Absolute upper-left X:/ {print "x="\$4}
        /Absolute upper-left Y:/ {print "y="\$4}')"
    [ -n "\${w:-}" ] || continue
    a=\$((w*h))
    if [ "\$a" -gt "\$besta" ]; then besta=\$a; best=\$id; fi
done
if [ -z "\$best" ]; then echo "GEOM ok=0 err=no_window"; exit 0; fi

if [ "\$REQ" != "query" ]; then
    W="\${REQ%x*}"; H="\${REQ#*x}"
    case "\$W\$H" in *[!0-9]*) echo "GEOM ok=0 err=bad_request"; exit 0;; esac
    if [ "\$W" -lt 100 ] || [ "\$H" -lt 100 ] || [ "\$W" -gt 16384 ] || [ "\$H" -gt 6144 ]; then
        echo "GEOM ok=0 err=out_of_range"; exit 0
    fi
    # xdotool windowsize sets the CLIENT area for most WMs (frame is added outside).
    xdotool windowsize "\$best" "\$W" "\$H"
    sleep 0.5   # let the WM apply/clamp before reading back
fi

eval "\$(xwininfo -id "\$best" 2>/dev/null | awk '
    /Width:/  {print "w="\$2}
    /Height:/ {print "h="\$2}
    /Absolute upper-left X:/ {print "x="\$4}
    /Absolute upper-left Y:/ {print "y="\$4}')"
echo "GEOM ok=1 x=\$x y=\$y w=\$w h=\$h"
EOF
chmod 755 "$SVC"

cat > "$POLICY" <<EOF
# IDD driver dev: $DEV may resize $VM's dom0 window. 10-install-resize-service.sh
local.WinResize  *  $DEV  dom0  allow
EOF

echo "Installed $SVC and $POLICY (dev qube: $DEV, target: $VM)."
echo "Test from $DEV:  qrexec-client-vm dom0 local.WinResize+query"
