#!/bin/bash
# Run IN DOM0. Installs local.WinSendKey: types a short ASCII string into the dom0 window of the
# running win-idd-testbed guest, so the dev qube can exercise the dom0 -> vchan -> agent input
# path (MSG_KEYPRESS) that it otherwise cannot reach.
#
# WHY THIS EXISTS (2026-09-25). Non-seamless input was reported broken by the owner. The agent-side
# defect was real and is fixed - HandleFocus resolved the focused window with FindWindowByHandle,
# which never finds WINDOW 0, so in non-seamless nothing was ever brought to the foreground and
# synthesized keys had nowhere to land. But the fix could only be HALF verified from the dev qube:
# the foreground window and SendInput delivery were demonstrated inside the guest, while the hop
# that actually carries a user's keystroke - dom0's gui-daemon -> vchan -> HandleKeypress - has no
# driver here. local.WinResize is the only window-touching service and its own header states
# "resize only (no move, no focus, no input)". Jev rated that gap the biggest remaining obstacle
# to calling the switch functional (0.77) and would not call input closed without it (0.40).
#
# THIS WIDENS WHAT THE DEV QUBE CAN DO, DELIBERATELY. Read before installing:
# - it SYNTHESIZES KEYSTROKES into a guest window. That is input injection, which every other
#   service in this kit was careful to avoid. It is scoped the same way they are - only the dev
#   qube may call it, only windows whose _QUBES_VMNAME is the running win-idd-testbed guest are
#   touched - but the capability itself is new, and it is the owner's call whether the testbed
#   should have it. The guest is disposable and assumed hostile; this sends INTO it, never reads
#   from it.
# - the payload is restricted to [A-Za-z0-9 ] and 64 characters, so it cannot carry modifiers,
#   function keys, shell metacharacters or a key sequence that could drive a menu.
# - it does not move, resize, focus or raise anything, and returns no guest content.
#
# Usage:  ./18-install-input-service.sh <dev-qube>          (no sudo; it writes as the caller)
# Then:   qrexec-client-vm dom0 local.WinSendKey+HELLO      from the dev qube
set -euo pipefail

DEV="${1:?usage: $0 <dev-qube> - name the dev qube; there is no default target}"
SVC=/etc/qubes-rpc/local.WinSendKey
POLICY=/etc/qubes/policy.d/32-win-idd-input.policy

for tool in xdotool xprop; do
    command -v "$tool" >/dev/null || {
        echo "Missing '$tool' in dom0 - install with: qubes-dom0-update xdotool xorg-x11-utils" >&2
        exit 1
    }
done

cat > "$SVC" <<'EOF'
#!/bin/bash
# Type a short ASCII string into the running win-idd-testbed guest's dom0 window.
# qubes-win-idd kit (18-install-input-service.sh). Output: one KEY line.
set -u
REQ="${QREXEC_SERVICE_ARGUMENT:-${1#*+}}"

# Payload allowlist. Anything outside [A-Za-z0-9 ] is refused, so this cannot carry a modifier,
# a function key, or a sequence that would drive a menu rather than land in a text field.
case "$REQ" in
    "" ) echo "KEY ok=0 err=empty"; exit 0;;
    *[!A-Za-z0-9\ ]* ) echo "KEY ok=0 err=charset"; exit 0;;
esac
[ "${#REQ}" -le 64 ] || { echo "KEY ok=0 err=too_long"; exit 0; }

# Target resolved at RUNTIME to the single RUNNING win-idd-testbed guest - never from the
# argument, which carries the payload. No default target.
VM=""
for c in $(qvm-ls --running --raw-list 2>/dev/null); do
    qvm-tags "$c" list 2>/dev/null | grep -qx win-idd-testbed && VM="${VM:+$VM }$c"
done
n=0; for x in $VM; do n=$((n+1)); done
[ "$n" -eq 0 ] && { echo "KEY ok=0 err=no_running_testbed_guest"; exit 0; }
[ "$n" -gt 1 ] && { echo "KEY ok=0 err=multiple_testbed_guests:$VM"; exit 0; }

DOMUSER=$(getent passwd 1000 | cut -d: -f1)
DISP="${DISPLAY:-:0}"
XA=""
for c in "/run/lightdm/$DOMUSER/xauthority" "/home/$DOMUSER/.Xauthority" \
         /run/user/$(id -u "$DOMUSER" 2>/dev/null)/xauth_* ; do
    [ -r "$c" ] && { XA="$c"; break; }
done
[ -z "$XA" ] && { echo "KEY ok=0 err=no_x_session"; exit 0; }
X() { sudo -u "$DOMUSER" env DISPLAY="$DISP" XAUTHORITY="$XA" "$@"; }

# Largest window belonging to that guest, selected by the unforgeable _QUBES_VMNAME property.
best=""; besta=0
for wid in $(X xprop -root _NET_CLIENT_LIST 2>/dev/null | sed 's/.*# //; s/,//g'); do
    owner=$(X xprop -id "$wid" _QUBES_VMNAME 2>/dev/null \
            | sed -n 's/^_QUBES_VMNAME(STRING) = "\(.*\)"$/\1/p')
    [ "$owner" = "$VM" ] || continue
    g=$(X xdotool getwindowgeometry --shell "$wid" 2>/dev/null) || continue
    w=$(printf '%s\n' "$g" | sed -n 's/^WIDTH=//p');  h=$(printf '%s\n' "$g" | sed -n 's/^HEIGHT=//p')
    [ -n "$w" ] && [ -n "$h" ] || continue
    a=$((w*h)); [ "$a" -gt "$besta" ] && { besta=$a; best=$wid; }
done
[ -z "$best" ] && { echo "KEY ok=0 err=no_window vm=$VM"; exit 0; }

# --window targets the keystrokes at that window without focusing or raising it.
X xdotool type --window "$best" --delay 80 -- "$REQ" 2>/dev/null \
    && echo "KEY ok=1 vm=$VM wid=$best n=${#REQ}" \
    || echo "KEY ok=0 err=xdotool_failed vm=$VM wid=$best"
EOF

chmod 755 "$SVC"

cat > "$POLICY" <<EOF
# IDD driver dev: $DEV may type into the running win-idd-testbed guest's dom0 window.
# Installed by dom0/18-install-input-service.sh. See that script's header before widening this.
local.WinSendKey   *  $DEV  dom0  allow
local.WinSendKey   *  @anyvm @anyvm  deny
EOF
chmod 644 "$POLICY"

echo "Installed $SVC and $POLICY (dev qube: $DEV, target: the running win-idd-testbed guest)."
echo "Test from $DEV:  qrexec-client-vm dom0 local.WinSendKey+HELLO"
