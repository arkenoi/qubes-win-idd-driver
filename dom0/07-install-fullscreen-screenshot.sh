#!/bin/bash
# Install a dom0 qrexec service returning a FULL DESKTOP screenshot to win-idd-mgmt,
# then SELF-TEST it so failures surface here rather than as an opaque error in the dev qube.
#
# SECURITY NOTE - read before installing.
# local.WinScreenshot deliberately captures ONLY win-idd-test's windows, so the management VM
# never sees other qubes' content. This service does NOT have that property: it photographs
# the whole dom0 display, every other qube's windows included.
#
# It exists because defects in the dom0 *rendering* - window borders, the rectangle drawn over
# menus, desktop artifacts - are invisible to the per-window service by construction: menus are
# override-redirect (absent from _NET_CLIENT_LIST) and decorations are drawn on the frame, not
# on the client window that `import -window` captures.
#
# Remove when finished:   sudo rm /etc/qubes-rpc/local.WinFullScreen
set -uo pipefail

SVC=/etc/qubes-rpc/local.WinFullScreen
POLICY=/etc/qubes/policy.d/30-win-idd-fullscreen.policy
CALLER=win-idd-mgmt

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

# Only `import` and `xprop` are required - both are already used by the existing
# local.WinScreenshot service, so they are known to be present. `xwininfo` is NOT required:
# it only adds the per-window geometry listing, and installing extra packages into dom0 to get
# a debugging nicety is a bad trade. Without it the full-desktop PNG is still produced.
missing=()
for tool in import xprop; do command -v "$tool" >/dev/null || missing+=("$tool"); done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing in dom0: ${missing[*]}" >&2
    echo "  sudo qubes-dom0-update ImageMagick" >&2
    exit 1
fi
if command -v xwininfo >/dev/null; then
    echo "xwininfo present: geometry listing enabled"
else
    echo "xwininfo absent: screenshot only, no geometry listing (this is fine)"
fi

cat > "$SVC" <<'EOF'
#!/bin/bash
# Full-desktop screenshot. Returns a tar with screen.png and geometry.txt (every win-idd-test
# window INCLUDING override-redirect ones and frames, so the caller can crop without guessing).
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
X=(sudo -u "$DOMUSER" env DISPLAY="$DISP" XAUTHORITY="$XA")

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# The service runs as root, so mktemp -d gives a 0700 root-owned directory - but the capture
# runs as the desktop user through `sudo -u`, which then cannot write into it. This is what
# made every method fail with "Permission denied ... WriteBlob Failed".
chown "$DOMUSER" "$TMP" 2>/dev/null || chmod 0777 "$TMP"

# `import -window root` alone is unreliable: without -screen it grabs the root window's own
# contents rather than the composited screen, and on some setups it fails outright. Try the
# variants in order of fidelity and REPORT the real error instead of swallowing it - the first
# version of this script hid the reason and just said "capture failed".
CAP_ERR="$TMP/cap.err"
captured=""
if "${X[@]}" import -screen -window root "$TMP/screen.png" 2>>"$CAP_ERR" && [ -s "$TMP/screen.png" ]; then
    captured="import -screen -window root"
elif "${X[@]}" import -window root "$TMP/screen.png" 2>>"$CAP_ERR" && [ -s "$TMP/screen.png" ]; then
    captured="import -window root"
elif command -v xwd >/dev/null &&
     "${X[@]}" xwd -root -silent > "$TMP/screen.xwd" 2>>"$CAP_ERR" && [ -s "$TMP/screen.xwd" ] &&
     convert "$TMP/screen.xwd" "$TMP/screen.png" 2>>"$CAP_ERR" && [ -s "$TMP/screen.png" ]; then
    captured="xwd -root | convert"
    rm -f "$TMP/screen.xwd"
elif command -v gnome-screenshot >/dev/null &&
     "${X[@]}" gnome-screenshot -f "$TMP/screen.png" 2>>"$CAP_ERR" && [ -s "$TMP/screen.png" ]; then
    captured="gnome-screenshot"
fi

if [ -z "$captured" ]; then
    echo "ERROR: every root-window capture method failed. Tool output:" >&2
    sed 's/^/  /' "$CAP_ERR" >&2
    echo "  tried: import -screen -window root | import -window root | xwd+convert | gnome-screenshot" >&2
    exit 3
fi
echo "capture method: $captured" >&2

# Geometry is best effort and must never abort the capture: the PNG is the point. It also
# requires xwininfo, which dom0 may not have - absence is not an error.
{
    echo "# id x y w h override_redirect name"
    command -v xwininfo >/dev/null || echo "# xwininfo not installed in dom0 - geometry omitted"
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
        echo "$id ${x:-?} ${y:-?} ${w:-?} ${h:-?} $ovr ${name:-?}"
    done
} > "$TMP/geometry.txt" 2>/dev/null || true

tar -C "$TMP" -cf - .
EOF
chmod 755 "$SVC"

# The existing local.WinScreenshot policy was configured by hand, so do not assume a file -
# write our own, which is evaluated alongside the others.
if [ ! -f "$POLICY" ] || ! grep -q 'local.WinFullScreen' "$POLICY" 2>/dev/null; then
    printf 'local.WinFullScreen * %s dom0 allow\n' "$CALLER" >> "$POLICY"
    chmod 664 "$POLICY"
    echo "policy: added 'local.WinFullScreen * $CALLER dom0 allow' to $POLICY"
else
    echo "policy: already present in $POLICY"
fi

echo
echo "== self-test =="
OUT=$(mktemp -d)
cleanup() { rm -rf "$OUT"; }
trap cleanup EXIT

"$SVC" < /dev/null > "$OUT/t.tar" 2>"$OUT/t.err"
rc=$?
if [ $rc -ne 0 ]; then
    echo "  FAIL: service exited $rc"
    sed 's/^/    /' "$OUT/t.err"
    exit 4
fi

tar -xf "$OUT/t.tar" -C "$OUT" 2>/dev/null

if [ ! -s "$OUT/screen.png" ]; then
    echo "  FAIL: tar produced no screen.png"
    sed 's/^/    /' "$OUT/t.err"
    exit 4
fi

dims=$(identify -format '%wx%h' "$OUT/screen.png" 2>/dev/null || echo '?')
bytes=$(stat -c%s "$OUT/screen.png")
echo "  OK  screen.png $dims ($bytes bytes)"
grep -h 'capture method' "$OUT/t.err" 2>/dev/null | sed 's/^/  /'

if command -v xwininfo >/dev/null 2>&1; then
    gcount=$(grep -vc '^#' "$OUT/geometry.txt" 2>/dev/null || true)
    echo "  OK  geometry.txt: ${gcount:-0} window(s) listed"
else
    echo "  --  geometry omitted (no xwininfo); the screenshot is what matters"
fi

echo
echo "Installed $SVC and self-tested."
echo "It captures the WHOLE screen, other qubes included. Remove with:"
echo "  sudo rm $SVC $POLICY"
