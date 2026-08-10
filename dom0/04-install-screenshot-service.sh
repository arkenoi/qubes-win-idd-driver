#!/bin/bash
# Run IN DOM0. Installs local.WinScreenshot: captures ONLY the windows of the qube named in
# the qrexec +argument, GATED by the win-idd-testbed tag. The tag is set by dom0 and cannot be
# forged from inside a VM, so this auto-tracks whatever test guests carry it and is NEVER
# hard-keyed to a single VM again (the old build baked win-idd-test into the service; deleting
# that VM silently broke every screenshot with no error). Never captures the rest of the desktop.
# Usage: ./04-install-screenshot-service.sh
set -euo pipefail

SVC=/etc/qubes-rpc/local.WinScreenshot

# dependencies in dom0
for tool in xprop import; do
    command -v "$tool" >/dev/null || {
        echo "Missing '$tool' in dom0 — install with: sudo qubes-dom0-update xdotool ImageMagick" >&2
        exit 1
    }
done

# NB: quoted heredoc (<<'EOF') - nothing expands at install time; every $ is a RUNTIME var.
cat > "$SVC" <<'EOF'
#!/bin/bash
# Screenshot all visible windows of the requested testbed VM; tar of PNGs on stdout.
#
# Target = the qrexec +argument, GATED by the win-idd-testbed tag. Two properties:
#   1. Self-maintaining: any guest carrying win-idd-testbed is served; a deleted guest cannot
#      break it, a new one needs no edit here. This replaces a baked-in VM name.
#   2. Secure: windows are selected by the _QUBES_VMNAME X property (set by dom0's gui-daemon,
#      NOT the guest-controlled title) and the target is confined to the tag, so a caller
#      cannot request another qube's windows.
set -u
# The +arg reaches an RPC service as $QREXEC_SERVICE_ARGUMENT (canonical). Some builds also
# hand the full "name+arg" as $1 (the resize sibling relies on that), so fall back to it.
VM="${QREXEC_SERVICE_ARGUMENT:-}"
[ -n "$VM" ] || VM="${1##*+}"
[ -n "$VM" ] || { echo "no target: call as local.WinScreenshot+<vm>" >&2; exit 1; }
qvm-tags "$VM" list 2>/dev/null | grep -qx win-idd-testbed || {
    echo "refused: '$VM' lacks the win-idd-testbed tag" >&2; exit 1; }

# Locate the live graphical session rather than assuming uid 1000 / ~/.Xauthority
# (lightdm keeps the cookie in /run/lightdm/<user>/xauthority).
DOMUSER=$(getent passwd 1000 | cut -d: -f1)
DISP="${DISPLAY:-:0}"
XA=""
for c in "/run/lightdm/$DOMUSER/xauthority" "/home/$DOMUSER/.Xauthority" \
         /run/user/$(id -u "$DOMUSER" 2>/dev/null)/xauth_* ; do
    [ -r "$c" ] || continue
    if sudo -u "$DOMUSER" env DISPLAY="$DISP" XAUTHORITY="$c" \
           xprop -root -notype _NET_SUPPORTED >/dev/null 2>&1; then XA="$c"; break; fi
done
if [ -z "$XA" ]; then
    echo "ERROR: no usable X session for $DOMUSER on $DISP" >&2
    exit 2
fi
XENV=(env DISPLAY="$DISP" XAUTHORITY="$XA")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
chown "$DOMUSER" "$TMP" 2>/dev/null || chmod 0777 "$TMP"

i=0; seen=0
for wid in $(sudo -u "$DOMUSER" "${XENV[@]}" xprop -root _NET_CLIENT_LIST 2>/dev/null \
              | sed 's/.*# *//' | tr -d ' ' | tr ',' '\n' | grep '^0x'); do
    seen=$((seen+1))
    owner=$(sudo -u "$DOMUSER" "${XENV[@]}" xprop -id "$wid" _QUBES_VMNAME 2>/dev/null \
            | sed -n 's/^_QUBES_VMNAME(STRING) = "\(.*\)"$/\1/p')
    [ "$owner" = "$VM" ] || continue
    if sudo -u "$DOMUSER" "${XENV[@]}" import -window "$wid" "$TMP/win-$i.png" 2>/dev/null; then
        i=$((i+1))
    fi
done

if [ "$i" -eq 0 ]; then
    echo "no $VM windows (X ok as $DOMUSER on $DISP; $seen managed windows scanned)" >&2
    exit 1
fi
tar -C "$TMP" -cf - .
EOF

chmod 755 "$SVC"
echo "Installed $SVC (target = qrexec +arg, gated by the win-idd-testbed tag)."
echo "Test from win-idd-mgmt:  qrexec-client-vm dom0 local.WinScreenshot+win11-fresh > shots.tar"
