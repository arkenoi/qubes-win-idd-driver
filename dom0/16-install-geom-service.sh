#!/bin/bash
# Install a dom0 qrexec service returning ONLY the window GEOMETRY of a testbed guest - the
# window list (ids, positions, sizes, override-redirect + map state, names), as PLAIN TEXT, with
# NO image capture at all.
#
# WHY THIS EXISTS. `local.WinFullScreen` (dom0/07) captures the entire dom0 desktop as a PNG and
# THEN appends the same geometry list. Callers that only need the geometry - e.g. `tools/qtest-geom`,
# which extracts geometry.txt and DELETES the PNG unread - pay the whole-desktop capture cost for
# nothing: measured ~59 s PER CALL on a 5120x1440 dom0 here. That made the toast-bridge acceptance's
# transient-toast detection impossible (a ~5 s toast is gone before a 59 s snapshot aligns) and any
# retry loop minutes long. The geometry itself (xwininfo -root -tree) is sub-second. So: emit the
# geometry directly, skip the capture. "Capture the window, don't cut it from the desktop" - here
# the caller wants the LIST, not pixels; per-window PIXELS already have their own service
# (local.WinWindowShot, dom0/15, `import -window <id>` - works for override-redirect windows too).
#
# SECURITY. This returns only OUR guest's window metadata (filtered by the unforgeable dom0-set
# _QUBES_VMNAME, tag-gated to win-idd-testbed) - strictly LESS than local.WinFullScreen, which
# photographs every qube's pixels. No image data of any qube crosses this service.
#
# Remove when finished:  sudo rm /etc/qubes-rpc/local.WinGeom /etc/qubes/policy.d/30-win-idd-geom.policy
set -uo pipefail

SVC=/etc/qubes-rpc/local.WinGeom
POLICY=/etc/qubes/policy.d/30-win-idd-geom.policy
CALLER=win-idd-mgmt

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

# xwininfo + xprop only - NO `import` (this service never captures pixels). Both are already used
# by local.WinScreenshot / local.WinFullScreen, so they are known present; xwininfo is the one that
# might be absent, and without it there is no geometry at all, so it is REQUIRED here (unlike in 07,
# where it was an optional nicety on top of the PNG).
missing=()
for tool in xwininfo xprop; do command -v "$tool" >/dev/null || missing+=("$tool"); done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing in dom0: ${missing[*]}" >&2
    echo "  sudo qubes-dom0-update xorg-x11-utils   # provides xwininfo/xprop" >&2
    exit 1
fi

cat > "$SVC" <<'EOF'
#!/bin/bash
# Geometry-only window list for a testbed guest. PLAIN TEXT to stdout, no tar, no image. One line
# per window owned by the target VM (by _QUBES_VMNAME), INCLUDING override-redirect windows
# (toasts/menus, absent from _NET_CLIENT_LIST) so the caller can find them without cutting a PNG.
set -uo pipefail
VM="${QREXEC_SERVICE_ARGUMENT:-${1##*+}}"
[ -n "$VM" ] || { echo "no target: call as local.WinGeom+<vm>" >&2; exit 1; }
if ! qvm-tags "$VM" list 2>/dev/null | grep -qx win-idd-testbed; then
    echo "refused: '$VM' lacks the win-idd-testbed tag" >&2; exit 1
fi

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
X=(sudo -u "$DOMUSER" env DISPLAY="$DISP" XAUTHORITY="$XA")

# Same emission as local.WinFullScreen's geometry block, verbatim, minus the PNG capture.
echo "# id x y w h override_redirect mapped name"
"${X[@]}" xwininfo -root -tree 2>/dev/null |
  grep -oE '0x[0-9a-f]+' | sort -u | while read -r id; do
    owner=$("${X[@]}" xprop -id "$id" _QUBES_VMNAME 2>/dev/null |
            sed -n 's/^_QUBES_VMNAME(STRING) = "\(.*\)"$/\1/p')
    [ "$owner" = "$VM" ] || continue
    info=$("${X[@]}" xwininfo -id "$id" -stats 2>/dev/null) || continue
    x=$(printf '%s' "$info" | sed -n 's/.*Absolute upper-left X: *\([0-9-]*\).*/\1/p' | head -1)
    y=$(printf '%s' "$info" | sed -n 's/.*Absolute upper-left Y: *\([0-9-]*\).*/\1/p' | head -1)
    w=$(printf '%s' "$info" | sed -n 's/.*Width: *\([0-9]*\).*/\1/p' | head -1)
    h=$(printf '%s' "$info" | sed -n 's/.*Height: *\([0-9]*\).*/\1/p' | head -1)
    ovr=$(printf '%s' "$info" | grep -c 'Override Redirect State: yes')
    name=$("${X[@]}" xprop -id "$id" WM_NAME 2>/dev/null |
           sed -n 's/^WM_NAME(\(STRING\|UTF8_STRING\)) = "\(.*\)"$/\2/p' | head -1)
    ms=$(printf '%s' "$info" | grep -c 'Map State: IsViewable')
    echo "$id ${x:-?} ${y:-?} ${w:-?} ${h:-?} $ovr $ms ${name:-?}"
done
EOF
chmod 755 "$SVC"

if [ ! -f "$POLICY" ] || ! grep -q 'local.WinGeom' "$POLICY" 2>/dev/null; then
    printf 'local.WinGeom * %s dom0 allow\n' "$CALLER" >> "$POLICY"
    chmod 664 "$POLICY"
    echo "policy: added 'local.WinGeom * $CALLER dom0 allow' to $POLICY"
else
    echo "policy: local.WinGeom already present in $POLICY"
fi

echo "installed $SVC"
echo "self-test: call it from $CALLER as  qrexec-client-vm dom0 local.WinGeom+<a-testbed-vm>"
echo "expected: sub-second, a '# id x y w h ...' header + one line per that VM's windows (o-r included)."
