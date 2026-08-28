#!/bin/bash
# Run IN DOM0. Installs local.WinWindowShot: captures the requested qube's OWN dom0 window(s)
# and nothing else, then SELF-TESTS so failures surface here instead of as an opaque empty tar
# in the dev qube.
#
# WHY THIS EXISTS (2026-08-29)
# local.WinScreenshot (04-install-screenshot-service.sh) already captures per-window, selecting by
# the dom0-set _QUBES_VMNAME property. It is the right shape and it is what should be used. The
# belief that it "cannot see" a guest without a gui-agent session, which is what sent this project
# to whole-desktop capture, was never tested. When it finally was, the guest window in question
# turned out to be an ordinary managed window and the two REAL causes were elsewhere:
#   1. The caller asked about a qube that does not exist (`tools/qtest` defaulted to win-idd-test,
#      long gone). The service refuses an unknown/untagged target by exiting non-zero having
#      written NOTHING — an empty tar, indistinguishable from "the guest has no windows".
#      tools/qtest now preflights the target and refuses up front.
#   2. tools/winshot.py silently DISCARDED the window: it required 8 whitespace-separated fields
#      per geometry line, so any window whose name was a single token — the bare VM name, or the
#      "?" written when there is no WM_NAME — produced a 7-field line that was skipped, and the
#      tool then reported "no window matching <vm>". Fixed 2026-08-29, with a reproduction.
# Neither cause needed a whole-desktop capture. Three such captures nevertheless reached a PUBLIC
# git repo (sm1-3.tar, commit fbee3ed, found and removed 2026-08-29).
#
# So this service is NOT a workaround for a proven gap in 04. It is the per-window path made
# explicit and diagnosable: it captures ONE WINDOW AT A TIME, never the root window, records which
# rule matched each capture, and on no-match prints WHICH failure mode occurred instead of
# returning an empty tar for the next reader to misdiagnose.
#
# UNVERIFIED, and deliberately marked as such: the title fallback below covers the case where a
# qube's window carries no _QUBES_VMNAME at all. That case is plausible but has NOT been observed
# here — every window actually examined had the property. The fallback is therefore written to be
# harmless if the case never occurs (it runs only when the trusted rule matched nothing, and only
# over windows with no owner property), and its use is recorded in the manifest so a reader can
# see a heuristic match for what it is. Do not cite it as evidence of anything.
#
# local.WinFullScreen remains justified for exactly two things and should be used for nothing
# else: override-redirect windows (menus/tooltips, absent from _NET_CLIENT_LIST) and dom0-side
# rendering defects that are only visible in the composited desktop.
#
# SECURITY
# Target is the qrexec +argument, gated by the win-idd-testbed tag (dom0-set, unforgeable from a
# VM) — same gate as 04. Window selection prefers _QUBES_VMNAME, which the gui-daemon sets and
# the guest cannot influence. The title fallback is used ONLY when _QUBES_VMNAME matched nothing
# at all, is restricted to windows whose _QUBES_VMNAME is ABSENT (never one owned by a different
# qube), and every captured window is recorded in a manifest with the rule that matched it, so a
# reader can tell a trusted match from a heuristic one instead of having to assume.
#
# Remove when finished:
#   sudo rm /etc/qubes-rpc/local.WinWindowShot /etc/qubes/policy.d/30-win-idd-windowshot.policy
set -uo pipefail

SVC=/etc/qubes-rpc/local.WinWindowShot
POLICY=/etc/qubes/policy.d/30-win-idd-windowshot.policy
CALLER=win-idd-mgmt

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

# Only `import` and `xprop` are hard requirements — both are already used by local.WinScreenshot,
# so they are known present. `xwininfo` is OPTIONAL and only buys frame-accurate capture (see
# below); 07 deliberately refused to install packages into dom0 for a debugging nicety and that
# judgement is kept here.
missing=()
for tool in import xprop; do command -v "$tool" >/dev/null || missing+=("$tool"); done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing in dom0: ${missing[*]}" >&2
    echo "  sudo qubes-dom0-update ImageMagick" >&2
    exit 1
fi
if command -v xwininfo >/dev/null; then
    echo "xwininfo present: frame capture enabled (dom0 window borders will be visible)"
else
    echo "xwininfo absent: client-window capture only — dom0-drawn BORDERS WILL NOT APPEAR."
    echo "  This matters if you are checking bordering/decoration behaviour. To enable:"
    echo "    sudo qubes-dom0-update xorg-x11-utils"
fi

# NB: quoted heredoc — nothing expands at install time; every $ below is a RUNTIME variable.
cat > "$SVC" <<'EOF'
#!/bin/bash
# Capture the named qube's own dom0 window(s). tar of win-N.png + manifest.txt on stdout.
# NEVER captures the root window. See the installer header for the security model.
set -u

VM="${QREXEC_SERVICE_ARGUMENT:-}"
[ -n "$VM" ] || VM="${1##*+}"
[ -n "$VM" ] || { echo "no target: call as local.WinWindowShot+<vm>" >&2; exit 1; }
qvm-tags "$VM" list 2>/dev/null | grep -qx win-idd-testbed || {
    echo "refused: '$VM' lacks the win-idd-testbed tag" >&2; exit 1; }

# Locate the live graphical session rather than assuming uid 1000 / ~/.Xauthority.
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
chown "$DOMUSER" "$TMP" 2>/dev/null || chmod 0777 "$TMP"

clients=$("${X[@]}" xprop -root _NET_CLIENT_LIST 2>/dev/null \
          | sed 's/.*# *//' | tr -d ' ' | tr ',' '\n' | grep '^0x')
[ -n "$clients" ] || { echo "ERROR: _NET_CLIENT_LIST empty — no window manager?" >&2; exit 2; }

owner_of() {  # dom0-set, guest cannot forge
    "${X[@]}" xprop -id "$1" _QUBES_VMNAME 2>/dev/null \
        | sed -n 's/^_QUBES_VMNAME(STRING) = "\(.*\)"$/\1/p'
}
title_of() {
    "${X[@]}" xprop -id "$1" _NET_WM_NAME 2>/dev/null \
        | sed -n 's/^_NET_WM_NAME(UTF8_STRING) = "\(.*\)"$/\1/p'
    "${X[@]}" xprop -id "$1" WM_NAME 2>/dev/null \
        | sed -n 's/^WM_NAME(STRING) = "\(.*\)"$/\1/p'
}
# Resolve a client window to the top-level FRAME the WM reparented it into: dom0 draws the
# qube's coloured border on the FRAME, so capturing the client window alone silently loses it.
frame_of() {
    local w="$1" parent root line
    command -v xwininfo >/dev/null || { echo "$w"; return; }
    root=$("${X[@]}" xwininfo -root 2>/dev/null | sed -n 's/^xwininfo: Window id: \(0x[0-9a-f]*\).*/\1/p')
    [ -n "$root" ] || { echo "$w"; return; }
    for _ in 1 2 3 4 5 6 7 8; do
        line=$("${X[@]}" xwininfo -id "$w" -children 2>/dev/null | sed -n 's/^ *Parent window id: \(0x[0-9a-f]*\).*/\1/p')
        [ -n "$line" ] || break
        [ "$line" = "$root" ] && break
        w="$line"
    done
    echo "$w"
}

i=0; scanned=0; : > "$TMP/manifest.txt"
echo "# target=$VM  rule  window-id  frame-id  title" >> "$TMP/manifest.txt"

capture() {  # capture <client-id> <rule>
    local wid="$1" rule="$2" frame png
    frame=$(frame_of "$wid")
    png="win-$i.png"
    # -screen reads the region as COMPOSITED ON SCREEN. Without it X hands back the window's own
    # drawable, which for an obscured or unmapped window is stale or blank. What we want to know
    # is what is actually displayed, so -screen is correct here — with the consequence that an
    # overlapping window WILL appear in the capture. Anything on top of the qube's window is by
    # definition already visible on the same physical screen; this never widens the region beyond
    # that one window's rectangle.
    if "${X[@]}" import -window "$frame" -screen "$TMP/$png" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$png" "$rule" "$wid" "$frame" "$(title_of "$wid" | head -1)" \
            >> "$TMP/manifest.txt"
        i=$((i+1))
    fi
}

# Pass 1 — the trusted rule.
for wid in $clients; do
    scanned=$((scanned+1))
    [ "$(owner_of "$wid")" = "$VM" ] || continue
    capture "$wid" "_QUBES_VMNAME"
done

# Pass 2 — ONLY if pass 1 found nothing: the agent-less guest (Automatic Repair / boot / wedged).
# Restricted to windows with NO _QUBES_VMNAME at all, so a window belonging to another qube can
# never be selected here no matter what its title says.
if [ "$i" -eq 0 ]; then
    for wid in $clients; do
        [ -z "$(owner_of "$wid")" ] || continue
        case "$(title_of "$wid" | tr '\n' ' ')" in
            *"$VM"*) capture "$wid" "title-fallback(no _QUBES_VMNAME)" ;;
        esac
    done
fi

if [ "$i" -eq 0 ]; then
    # Distinguish the failure modes instead of returning an empty tar that reads as "no windows".
    echo "no window found for '$VM'." >&2
    echo "  scanned=$scanned managed windows; none had _QUBES_VMNAME=$VM and none untitled-owner" >&2
    echo "  window mentioned '$VM'. The qube is probably not running, or is running with no" >&2
    echo "  display at all. This is NOT the same as 'the guest has no gui-agent'." >&2
    exit 1
fi
tar -C "$TMP" -cf - .
EOF
chmod 755 "$SVC"

# Policy: only the management qube may call this, and only for a tagged target.
cat > "$POLICY" <<EOF
local.WinWindowShot * $CALLER dom0 allow
local.WinWindowShot * @anyvm  dom0 deny
EOF
chmod 0644 "$POLICY"

echo "Installed $SVC"
echo "Installed $POLICY (caller: $CALLER)"

# ---- SELF-TEST -------------------------------------------------------------------------------
# A check that cannot fail is worthless. This runs the service against a live tagged guest and
# asserts the tar actually contains a PNG; if no tagged guest is running it says so rather than
# reporting a pass it did not earn.
echo
echo "=== self-test ==="
target=""
for vm in $(qvm-ls --raw-list 2>/dev/null); do
    qvm-tags "$vm" list 2>/dev/null | grep -qx win-idd-testbed || continue
    [ "$(qvm-check --running "$vm" 2>/dev/null; echo $?)" = "0" ] || continue
    target="$vm"; break
done
if [ -z "$target" ]; then
    echo "SKIPPED: no running qube carries the win-idd-testbed tag."
    echo "  Start one and re-run:  sudo $0"
    echo "  UNTESTED — do not record this install as verified."
    exit 0
fi
out=$(mktemp); trap 'rm -f "$out"' EXIT
if QREXEC_SERVICE_ARGUMENT="$target" "$SVC" > "$out" 2>/tmp/winwindowshot-selftest.err; then
    n=$(tar -tf "$out" 2>/dev/null | grep -c '\.png$')
    if [ "${n:-0}" -gt 0 ]; then
        echo "PASS: captured $n window(s) from '$target' ($(stat -c%s "$out") bytes)"
        echo "--- manifest ---"; tar -xOf "$out" ./manifest.txt 2>/dev/null || true
    else
        echo "FAIL: service succeeded but the tar holds no PNG." >&2; exit 1
    fi
else
    echo "FAIL: service returned non-zero for '$target'. stderr:" >&2
    cat /tmp/winwindowshot-selftest.err >&2
    exit 1
fi
echo
echo "Call it from $CALLER:"
echo "  qrexec-client-vm dom0 local.WinWindowShot+$target > shot.tar"
