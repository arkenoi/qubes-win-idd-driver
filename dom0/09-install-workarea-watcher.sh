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
# No gui-daemon change, no policy change (dom0-local + qubesdb only).
#
# Usage:  sudo -u <dom0 user> ./09-install-workarea-watcher.sh [VM]     (default: win-idd-test)
#         ./09-install-workarea-watcher.sh --uninstall
#
# UNINSTALL EXISTS BECAUSE THIS THING OUTLIVES ITS EXPERIMENT (owner, 2026-09-01: "we have
# some leftover that pushes dom0 workarea geometry to win-idd-test"). It autostarts at every
# dom0 login and targets ONE hard-coded guest, so it silently makes that guest a different
# experimental subject from every other testbed qube - the agent has a qubesdb watch on
# /qubes-workarea, and workarea churn is measured in FINDINGS at 12.2 applies/s on a pre-fix
# agent. An undeclared per-guest input is exactly the kind of thing that voids a comparison.
# It cannot start a halted VM (qubesdb-write talks to a dom0-local socket, not qrexec); on a
# halted guest it just fails silently once a minute.
set -euo pipefail

if [ "${1:-}" = "--uninstall" ]; then
    pkill -f "qubes-win-workarea-watch.sh" 2>/dev/null || true
    rm -f ~/.local/bin/qubes-win-workarea-watch.sh \
          ~/.config/autostart/qubes-win-workarea.desktop
    echo "removed watcher + autostart entry; killed any running instance"
    echo "NOTE: the last pushed value stays in the VM's qubesdb until it is next shut down."
    echo "      Clear it now with:  qubesdb-rm -d <vm> /qubes-workarea"
    exit 0
fi

VM="${1:-win-idd-test}"
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

    # frame extents from any managed window of this VM (l, r, t, b).
    # Select by _QUBES_VMNAME - dom0-set and unforgeable; WM_NAME never carries
    # "[vm]" (that text is WM decoration), so the old title match never found a
    # window and the extents silently stayed at the 0 fallback (measured: real
    # title bar is ~25 px; M6 maximize sizes would poke under the panel).
    local fl=0 fr=0 ft=0 fb=0 wid owner
    for wid in $(xprop -root _NET_CLIENT_LIST 2>/dev/null | sed 's/.*# *//; s/,//g'); do
        owner=$(xprop -id "$wid" _QUBES_VMNAME 2>/dev/null | sed -n 's/^_QUBES_VMNAME(STRING) = "\(.*\)"$/\1/p')
        [ "$owner" = "$VM" ] || continue
        fx=$(xprop -id "$wid" -notype _NET_FRAME_EXTENTS 2>/dev/null | sed 's/.*= //; s/,//g')
        case "$fx" in
            *[0-9]*) read -r fl fr ft fb <<< "$fx"; break ;;
        esac
    done

    echo "$x $y $w $h ${fl:-0} ${fr:-0} ${ft:-0} ${fb:-0}"
}

push() {
    local v stored
    v=$(current_value)
    [ -n "$v" ] || return 0
    # Compare against what the VM ACTUALLY holds, not a local cache. The cache version had
    # to clear itself every 60 s so a restarted guest's fresh qubesdb got repopulated - which
    # meant an unconditional write + syslog line every single minute, forever. Reading back
    # covers the restart case for free and writes only on a real change.
    stored=$(qubesdb-read -d "$VM" /qubes-workarea 2>/dev/null) || stored=""
    [ "$v" = "$stored" ] && return 0
    if qubesdb-write -d "$VM" /qubes-workarea "$v" 2>/dev/null; then
        logger -t qubes-win-workarea "pushed to $VM: $v"
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
    push   # safety net for VM restarts; push() read-backs, so this is a no-op when unchanged
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
