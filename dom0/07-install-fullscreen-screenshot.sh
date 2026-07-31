#!/bin/bash
# Install a dom0 qrexec service that returns a FULL DESKTOP screenshot to win-idd-mgmt.
#
# SECURITY NOTE - read before installing.
# The existing local.WinScreenshot deliberately captures ONLY windows belonging to
# win-idd-test, so the management VM never sees other qubes' content. This service does NOT
# have that property: it photographs the whole dom0 display, including every other qube's
# windows and anything else on screen at the time.
#
# It exists because two reported defects - the dom0-drawn rectangle over menus, and the window
# border being off - are invisible to the per-window service by construction: menus are
# override-redirect (absent from _NET_CLIENT_LIST) and decorations are drawn on the frame, not
# on the client window that `import -window` captures.
#
# Install it while working on this, uninstall it when done:
#     sudo rm /etc/qubes-rpc/local.WinFullScreen
# Only install if you accept that win-idd-mgmt can see your whole screen while it is present.
set -euo pipefail

SVC=/etc/qubes-rpc/local.WinFullScreen
POLICY=/etc/qubes/policy.d/30-win-idd-mgmt.policy

for tool in import xprop xwininfo; do
    command -v "$tool" >/dev/null || {
        echo "Missing '$tool' in dom0 - install with: sudo qubes-dom0-update ImageMagick xorg-x11-utils" >&2
        exit 1
    }
done

cat > "$SVC" <<'EOF'
#!/bin/bash
# Full-desktop screenshot for visual validation. Returns a tar containing screen.png plus
# geometry.txt listing every win-idd-test window INCLUDING override-redirect ones (menus) and
# their frame windows, so the caller can crop and compare without guessing.
set -uo pipefail
VM=win-idd-test

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
XENV=(env DISPLAY="$DISP" XAUTHORITY="$XA")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sudo -u "$DOMUSER" "${XENV[@]}" import -window root "$TMP/screen.png" 2>/dev/null || {
    echo "ERROR: root window capture failed" >&2; exit 3; }

# Walk the whole window tree, not _NET_CLIENT_LIST: menus are override-redirect and never
# appear in the managed-client list. _QUBES_VMNAME is set by dom0 and cannot be forged by the
# guest, unlike WM_NAME.
{
    echo "# id x y w h override_redirect name"
    sudo -u "$DOMUSER" "${XENV[@]}" xwininfo -root -tree -int 2>/dev/null |
    grep -oE '^ +[0-9]+ ' | tr -d ' ' | while read -r id; do
        [ -n "$id" ] || continue
        owner=$(sudo -u "$DOMUSER" "${XENV[@]}" xprop -id "$id" _QUBES_VMNAME 2>/dev/null |
                sed -n 's/^_QUBES_VMNAME(STRING) = "\(.*\)"$/\1/p')
        [ "$owner" = "$VM" ] || continue
        info=$(sudo -u "$DOMUSER" "${XENV[@]}" xwininfo -id "$id" -stats 2>/dev/null) || continue
        x=$(echo "$info" | sed -n 's/.*Absolute upper-left X: *\([0-9-]*\).*/\1/p')
        y=$(echo "$info" | sed -n 's/.*Absolute upper-left Y: *\([0-9-]*\).*/\1/p')
        w=$(echo "$info" | sed -n 's/.*Width: *\([0-9]*\).*/\1/p')
        h=$(echo "$info" | sed -n 's/.*Height: *\([0-9]*\).*/\1/p')
        ovr=$(echo "$info" | grep -c 'Override Redirect State: yes' || true)
        name=$(sudo -u "$DOMUSER" "${XENV[@]}" xprop -id "$id" WM_NAME 2>/dev/null |
               sed -n 's/^WM_NAME(\(STRING\|UTF8_STRING\)) = "\(.*\)"$/\2/p' | head -1)
        echo "$id $x $y $w $h $ovr ${name:-?}"
    done
} > "$TMP/geometry.txt" 2>/dev/null

tar -C "$TMP" -cf - .
EOF

chmod 755 "$SVC"

if ! grep -q 'local.WinFullScreen' "$POLICY" 2>/dev/null; then
    printf 'local.WinFullScreen * win-idd-mgmt dom0 allow\n' >> "$POLICY"
    echo "Added policy line to $POLICY"
fi

echo "Installed $SVC"
echo
echo "This captures the WHOLE dom0 display, including other qubes' windows."
echo "Remove when finished:  sudo rm $SVC"
