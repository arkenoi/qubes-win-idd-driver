#!/bin/bash
# Install a dom0 qrexec service that captures what local.WinScreenshot cannot see - a testbed
# guest's override-redirect windows and dom0's notification bubbles - each over ITS OWN rectangle.
# Never the desktop.
#
# WHY. A toast, a menu, a tooltip and a dom0 notification bubble are absent from _NET_CLIENT_LIST,
# which is all 04 and 15 walk, so four dom0 render witnesses photographed the owner's whole desktop
# (local.WinFullScreen, 07) to find one. A window outside _NET_CLIENT_LIST still has a rectangle:
# this walks the whole window tree (xwininfo -root -tree, as 16 does) and grabs each match with
# `scrot -a x,y,w,h`, the same grab 04 uses.
#
# RULES (each capture's rule is in the manifest):
#   vm-override        viewable, override-redirect, _QUBES_VMNAME = the target: a guest toast, menu
#                      or tooltip. The gui-daemon sets the property; the guest cannot.
#   dom0-notification  viewable, EWMH type _NET_WM_WINDOW_TYPE_NOTIFICATION, no _QUBES_VMNAME: a
#                      bubble dom0's notification daemon drew.
#
# OUTPUT: a tar of pop-<n>.png and manifest.txt -
#   # screen <W> <H> saver=<active|inactive|unknown> monitor=<On|Off|Standby|Suspend|unknown>
#   pop-<n>.png <rule> <window-id> <x> <y> <w> <h>
# saver is xfce4-screensaver's own answer (org.xfce.ScreenSaver.GetActive on the session bus, asked
# only when that name has an owner, so the query never starts a saver) and monitor is DPMS (xset q):
# an active saver - running or locked - or a monitor that is not On means nothing on screen can be
# seen. The service exits 0 whenever the walk ran, with no capture too: "no popup" is an answer.
#
# SECURITY. Target = the qrexec +argument, gated by the win-idd-testbed tag, as 04. vm-override
# returns only the target's windows. dom0-notification returns every bubble on screen, whichever
# qube's message it carries - the bubbles' rectangles only, strictly less than local.WinFullScreen,
# which hands the same caller the whole desktop.
#
# Remove:  sudo rm /etc/qubes-rpc/local.WinPopupShot /etc/qubes/policy.d/30-win-idd-popupshot.policy
set -uo pipefail

SVC=/etc/qubes-rpc/local.WinPopupShot
POLICY=/etc/qubes/policy.d/30-win-idd-popupshot.policy
CALLER=win-idd-mgmt

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
missing=()
for tool in xprop xwininfo scrot; do command -v "$tool" >/dev/null || missing+=("$tool"); done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing in dom0: ${missing[*]}" >&2
    echo "  sudo qubes-dom0-update xorg-x11-utils scrot" >&2
    exit 1
fi

cat > "$SVC" <<'EOF'
#!/bin/bash
# local.WinPopupShot+<vm> - see dom0/19-install-popup-screenshot-service.sh in the repo.
set -uo pipefail
VM="${QREXEC_SERVICE_ARGUMENT:-${1:-}}"; VM="${VM##*+}"
[ -n "$VM" ] || { echo "no target: call as local.WinPopupShot+<vm>" >&2; exit 1; }
qvm-tags "$VM" list 2>/dev/null | grep -qx win-idd-testbed || {
    echo "refused: '$VM' lacks the win-idd-testbed tag" >&2; exit 1; }

DOMUSER=$(getent passwd 1000 | cut -d: -f1)
DISP="${DISPLAY:-:0}"
XA=""
for c in "/run/lightdm/$DOMUSER/xauthority" "/home/$DOMUSER/.Xauthority" \
         /run/user/$(id -u "$DOMUSER" 2>/dev/null)/xauth_* ; do
    [ -r "$c" ] || continue
    if sudo -u "$DOMUSER" env DISPLAY="$DISP" XAUTHORITY="$c" \
           xprop -root -notype _NET_SUPPORTED >/dev/null 2>&1; then XA="$c"; break; fi
done
[ -n "$XA" ] || { echo "ERROR: no usable X session for $DOMUSER on $DISP" >&2; exit 2; }

# The session bus, from the session's own environment; /run/user/<uid>/bus when that is unreadable.
BUS=""
for p in $(pgrep -u "$DOMUSER" -x xfce4-session) $(pgrep -u "$DOMUSER" -x xfce4-screensaver); do
    BUS=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -1)
    [ -n "$BUS" ] && break
done
[ -n "$BUS" ] || BUS="unix:path=/run/user/$(id -u "$DOMUSER")/bus"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
chown "$DOMUSER" "$TMP" 2>/dev/null || chmod 0777 "$TMP"

# One sudo context for the whole walk: a sudo per window was the ~58 s 16 measured.
sudo -u "$DOMUSER" env DISPLAY="$DISP" XAUTHORITY="$XA" DBUS_SESSION_BUS_ADDRESS="$BUS" \
    TARGETVM="$VM" OUT="$TMP" bash -s <<'POPINNER'
pop_rect(){ # <id> -> "x y w h viewable override-redirect", absolute and unclipped
    xwininfo -id "$1" -stats 2>/dev/null | awk '
        /Absolute upper-left X:/ {x = $4}
        /Absolute upper-left Y:/ {y = $4}
        /^ *Width:/  {w = $2}
        /^ *Height:/ {h = $2}
        /Map State:/ {m = ($3 == "IsViewable") ? 1 : 0}
        /Override Redirect State:/ {o = ($4 == "yes") ? 1 : 0}
        END { if (w == "" || h == "") exit 1; printf "%d %d %d %d %d %d\n", x, y, w, h, m, o }'
}
read -r SW SH < <(xwininfo -root 2>/dev/null | awk '/^ *Width:/ {w = $2} /^ *Height:/ {h = $2} END {print w, h}')
saver=unknown
if dbus-send --session --print-reply --reply-timeout=2000 --dest=org.freedesktop.DBus /org/freedesktop/DBus \
       org.freedesktop.DBus.NameHasOwner string:org.xfce.ScreenSaver 2>/dev/null | grep -q 'boolean true'; then
    case "$(dbus-send --session --print-reply --reply-timeout=2000 --dest=org.xfce.ScreenSaver /org/xfce/ScreenSaver \
                org.xfce.ScreenSaver.GetActive 2>/dev/null | grep -oE 'boolean (true|false)')" in
        'boolean true')  saver=active ;;
        'boolean false') saver=inactive ;;
    esac
fi
monitor=$(xset q 2>/dev/null | sed -n 's/^ *Monitor is \([A-Za-z]*\).*/\1/p' | head -1)
echo "# screen ${SW:-?} ${SH:-?} saver=$saver monitor=${monitor:-unknown}" > "$OUT/manifest.txt"
n=0
for id in $(xwininfo -root -tree 2>/dev/null | grep -oE '0x[0-9a-f]+' | sort -u); do
    props=$(xprop -id "$id" _QUBES_VMNAME _NET_WM_WINDOW_TYPE 2>/dev/null)
    owner=$(printf '%s\n' "$props" | sed -n 's/^_QUBES_VMNAME(STRING) = "\(.*\)"$/\1/p')
    if [ "$owner" = "$TARGETVM" ]; then rule=vm-override
    elif [ -z "$owner" ] && printf '%s\n' "$props" | grep -q '_NET_WM_WINDOW_TYPE_NOTIFICATION'; then rule=dom0-notification
    else continue; fi
    r=$(pop_rect "$id") || continue
    read -r x y w h m o <<< "$r"
    [ "$m" = 1 ] || continue
    [ "$rule" = vm-override ] && [ "$o" != 1 ] && continue
    # Clipped to the screen; the manifest gives the rectangle actually grabbed.
    [ "$x" -lt 0 ] && { w=$((w + x)); x=0; }
    [ "$y" -lt 0 ] && { h=$((h + y)); y=0; }
    [ -n "$SW" ] && [ $((x + w)) -gt "$SW" ] && w=$((SW - x))
    [ -n "$SH" ] && [ $((y + h)) -gt "$SH" ] && h=$((SH - y))
    { [ "$w" -gt 0 ] && [ "$h" -gt 0 ]; } || continue
    # Read again after the grab: a window that moved, resized or went away meanwhile is dropped
    # rather than recorded over pixels that are no longer its own.
    if scrot -a "$x,$y,$w,$h" -o "$OUT/pop-$n.png" 2>/dev/null && [ "$(pop_rect "$id")" = "$r" ]; then
        echo "pop-$n.png $rule $id $x $y $w $h" >> "$OUT/manifest.txt"
        n=$((n + 1))
    else
        rm -f "$OUT/pop-$n.png"
    fi
done
POPINNER
tar -C "$TMP" -cf - .
EOF
chmod 755 "$SVC"

cat > "$POLICY" <<EOF
local.WinPopupShot * $CALLER dom0 allow
local.WinPopupShot * @anyvm  dom0 deny
EOF
chmod 0644 "$POLICY"
echo "Installed $SVC"
echo "Installed $POLICY (caller: $CALLER)"

# ---- ONE CHECK ON THIS dom0: does a real bubble match the dom0-notification rule? -------------
# The rule assumes the notification daemon types its bubbles _NET_WM_WINDOW_TYPE_NOTIFICATION.
# Nothing the caller qube can reach lists dom0's own windows, so it is checked here, once, with a
# bubble raised for the purpose (it shows on screen for 8 s).
T=$(qvm-ls --raw-data --tags win-idd-testbed --fields NAME 2>/dev/null | head -1)
[ -n "$T" ] || { echo "check SKIPPED: no qube carries the win-idd-testbed tag"; exit 0; }
DOMUSER=$(getent passwd 1000 | cut -d: -f1)
BUS=""
for p in $(pgrep -u "$DOMUSER" -x xfce4-session); do
    BUS=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -1)
    [ -n "$BUS" ] && break
done
[ -n "$BUS" ] || BUS="unix:path=/run/user/$(id -u "$DOMUSER")/bus"
sudo -u "$DOMUSER" env DISPLAY="${DISPLAY:-:0}" DBUS_SESSION_BUS_ADDRESS="$BUS" \
    notify-send -t 8000 "win-idd popup check" "local.WinPopupShot should capture this bubble" \
    || { echo "check SKIPPED: notify-send failed"; exit 0; }
sleep 2
CHK=$(mktemp -d)
QREXEC_SERVICE_ARGUMENT="local.WinPopupShot+$T" "$SVC" > "$CHK/p.tar" 2>"$CHK/err.txt"
echo "service rc=$? against $T; manifest:"
tar -xOf "$CHK/p.tar" ./manifest.txt 2>/dev/null | sed 's/^/  /'
if tar -xOf "$CHK/p.tar" ./manifest.txt 2>/dev/null | grep -q ' dom0-notification '; then
    echo "check PASSED: the bubble was captured as dom0-notification"
else
    echo "check FAILED: no dom0-notification capture - the daemon's bubble does not carry the"
    echo "  NOTIFICATION window type; tell the agent, and paste:  $(cat "$CHK/err.txt" 2>/dev/null | head -3)"
fi
rm -rf "$CHK"
