#!/bin/bash
# Clone a HALTED Windows StandaloneVM into a TemplateVM, then create an AppVM on it.
# This is the configuration in forum 42717 post 56 ("an AppVM based on the Windows 10
# template starts and then shuts down silently") and nothing in this project had ever
# exercised it - every test guest here is standalone.
#
# Usage: mgmt/clone-to-template.sh <src-standalone> <new-template> <new-appvm>
#
# qvm-clone in one shot FAILS on this testbed: policy is tag-based, and qvm-clone creates
# the qube and copies volumes into it BEFORE the tags are applied, so the volume call hits
# a qube policy does not yet cover. Create, tag, then copy - that order satisfies policy.
set -u
HINT_NETVM=""
SRC="${1:?usage: $0 <src-standalone> <new-template> <new-appvm>}"
TPL="${2:?}"
APP="${3:?}"

log() { echo "$(date -u +%H:%M:%S) clone-to-template: $*"; }
state() { qvm-ls --raw-data --fields state "$1" 2>/dev/null; }

[ "$(state "$SRC")" = Halted ] || { log "FAIL: $SRC must be Halted (a running source gives an inconsistent copy)"; exit 1; }

# APP first: a TemplateVM cannot be removed while a qube is still based on it, so removing $TPL
# ahead of $APP fails outright on any re-run over an existing pair.
for v in "$APP" "$TPL"; do
    if qvm-check "$v" >/dev/null 2>&1; then
        log "removing existing $v"
        timeout 120 qvm-shutdown --wait "$v" >/dev/null 2>&1
        timeout 300 qvm-remove -f "$v" >/dev/null 2>&1 || { log "FAIL: could not remove $v"; exit 1; }
    fi
done

log "creating template $TPL"
qvm-create --class TemplateVM --label red "$TPL" || exit 1
qvm-tags "$TPL" add win-idd-testbed || exit 1

python3 - "$SRC" "$TPL" <<'EOF' || exit 1
import sys, qubesadmin
app = qubesadmin.Qubes()
src, dst = app.domains[sys.argv[1]], app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
# A fresh TemplateVM's defaults are Linux-shaped: without virt_mode=hvm and an EMPTY kernel
# the guest never reaches its own bootloader.
for p in ('virt_mode', 'kernel', 'memory', 'maxmem', 'vcpus', 'qrexec_timeout', 'netvm'):
    setattr(dst, p, getattr(src, p))
for f in ('os', 'gui', 'qrexec', 'stubdom-qrexec', 'vmexec', 'audio-model', 'timezone',
          'no-monitor-layout', 'rpc-clipboard', 'gui-emulated'):
    try:
        dst.features[f] = src.features[f]
    except KeyError:
        pass
print('cloned volumes, prefs and features')
EOF

log "creating AppVM $APP on $TPL"
qvm-create --class AppVM --template "$TPL" --label red "$APP" || exit 1
qvm-tags "$APP" add win-idd-testbed || exit 1
for p in virt_mode kernel memory maxmem vcpus qrexec_timeout netvm; do
    v=$(qvm-prefs "$TPL" "$p" 2>/dev/null)
    qvm-prefs "$APP" "$p" "$v" >/dev/null 2>&1
done

# --- install the PV network device, which our offline install skipped --------------------
# THIS IS NOT A NEW STEP - it restores what a STOCK install gets for free. qvm-create-windows-qube
# creates the qube with its default netvm, so a vif is present throughout Windows and QWT setup:
# xennet installs THEN, and the installer's own reboot completes it. Our provisioning strips the
# netvm first (mgmt/reprovision-usb.sh, per the offline-rig rule), so the PV NIC is never installed
# at all and the debt is passed to the first app qube that gets a network.
#
# The debt is unpayable there. The first time a vif appears, Windows installs xennet on the XENVIF
# NET child and the device lands in CM_PROB_NEED_RESTART (problem 14) - it cannot start until a
# reboot. A template's persistent root completes that once. An app qube's volatile root discards it
# every boot, so it reinstalls, demands a restart, resets, and Qubes halts it. Measured: an app qube
# from a template installed offline dies ~4 s after DHCP forever; from one where the install
# completed, it runs indefinitely.
#
# It cannot be done without a vif: on a template that has never been networked there is NO VIF class
# device, NO NET child and NO xennet service - the devnodes exist only once a vif has appeared.
#
# THE TEMPLATE STILL NEVER REACHES A NETWORK: the netvm is attached with a drop-everything firewall,
# so the device is enumerated and the driver install completes while no traffic can leave, then it
# is detached again.
# MEASURED 2026-08-17 on win10-tpl: reaching a STARTED PV NIC takes THREE clean boots, and the
# intermediate states are what makes an AppVM unusable rather than merely slow:
#
#   boot 1  vif appears, PnP stages the package (xennet.sys + oemN.inf on disk)  problem 19
#   boot 2  the service key is created, device demands a restart                 problem 14
#   boot 3  device starts, adapter Up, emulated RTL8139 unplugged                problem 0
#
# An AppVM can never get past boot 2: problem 14 means "restart to finish", the guest restarts,
# and its VOLATILE root discards the half-finished install - that is the reset loop, in full.
# The template's persistent root keeps it, so the AppVM inherits a device that is already done.
#
# Waiting a fixed two minutes (what this did before) is NOT equivalent: it happened to survive
# on an already-primed template and silently produced a template stuck at problem 14 otherwise.
# So boot until the guest itself reports problem 0, and FAIL LOUDLY if it never does - a template
# that ships half-installed breaks every app qube built on it, which is exactly how this shipped.
pvnic_problem() {
    # Guest-reported CM_PROB_* for the PV NIC devnode, or empty if unreachable. Guest output is
    # untrusted data: only ever compared against a literal, never executed.
    #
    # The value MUST be delimited. Scraping digits out of the raw console (an early version did
    # `tr -cd 0-9`) also scrapes the Windows banner and the `system32` prompt, so every reading
    # came back as a meaningless 19-digit run - a probe that cannot report a wrong answer because
    # it never reports a usable one.
    printf '%s\n' "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"Write-Output ('QPROB=' + (Get-PnpDeviceProperty -InstanceId 'XENVIF\\VEN_XP&DEV_NET\\0' -KeyName 'DEVPKEY_Device_ProblemCode' -EA SilentlyContinue).Data + '=END')\"" \
        | timeout 30 qrexec-client-vm "$1" qubes.VMShell 2>/dev/null \
        | sed -n 's/.*QPROB=\([0-9]*\)=END.*/\1/p' | head -1
}

guest_alive() {
    # LIVENESS ONLY, and deliberately NOT pvnic_problem(). On the offline settle boot there is no
    # XENVIF device, so the problem-code probe returns empty on a perfectly healthy guest - using it
    # for liveness makes the settle boot time out and abort the run every time.
    printf '%s\n' "echo QALIVE_OK" \
        | timeout 30 qrexec-client-vm "$1" qubes.VMShell 2>/dev/null | grep -q QALIVE_OK
}

wait_alive() {
    # Bounded by WALL CLOCK, not by iteration count: with a per-probe timeout an iteration budget
    # silently becomes hours when the guest stops answering, which is exactly when you need it to
    # give up. Returns 0 as soon as the guest answers.
    local vm="$1" deadline=$(( SECONDS + ${2:-300} ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        guest_alive "$vm" && return 0
        sleep 10
    done
    return 1
}

latch_readback() {
    # Guest-reported latch state, delimited (see FINDINGS on why raw console scraping lies).
    printf '%s\n' "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"\$u=Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\XEN\\Unplug' -EA SilentlyContinue; \$k=Test-Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Enum\\XENBUS\\VEN_XP0001&DEV_VIF'; schtasks /query /tn QubesPvNic 2>\$null | Out-Null; \$t=(\$LASTEXITCODE -eq 0); Write-Output ('QLATCH=' + \$u.NICS + ',' + \$k + ',' + \$t + '=END')\"" \
        | timeout 60 qrexec-client-vm "$1" qubes.VMShell 2>/dev/null \
        | sed -n 's/.*QLATCH=\(.*\)=END.*/\1/p' | head -1
}

prime_latch() {
    # NETVM-FREE priming (measured + source-verified 2026-08-18, adversarially reviewed):
    # seed the PV drivers' emulated-NIC unplug latch (Services\XEN\Unplug\NICS=1 + the
    # Enum\XENBUS VIF veto key) plus two SYSTEM tasks that (a) re-arm it every boot - xen.sys
    # DELETES the value on every read, so an unattended template boot would otherwise strip
    # the seed - and (b) apply the qubesdb network config to the per-boot freshly installed
    # PV adapter, loudly failing into a marker + user-visible alert if it cannot.
    # With this seed an AppVM's first vif install completes in ONE boot at problem 0 (both
    # xenvif reboot triggers are cleared: the RTL8139 is unplugged pre-NDIS and the in-memory
    # unplug request is latched), and the applier lands the per-VM IP each boot.
    # The template NEVER gets a netvm. Trade-off vs vif priming: every AppVM boot performs a
    # fresh driver install (~40 s to network vs near-instant on a vif-primed template).
    local vm="$1" repo; repo="$(cd "$(dirname "$0")/.." && pwd)"

    log "settle boot (offline) before seeding the latch"
    qvm-prefs "$vm" netvm '' >/dev/null 2>&1
    qvm-start "$vm" >/dev/null 2>&1
    wait_alive "$vm" 420 || { log "FAIL: $vm never answered qrexec on its settle boot"; return 1; }

    log "installing latch seed + tasks (guest/pvnic-selfprime.ps1)"
    local out
    out="$(QTEST_VM=$vm "$repo/tools/qtest" pushrun "$repo/guest/pvnic-selfprime.ps1" 2>/dev/null | tr -d '\r' | grep -A1 '^MARKJSON' | tail -1)"
    case "$out" in
        *'"ok":true'*) log "  installer: ok ($(printf '%s' "$out" | sed -n 's/.*"payload_sha256":"\([a-f0-9]\{12\}\).*/payload \1.../p'))" ;;
        *) log "FAIL: latch installer did not report ok - guest said: ${out:-<nothing>}"; return 1 ;;
    esac
    timeout 300 qvm-shutdown --wait "$vm" >/dev/null 2>&1 || { log "FAIL: clean shutdown after seeding"; return 1; }

    # The consume->re-arm cycle must be PROVEN on this template, not assumed: boot once more,
    # confirm the boot task re-wrote NICS=1 (xen.sys consumed it seconds into the boot), then
    # clean-shut. Registry state only counts after a clean shutdown.
    log "verification boot (latch must re-arm itself)"
    qvm-start "$vm" >/dev/null 2>&1
    wait_alive "$vm" 420 || { log "FAIL: $vm never answered qrexec on the verification boot"; return 1; }
    local rb='' deadline=$(( SECONDS + 180 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        rb="$(latch_readback "$vm")"
        [ "$rb" = "1,True,True" ] && break
        sleep 10
    done
    timeout 300 qvm-shutdown --wait "$vm" >/dev/null 2>&1
    if [ "$rb" != "1,True,True" ]; then
        log "FAIL: latch readback after a full boot cycle = '${rb:-<unreachable>}' (want 1,True,True)."
        log "      Template would ship latched-broken. Not shipping it."
        return 1
    fi
    log "latch primed and self-healing (NICS=1, veto key, tasks verified across a boot cycle); $vm never had a netvm"
}

prime_pv_nic() {
    local vm="$1" net="$2"
    [ -n "$net" ] || { log "no netvm given, skipping PV NIC priming (app qubes will loop when networked)"; return 0; }

    # SETTLE BOOT FIRST, OFFLINE. Measured 2026-08-17: attaching a vif to the FIRST boot of a
    # freshly cloned template wedges it - black screen, no qrexec, still dead after 12 minutes.
    # The same clone booted with no netvm answered qrexec in 8 seconds. Windows has post-clone
    # work to do (it is a new machine to it) and a brand-new network device on top of that is
    # what breaks it, so let it complete one quiet boot before the vif ever appears.
    log "settle boot (offline) before attaching a vif"
    qvm-prefs "$vm" netvm '' >/dev/null 2>&1
    qvm-start "$vm" >/dev/null 2>&1
    wait_alive "$vm" 420 || { log "FAIL: $vm never answered qrexec on its offline settle boot"; return 1; }
    timeout 300 qvm-shutdown --wait "$vm" >/dev/null 2>&1

    log "installing PV network device on $vm via $net (all traffic blocked)"
    qvm-prefs "$vm" netvm "$net" || return 1
    qvm-firewall "$vm" reset >/dev/null 2>&1
    qvm-firewall "$vm" add action=drop >/dev/null 2>&1

    local boot prob=''
    for boot in 1 2 3 4 5; do
        qvm-start "$vm" >/dev/null 2>&1
        wait_alive "$vm" 420 || log "  boot $boot: guest never answered qrexec"
        # qrexec answering does not mean PnP has enumerated the device yet; give it a little while
        # before treating an empty reading as absent, or a slow enumeration burns a whole boot.
        local pdl=$(( SECONDS + 120 ))
        while :; do
            prob="$(pvnic_problem "$vm")"
            [ -n "$prob" ] && break
            [ "$SECONDS" -ge "$pdl" ] && break
            sleep 10
        done
        log "  boot $boot: PV NIC problem code = ${prob:-<unreachable>}"
        [ "$prob" = 0 ] && break
        timeout 300 qvm-shutdown --wait "$vm" >/dev/null 2>&1 || qvm-kill "$vm" >/dev/null 2>&1
        until [ "$(state "$vm")" = Halted ]; do sleep 5; done
    done

    timeout 300 qvm-shutdown --wait "$vm" >/dev/null 2>&1
    qvm-prefs "$vm" netvm '' || true
    qvm-firewall "$vm" reset >/dev/null 2>&1

    if [ "$prob" != 0 ]; then
        log "FAIL: $vm still reports PV NIC problem ${prob:-<unreachable>} (0 required)."
        log "      App qubes on this template WILL restart-loop when networked. Not shipping it."
        return 1
    fi
    log "PV NIC primed (problem 0, started); $vm is offline again"
}

# Priming is opt-out: PRIME_NETVM= to skip it, otherwise the app qube's netvm is used.
#
# The app qube inherits its netvm from the offline source, i.e. NONE - so taking that value alone
# made the script skip priming and rebuild the very configuration this exists to prevent.
#
# It must NOT fall back to `qubes-prefs default_netvm`. This script runs on somebody else's system:
# reaching for whatever netvm happens to be the default attaches a Windows template to production
# network infrastructure that was never offered to it. Name the netvm or get an error.
if [ "${PRIME_NETVM-unset}" = "unset" ]; then
    PRIME_NETVM="$(qvm-prefs "$APP" netvm 2>/dev/null)"
fi
# PRIME_NETVM=none is the explicit opt-out: build the pair and skip priming entirely. For an
# offline-only template that is a legitimate choice; for anything networked it is a loaded gun, so
# it says so. Empty/unset is NOT the opt-out - that is the accident this guards against.
# PRIME_NETVM=latch is the NETVM-FREE mode: seed the unplug latch + self-healing tasks instead of
# attaching any netvm (see prime_latch above for the mechanism and the per-boot cost).
if [ "$PRIME_NETVM" = none ]; then
    log "WARNING: PRIME_NETVM=none - skipping PV NIC priming."
    log "         Any app qube on $TPL that is given a netvm WILL restart-loop. Offline use only."
    PRIME_NETVM=''
    HINT_NETVM='<netvm>'
elif [ "$PRIME_NETVM" = latch ]; then
    prime_latch "$TPL" || { log "FAIL: latch priming did not complete"; exit 1; }
    PRIME_NETVM=''
    HINT_NETVM='<netvm>'
elif [ -z "$PRIME_NETVM" ]; then
    log "FAIL: no netvm to prime with. $APP has none, and this script will not pick one for you."
    log "      Re-run as: PRIME_NETVM=<netvm> $0 $SRC $TPL $APP   (traffic is firewalled off; the"
    log "      vif only has to exist), PRIME_NETVM=latch (netvm-free latch priming), or"
    log "      PRIME_NETVM=none to deliberately skip priming."
    exit 1
fi
[ -n "$PRIME_NETVM" ] && { prime_pv_nic "$TPL" "$PRIME_NETVM" || { log "FAIL: PV NIC priming did not complete"; exit 1; }; }

log "done: template=$TPL appvm=$APP"
# $APP inherits the template's netvm, i.e. none. Say so rather than attaching a network to somebody's
# new qube on their behalf - but say it plainly, because "it starts and does nothing" is the exact
# confusion this script exists to end.
[ -n "$(qvm-prefs "$APP" netvm 2>/dev/null)" ] || \
    log "note: $APP has no netvm. To use it networked: qvm-prefs $APP netvm ${HINT_NETVM:-$PRIME_NETVM}"
qvm-ls --fields NAME,STATE,KLASS,TEMPLATE "$TPL" "$APP" 2>/dev/null | tail -3
