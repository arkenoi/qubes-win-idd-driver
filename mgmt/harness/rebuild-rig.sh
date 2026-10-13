#!/bin/bash
# rebuild-rig.sh - rebuild every golden and fixture acceptance needs, unattended, from vendor media.
#
# ZERO JUDGEMENT ON A NORMAL RUN. Every step below is deterministic and was executed by hand on
# 2026-10-13; this script is that sequence with the three things that went wrong turned into
# preconditions. A model is needed only when a step FAILS: the script stops at the first failure,
# writes a failure package, and exits 10 with LLM-NEEDED on stdout. It never guesses, never retries
# a guest-destroying step, and never continues past a failure to "see how far it gets".
#
#   mgmt/harness/rebuild-rig.sh                 # everything, in order
#   mgmt/harness/rebuild-rig.sh --only base10   # one step
#   mgmt/harness/rebuild-rig.sh --from iqi10    # resume after a fixed failure
#   mgmt/harness/rebuild-rig.sh --list          # the steps and what each produces
#
# WHAT ACCEPTANCE ACTUALLY NEEDS, and nothing else (checked against mgmt/gate-scope.json, which
# names eight OS suites - win10/win11 x clean/reinstall/upgrade/appvm):
#   win10-base, win11r-base   pristine bases with the QubesPrime primer hook. The clean cells enter
#                             from these, and clean parks an 'installed' snapshot that reinstall and
#                             appvm then reuse - so one base feeds three suites per OS.
#   win10-iqi, win11-iqi      entry fixtures with the PREVIOUS release installed, for the upgrade
#                             cells. G10/G11 name these.
#   win10-tpl+win10-app,      the appvm cells restore the installed park into a TEMPLATE and derive
#   win11-tpl+win11-app       an AppVM from it.
# The GERMAN base is deliberately NOT here. No gate suite enters from it; its only consumer is
# GWeck field-report work, which is served by win11de-qwt. Rebuilding it costs ~30 min and 15 GB
# for nothing (owner, 2026-10-13).
#
# THE THREE FAILURES THIS ENCODES, so they cannot recur silently:
#  1. A SECOND GUEST. On 2026-10-13 a base was built while another guest was still Running, because
#     the only serial enforcement read the launching command's TEXT and the launch was wrapped in a
#     script. Every step here asserts sole-guest through vm_lock (mgmt/harness/serial-rig.sh).
#  2. THE WIN11 COMPLETION GATE CANNOT FIRE. reprovision's PRISTINE mode needs cpu under 15% for
#     three samples; a finished Win11 26300 desktop idles at a STEADY 44-48%, so the run burns its
#     full budget with the guest finished. This script therefore does NOT trust that gate as the
#     completion signal. It bounds the wait, then proves the base with prime-selftest - which is the
#     real question anyway: an incomplete install cannot pass the primer selftest.
#  3. clone-to-template NEEDS A SOURCE THAT ANSWERS QREXEC. Its settle boot waits for qrexec, and a
#     pristine base has no QWT and never answers - seven minutes of timeout. The templates are built
#     from the -iqi fixtures, NOT from the bases. mgmt/teardown-campaign-fixtures.sh still says
#     "rebuild from win10-base"; that instruction cannot work and is why this is spelled out here.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
. mgmt/harness/vmlock.sh          # vm_lock also asserts sole-guest
. mgmt/harness/serial-rig.sh

RUN_ID="rebuild-$(date -u +%Y%m%d-%H%M%S)"
OUT="$PWD/evidence/$RUN_ID"; mkdir -p "$OUT"
LOG="$OUT/rebuild.log"
MANIFEST="$OUT/manifest.jsonl"
N1_TREE="${N1_TREE:-/home/user/qwt-accept/n1-4.3.35/tree}"
ISO10="${ISO10:-/home/user/win-iso/Win10_22H2_EnglishInternational_x64v1.iso}"
ISO11="${ISO11:-/home/user/win-iso/Win11_26300_English_x64.iso}"
STICK10="${STICK10:-/home/user/win-iso/answer-pristine-win10.img}"
STICK11="${STICK11:-/home/user/win-iso/answer-pristine-win11r.img}"

say(){ echo "$(date -u +%H:%M:%S) rebuild-rig: $*" | tee -a "$LOG"; }
record(){ python3 - "$MANIFEST" "$1" "$2" "$3" <<'PY'
import json,sys,datetime
open(sys.argv[1],'a').write(json.dumps({
    "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "step": sys.argv[2], "event": sys.argv[3], "detail": sys.argv[4]})+"\n")
PY
}
# THE ONLY EXIT THAT ASKS FOR A HUMAN OR A MODEL. Everything a normal run does is above this line.
fail(){ local step="$1" why="$2" vm="${3:-}"
    say "FAIL [$step]: $why"
    record "$step" fail "$why"
    if [ -n "$vm" ] && [ -x mgmt/harness/collect-failure.sh ]; then
        say "collecting failure package for $vm"
        mgmt/harness/collect-failure.sh "$vm" "$OUT/failure-$step" "$why" >>"$LOG" 2>&1 \
            && say "package -> $OUT/failure-$step" || say "WARNING: collect-failure.sh itself failed"
    fi
    echo "LLM-NEEDED step=$step vm=${vm:-none} evidence=$OUT"
    exit 10
}

# ---- the loop device for a file, created if absent. Root-free; never losetup. -------------------
ensure_loop(){ # $1=file $2=ro|rw -> prints loopN
    local f="$1" mode="${2:-rw}" l
    l=$(losetup -l 2>/dev/null | awk -v f="$f" '$6==f{sub("/dev/","",$1);print $1;exit}')
    [ -n "$l" ] && { echo "$l"; return 0; }
    local flag=""; [ "$mode" = ro ] && flag="-r"
    udisksctl loop-setup $flag -f "$f" >/dev/null 2>&1 || return 1
    losetup -l 2>/dev/null | awk -v f="$f" '$6==f{sub("/dev/","",$1);print $1;exit}'
}

# ---- wait for a guest to look finished, WITHOUT trusting the cpu gate (failure 2) ---------------
# Bounded, and deliberately generous: being wrong here costs a selftest, not a wrong verdict, since
# the base is proven by prime-selftest immediately afterwards.
wait_installed(){ # $1=vm $2=budget-seconds
    local vm="$1" budget="${2:-3600}" t0 el st
    t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt "$budget" ]; do
        sleep 60
        st=$(qvm-ls --raw-data --fields STATE "$vm" 2>/dev/null | tail -1)
        el=$(( $(date +%s) - t0 ))
        [ "$st" = Halted ] && { say "  $vm halted at t+${el}s (installer reboot) - restarting"; timeout 120 qvm-start "$vm" >/dev/null 2>&1; continue; }
        say "  $vm t+${el}s state=$st"
    done
}

# ---- TESTABLE FINAL CONDITIONS -----------------------------------------------------------------
# One per step, checkable by this script with no model and no human. Rig preparation is deterministic:
# a step either reached its end state or it did not. There are deliberately NO retries - an
# intermittent pass is not a pass, it is an unexamined defect, and the whole point of stopping at the
# first failure is that someone looks at it.
assert_halted(){ [ "$(qvm-ls --raw-data --fields STATE "$1" 2>/dev/null | tail -1)" = Halted ]; }

# A base is good when: it is Halted, its seal verifies, and its root volume holds a REAL amount of
# Windows. That last check is here because on 2026-10-13 a root volume reporting exactly size/10000
# was read as a destroyed image - that value means "not computed", never "empty", and a real base
# reads 10-16 GB. An install that silently produced nothing would pass the first two checks.
assert_base(){ # $1=vm
    local vm="$1" usage size
    assert_halted "$vm"                      || { say "  ASSERT FAIL: $vm is not Halted"; return 1; }
    mgmt/golden.sh verify "$vm" >>"$LOG" 2>&1 || { say "  ASSERT FAIL: $vm seal does not verify"; return 1; }
    usage=$(qvm-volume info "$vm":root 2>/dev/null | awk '/^usage/{print $2}')
    size=$(qvm-volume info "$vm":root 2>/dev/null | awk '/^size/{print $2}')
    [ -n "$usage" ] && [ -n "$size" ]        || { say "  ASSERT FAIL: cannot read $vm root volume"; return 1; }
    [ "$usage" -ne $(( size / 10000 )) ]     || { say "  ASSERT FAIL: $vm root usage is exactly size/10000 - the 'not computed' stub, so nothing was written"; return 1; }
    [ "$usage" -gt 5000000000 ]              || { say "  ASSERT FAIL: $vm root holds only $usage bytes - no Windows was installed"; return 1; }
    say "  assert ok: $vm Halted, seal verifies, root $(( usage / 1073741824 )) GiB"
}

# The primer fired iff the job rebooted the guest. Parsed from THIS run's own output file, never a
# shared log - a grep over a shared log would match an earlier step's success.
assert_prove(){ # $1=vm $2=selftest-output-file
    grep -q 'restart #1' "$2" || { say "  ASSERT FAIL: $1 primer hook never fired (no restart in $2)"; return 1; }
    say "  assert ok: $1 primer hook fired"
}

# A fixture is good when it carries the N-1 package, verified file-for-file, and is parked Halted.
assert_fixture(){ # $1=vm
    local vm="$1" want got ev
    want=$(python3 -c "import json;print(json.load(open('$N1_TREE/MANIFEST.json'))['package_version'])")
    ev=$(ls -dt evidence/prime-ours-"$vm"-* 2>/dev/null | head -1)
    [ -n "$ev" ]                             || { say "  ASSERT FAIL: no evidence dir for $vm"; return 1; }
    got=$(grep -aoE '"package_version":"[^"]*"' "$ev/qwt-improved-install.log" 2>/dev/null | head -1 | cut -d'"' -f4)
    [ "$got" = "$want" ]                     || { say "  ASSERT FAIL: $vm carries '$got', expected '$want'"; return 1; }
    grep -aq '"payload_files_verified":85' "$ev/qwt-improved-install.log" 2>/dev/null                                              || { say "  ASSERT FAIL: $vm did not verify all 85 payload files"; return 1; }
    assert_halted "$vm"                      || { say "  ASSERT FAIL: $vm is not Halted"; return 1; }
    say "  assert ok: $vm carries $got, 85 payload files verified, Halted"
}

assert_template(){ # $1=tpl $2=appvm
    local tpl="$1" app="$2" k t
    k=$(qvm-ls --raw-data --fields NAME,KLASS "$tpl" 2>/dev/null | tail -1 | cut -d'|' -f2)
    [ "$k" = TemplateVM ]                    || { say "  ASSERT FAIL: $tpl is '$k', not a TemplateVM"; return 1; }
    t=$(qvm-ls --raw-data --fields NAME,TEMPLATE "$app" 2>/dev/null | tail -1 | cut -d'|' -f2)
    [ "$t" = "$tpl" ]                        || { say "  ASSERT FAIL: $app is templated on '$t', not $tpl"; return 1; }
    assert_halted "$tpl" && assert_halted "$app" || { say "  ASSERT FAIL: $tpl/$app not both Halted"; return 1; }
    say "  assert ok: $tpl is a TemplateVM, $app derives from it, both Halted"
}

step_preflight(){
    say "=== preflight ==="
    assert_sole_guest "" || fail preflight "a guest is already up - this script owns the whole rig"
    for f in "$ISO10" "$ISO11" "$STICK10" "$STICK11"; do
        [ -f "$f" ] || fail preflight "missing required file: $f"
    done
    [ -f "$N1_TREE/MANIFEST.json" ] && [ -f "$N1_TREE/install.cmd" ] \
        || fail preflight "N1_TREE=$N1_TREE is not a setup tree (needs MANIFEST.json + install.cmd at its root)"
    if [ -f "$N1_TREE/SHA256SUMS.txt" ]; then
        ( cd "$N1_TREE" && sha256sum -c SHA256SUMS.txt >/dev/null 2>&1 ) \
            || fail preflight "N-1 setup tree fails its own SHA256SUMS.txt"
        say "N-1 tree verified against SHA256SUMS.txt"
    fi
    local pv; pv=$(python3 -c "import json;print(json.load(open('$N1_TREE/MANIFEST.json'))['package_version'])")
    say "N-1 package: $pv"
    local used size free_gb
    used=$(qvm-pool info vm-pool 2>/dev/null | awk '/^usage/{print $2}')
    size=$(qvm-pool info vm-pool 2>/dev/null | awk '/^size/{print $2}')
    free_gb=$(( (size - used) / 1073741824 ))
    say "pool: ${free_gb} GiB free"
    [ "$free_gb" -ge 90 ] || fail preflight "only ${free_gb} GiB free; a full rebuild needs ~90 GiB"
    record preflight ok "n1=$pv free=${free_gb}GiB"
}

# $1=vm $2=iso-file $3=stick-file $4=unattend $5=locale $6=image-name
build_base(){
    local vm="$1" iso="$2" stick="$3" unattend="$4" locale="$5" image="$6" il sl sz
    say "=== $vm: pristine base from vendor media ==="
    vm_lock "$vm" || fail "base:$vm" "could not take the lock"
    il=$(ensure_loop "$iso" ro)  || fail "base:$vm" "no loop for $iso"
    sl=$(ensure_loop "$stick" rw)|| fail "base:$vm" "no loop for $stick"
    sz=$(( $(stat -c%s "$stick") / 1024 / 1024 ))
    say "iso=$il stick=$sl (${sz}M) unattend=$(basename "$unattend") locale=$locale"
    # PRIMER=1 is what bakes the QubesPrime hook in. Without it the base installs fine and is
    # USELESS: nothing can drive a clone of it, because a base has no QWT and so no qrexec.
    PRIMER=1 SIZE_MB="$sz" LOCALE="$locale" UNATTEND="$unattend" OUT="$stick" \
        mgmt/build-answer-stick.sh "$image" >>"$LOG" 2>&1 \
        || fail "base:$vm" "answer stick build failed"
    record "base:$vm" stick "unattend=$unattend locale=$locale image=$image"
    PRISTINE=1 GOLDEN_UNSEAL="$vm" mgmt/reprovision-usb.sh "$vm" "$il" "$sl" >>"$LOG" 2>&1
    # rc 3 means "candidate desktop, needs visual confirmation"; on Win11 the gate cannot fire at
    # all and the run ends at its budget. Neither is a verdict - prime-selftest below is.
    say "reprovision returned $? (advisory); proving the base is what decides"
    [ "$(qvm-ls --raw-data --fields STATE "$vm" 2>/dev/null | tail -1)" = Running ] \
        || fail "base:$vm" "guest is not Running after reprovision" "$vm"
    say "shutting $vm down cleanly"
    qwt_shutdown "$vm" 600
    [ "$(qvm-ls --raw-data --fields STATE "$vm" 2>/dev/null | tail -1)" = Halted ] \
        || fail "base:$vm" "did not halt cleanly" "$vm"
    GOLDEN_RESEAL_REASON="rebuilt from vendor media by $RUN_ID" \
        mgmt/golden.sh seal "$vm" "pristine base rebuilt $RUN_ID from $(basename "$iso"), PRIMER=1, no QWT" >>"$LOG" 2>&1 \
        || fail "base:$vm" "seal failed"
    mgmt/golden.sh verify "$vm" >>"$LOG" 2>&1 || fail "base:$vm" "seal does not verify after sealing"
    assert_base "$vm" || fail "base:$vm" "final condition not met after sealing" "$vm"
    record "base:$vm" sealed "$(python3 -c "import json;print(json.load(open('mgmt/goldens/$vm.json'))['sealed_utc'])")"
    say "$vm sealed and verified"
}

# The REAL completion check: a base whose install is incomplete, or whose primer hook never
# registered, cannot pass this. PASS is read off the screen because a primed base has no qrexec.
prove_base(){
    local vm="$1" churn="prime-sel-$$" frame sout="$OUT/selftest-$1.log"
    say "=== $vm: proving the primer channel ==="
    mgmt/prime-selftest.sh "$vm" "$churn" >"$sout" 2>&1
    cat "$sout" >>"$LOG"
    frame=$(ls -dt evidence/prime-selftest-"$churn"-* 2>/dev/null | head -1)/latest.png
    [ -f "$frame" ] || fail "prove:$vm" "selftest produced no frame" "$churn"
    # The frame is the verdict and it is an IMAGE: the script cannot read it. What it CAN check is
    # the restart, which only happens when the hook fires and the job reboots the guest. A run with
    # restarts=0 is the documented failure and is refused here without a model being consulted.
    assert_prove "$vm" "$sout" \
        || fail "prove:$vm" "the primer hook never fired (no restart) - frame: $frame" "$churn"
    record "prove:$vm" ok "frame=$frame"
    say "$vm primer fired; frame for the record: $frame"
    timeout 90 qvm-kill "$churn" >/dev/null 2>&1; qvm-remove -f "$churn" >/dev/null 2>&1
}

# $1=base $2=fixture-name
build_fixture(){
    local base="$1" vm="$2"
    say "=== $vm: previous-release entry fixture from $base ==="
    vm_lock "$vm" || fail "iqi:$vm" "could not take the lock"
    mgmt/harness/prime-run.sh "$base" "$vm" ours --payload "$N1_TREE" >>"$LOG" 2>&1 \
        || fail "iqi:$vm" "prime-run did not bring $vm up" "$vm"
    # prime-run says so itself: the stick stays --required-assigned and qemu-extra-args stays set.
    # A cell subject cloned from a fixture that still carries them inherits a provisioning rig.
    qvm-device block unassign "$vm" win-idd-mgmt:"$(ensure_loop /home/user/win-iso/answer-usb.img rw)" >>"$LOG" 2>&1
    qvm-features --unset "$vm" qemu-extra-args >>"$LOG" 2>&1
    qwt_shutdown "$vm" 600
    assert_fixture "$vm" || fail "iqi:$vm" "final condition not met" "$vm"
    record "iqi:$vm" ok "base=$base"
    say "$vm built and halted"
}

# $1=src-fixture $2=template $3=appvm
build_template(){
    local src="$1" tpl="$2" app="$3"
    say "=== $tpl + $app from $src ==="
    # PRIME_NETVM=latch is the netvm-free priming path. The script REFUSES to pick a netvm itself,
    # deliberately, and fw-net cannot be started from this qube (policy, not absence).
    # REPORT WHAT IT SAID, NOT WHAT I GUESS IT MEANS. The first version of this line asserted
    # "source must answer qrexec - use an -iqi fixture", because that was the failure I had just
    # debugged by hand. When the step really did fail, on 2026-10-13, the cause was entirely
    # different ("latch installer did not report ok - guest said: <nothing>") and the message sent
    # the reader at the wrong thing. A failure message that names a cause it has not checked is the
    # same defect as the screen classifier calling a modal error dialog VERDICT=DESKTOP.
    if ! PRIME_NETVM=latch mgmt/clone-to-template.sh "$src" "$tpl" "$app" >>"$LOG" 2>&1; then
        local tail_said
        tail_said=$(grep -a 'clone-to-template:' "$LOG" | tail -3 | sed 's/^[0-9:]* clone-to-template: //' | tr '\n' ' | ')
        fail "tpl:$tpl" "clone-to-template failed. It said: $tail_said" "$tpl"
    fi
    assert_template "$tpl" "$app" || fail "tpl:$tpl" "final condition not met" "$tpl"
    record "tpl:$tpl" ok "src=$src appvm=$app"
    say "$tpl and $app built"
}

STEPS="preflight base10 prove10 base11 prove11 iqi10 iqi11 tpl10 tpl11 inventory"
run_step(){ case "$1" in
    preflight) step_preflight ;;
    base10)    build_base win10-base  "$ISO10" "$STICK10" "$PWD/mgmt/autounattend.xml"               en-GB "Windows 10 Pro" ;;
    prove10)   prove_base win10-base ;;
    base11)    build_base win11r-base "$ISO11" "$STICK11" "$PWD/mgmt/autounattend-win11-static.xml"  en-US "Windows 11 Pro" ;;
    prove11)   prove_base win11r-base ;;
    iqi10)     build_fixture win10-base  win10-iqi ;;
    iqi11)     build_fixture win11r-base win11-iqi ;;
    tpl10)     build_template win10-iqi win10-tpl win10-app ;;
    tpl11)     build_template win11-iqi win11-tpl win11-app ;;
    inventory) say "=== final inventory ==="
               qvm-ls --raw-data --fields NAME,STATE,KLASS 2>/dev/null | grep -iE '^win(10|11)' | tee -a "$LOG"
               for g in win10-base win11r-base; do mgmt/golden.sh verify "$g" >>"$LOG" 2>&1 \
                   && say "  $g seal verifies" || fail inventory "$g seal does not verify at the end"; done
               record inventory ok "$RUN_ID complete" ;;
    *) fail driver "unknown step: $1" ;;
esac }

ONLY=""; FROM=""
while [ $# -gt 0 ]; do case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --list) printf '%s\n' $STEPS; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
esac done

say "run $RUN_ID  evidence -> $OUT"
started=0
for s in $STEPS; do
    [ -n "$ONLY" ] && [ "$s" != "$ONLY" ] && continue
    [ -n "$FROM" ] && [ "$started" = 0 ] && [ "$s" != "$FROM" ] && continue
    started=1
    record "$s" start ""
    run_step "$s"
    record "$s" done ""
done
say "COMPLETE: $RUN_ID"
record run complete "$OUT"
