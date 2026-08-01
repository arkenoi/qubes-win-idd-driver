#!/bin/bash
# Run IN DOM0. Installs a small user-session watcher that mirrors dom0's usable
# workspace geometry into win-idd-test's QubesDB, so the Windows agent can size
# maximized windows to fit (see DESIGN-workarea-propagation.md, alternative A).
#
# What it writes, on every _NET_WORKAREA change (panel moved, monitor hotplug):
#   qubesdb-write -d win-idd-test /qubes-workarea "x y w h fl fr ft fb"
# where x/y/w/h is the current desktop's work area (dom0 root coordinates) and
# fl/fr/ft/fb are the WM frame extents measured from any managed VM window
# (fallback 0 0 0 0 until one exists; the agent treats zeros as "no reserve").
#
# No gui-daemon change, no policy change (dom0-local + qubesdb only). Remove with:
#   rm ~/.local/bin/qubes-win-workarea-watch.sh ~/.config/autostart/qubes-win-workarea.desktop
set -euo pipefail

VM=win-idd-test
BIN=~/.local/bin/qubes-win-workarea-watch.sh
AUTOSTART=~/.config/autostart/qubes-win-workarea.desktop

mkdir -p ~/.local/bin ~/.config/autostart

cat > "$BIN" <<'EOF'
#!/bin/bash
# Mirror dom0 work area + frame extents into a VM's QubesDB. See installer header.
VM="${1:-win-idd-test}"

current_value() {
    local desk wa idx x y w h fx
    desk=$(xprop -root -notype _NET_CURRENT_DESKTOP 2>/dev/null | awk '{print $3}')
    [ -n "$desk" ] || desk=0
    # _NET_WORKAREA: x,y,w,h per desktop
    wa=$(xprop -root -notype _NET_WORKAREA 2>/dev/null | sed 's/.*= //; s/,//g')
    idx=$((desk * 4))
    read -r -a arr <<< "$wa"
    x=${arr[$idx]:-0}; y=${arr[$((idx+1))]:-0}
    w=${arr[$((idx+2))]:-0}; h=${arr[$((idx+3))]:-0}

    # frame extents from any managed window of this VM (l, r, t, b)
    local fl=0 fr=0 ft=0 fb=0 wid
    for wid in $(xdotool search --name "^\[$VM\]" 2>/dev/null | head -5); do
        fx=$(xprop -id "$wid" -notype _NET_FRAME_EXTENTS 2>/dev/null | sed 's/.*= //; s/,//g')
        if [ -n "$fx" ] && [ "$fx" != "_NET_FRAME_EXTENTS:  not found." ]; then
            read -r fl fr ft fb <<< "$fx"
            break
        fi
    done

    echo "$x $y $w $h ${fl:-0} ${fr:-0} ${ft:-0} ${fb:-0}"
}

last=""
push() {
    local v
    v=$(current_value)
    if [ "$v" != "$last" ] && [ -n "$v" ]; then
        if qubesdb-write -d "$VM" /qubes-workarea "$v" 2>/dev/null; then
            last="$v"
            logger -t qubes-win-workarea "pushed to $VM: $v"
        fi
    fi
}

push
# Re-check on every root-window property change (covers _NET_WORKAREA and
# desktop switches) plus a slow safety poll for VM restarts (fresh qubesdb).
xprop -root -spy _NET_WORKAREA 2>/dev/null | while read -r _; do
    push
done &
SPY=$!
trap 'kill $SPY 2>/dev/null' EXIT
while sleep 60; do
    last=""   # force re-push so a restarted VM's empty qubesdb gets repopulated
    push
done
EOF
chmod +x "$BIN"

cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Qubes Windows work-area watcher ($VM)
Exec=$BIN $VM
X-GNOME-Autostart-enabled=true
EOF

# start it now (idempotent enough: kill a previous instance first)
pkill -f "qubes-win-workarea-watch.sh" 2>/dev/null || true
nohup "$BIN" "$VM" >/dev/null 2>&1 &
echo "Installed and started. Verify from the mgmt qube:"
echo "  tools/qtest run '\"C:\\Program Files\\Qubes Tools\\bin\\qubesdb-cmd.exe\" -c read /qubes-workarea'"
