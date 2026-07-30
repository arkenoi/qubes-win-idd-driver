#!/bin/bash
# Run IN DOM0. Installs local.WinScreenshot: captures ONLY windows titled "[win-idd-test]"
# and streams a tar of PNGs to the caller. Never captures the rest of the desktop.
# Usage: ./04-install-screenshot-service.sh [test-qube]
set -euo pipefail

VM="${1:-win-idd-test}"
SVC=/etc/qubes-rpc/local.WinScreenshot

# dependencies in dom0
for tool in xprop import; do
    command -v "$tool" >/dev/null || {
        echo "Missing '$tool' in dom0 — install with: sudo qubes-dom0-update xdotool ImageMagick" >&2
        exit 1
    }
done

cat > "$SVC" <<EOF
#!/bin/bash
# Screenshot all visible windows of $VM; tar of PNGs on stdout. qubes-win-idd kit.
#
# Windows are selected by the _QUBES_VMNAME X property, which qubes-gui-daemon sets in
# dom0 -- NOT by window title. Two reasons:
#   1. Correctness: Qubes does not prefix WM_NAME with the qube name. The "[vm]" you see
#      in the title bar is drawn by the WM decoration from _QUBES_VMNAME, so a title
#      regex like "^\\[\$VM\\]" matches nothing (WM_NAME is just e.g. "Untitled - Notepad").
#   2. Security: window titles are set by the GUEST and are therefore spoofable -- a
#      hostile VM could title itself "[other-vm] ..." to get captured. _QUBES_VMNAME is
#      set by dom0 and cannot be forged from inside a VM.
# A window with no _QUBES_VMNAME (i.e. a native dom0 window) is never captured.
set -u
VM="$VM"

# Locate the live graphical session rather than assuming uid 1000 / ~/.Xauthority
# (lightdm keeps the cookie in /run/lightdm/<user>/xauthority).
DOMUSER=\$(getent passwd 1000 | cut -d: -f1)
DISP="\${DISPLAY:-:0}"
XA=""
for c in "/run/lightdm/\$DOMUSER/xauthority" "/home/\$DOMUSER/.Xauthority" \\
         /run/user/\$(id -u "\$DOMUSER" 2>/dev/null)/xauth_* ; do
    [ -r "\$c" ] || continue
    if sudo -u "\$DOMUSER" env DISPLAY="\$DISP" XAUTHORITY="\$c" \\
           xprop -root -notype _NET_SUPPORTED >/dev/null 2>&1; then XA="\$c"; break; fi
done
if [ -z "\$XA" ]; then
    echo "ERROR: no usable X session for \$DOMUSER on \$DISP" >&2
    exit 2
fi
XENV=(env DISPLAY="\$DISP" XAUTHORITY="\$XA")

TMP=\$(mktemp -d)
trap 'rm -rf "\$TMP"' EXIT

i=0; seen=0
for wid in \$(sudo -u "\$DOMUSER" "\${XENV[@]}" xprop -root _NET_CLIENT_LIST 2>/dev/null \\
              | sed 's/.*# *//' | tr -d ' ' | tr ',' '\\n' | grep '^0x'); do
    seen=\$((seen+1))
    owner=\$(sudo -u "\$DOMUSER" "\${XENV[@]}" xprop -id "\$wid" _QUBES_VMNAME 2>/dev/null \\
            | sed -n 's/^_QUBES_VMNAME(STRING) = "\\(.*\\)"\$/\\1/p')
    [ "\$owner" = "\$VM" ] || continue
    if sudo -u "\$DOMUSER" "\${XENV[@]}" import -window "\$wid" "\$TMP/win-\$i.png" 2>/dev/null; then
        i=\$((i+1))
    fi
done

if [ "\$i" -eq 0 ]; then
    echo "no \$VM windows (X ok as \$DOMUSER on \$DISP; \$seen managed windows scanned)" >&2
    exit 1
fi
tar -C "\$TMP" -cf - .
EOF

chmod 755 "$SVC"
echo "Installed $SVC (captures only windows titled [$VM])."
echo "Test from the dev qube:  qrexec-client-vm dom0 local.WinScreenshot > shots.tar"
