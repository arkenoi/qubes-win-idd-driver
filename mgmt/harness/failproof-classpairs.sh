#!/bin/bash
# FAIL-PROOF harness for CLASS-CONDITIONAL checks — the negative needs no mutation at all.
#
# Several acceptance checks assert behaviour that the product deliberately varies BY VM CLASS.
# For those, the "defect" state is not something to manufacture: it exists legitimately on
# another class, and running the SAME assertion there is a true two-sided proof.
#
#   check                        asserts                            legitimate negative
#   standalone-nau-removed       StandaloneVM: NoAutoUpdate REMOVED TemplateVM keeps it (=1),
#                                (the updater carve-out)            because the carve-out is
#                                                                   class-conditional by design
#   appvm-private-reformatted    AppVM: private volume formatted,   StandaloneVM has no Q: at
#                                Q:\Users present                   all - nothing to format
#
# WHY THIS IS STRONGER THAN A PLANT, not weaker: a plant proves the check notices a state the
# plant created, which can be an artefact of how the plant was applied (protocol rule 2 - a
# health-check plant once did nothing at all and the check was blamed). Here both sides are
# real product behaviour on real subjects, so a check that cannot tell them apart is failing
# against the world rather than against my scaffolding.
#
# WHAT THIS CANNOT PROVE. If a check is simply reading the wrong thing, two classes can still
# differ for the wrong reason. So each earn records the RAW value from both sides, not just the
# boolean, and a proof whose two sides do not differ in the expected DIRECTION is refused.
#
#   mgmt/harness/failproof-classpairs.sh [outdir]
set -uo pipefail
cd /home/user/qubes-win-idd-driver
OUT="${1:-$HOME/qwt-accept/20260830-acceptance-4.3.16/FAILPROOF-classpairs}"
mkdir -p "$OUT"
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0
log(){ echo "$(date -u +%H:%M:%S) classpair: $*" | tee -a "$OUT/classpair.log"; }

psrun(){ # <vm> <ps>
  local vm="$1" b
  b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$2")
  QTEST_VM=$vm timeout -k 8 250 ./tools/qtest run "cmd /c powershell -NoProfile -EncodedCommand $b" 2>/dev/null \
    | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }

ensure_up(){  # <vm>
  local vm="$1" st
  st=$(qvm-ls --raw-data --fields STATE "$vm" 2>/dev/null | tail -1)
  if [ "$st" != Running ]; then
    log "  starting $vm (was $st)"
    timeout -k 10 240 qvm-start "$vm" >/dev/null 2>&1 &
    disown
  fi
  local i
  for i in $(seq 1 40); do
    QTEST_VM=$vm timeout -k 5 40 ./tools/qtest run 'cmd /c echo UP' 2>/dev/null | grep -qa UP && { log "  $vm answering qrexec"; return 0; }
    sleep 15
  done
  log "  FATAL: $vm never answered qrexec"; return 1
}

earn(){  # <check> <pos-raw> <neg-raw> <pos-bool> <neg-bool> <detail>
  local chk="$1" praw="$2" nraw="$3" pb="$4" nb="$5" det="$6"
  if [ "$pb" = True ] && [ "$nb" = False ]; then
    log "  -> PROOF EARNED: $chk   positive='$praw' negative='$nraw'"
    printf 'CLASSPAIR\t%s\tPASS\tSEEN TO FAIL 2026-08-31 (class-conditional, NO mutation): %s. Raw values - positive=[%s] negative=[%s]\t%s\n' \
      "$chk" "$det" "$praw" "$nraw" "$EV" >> "$V"
  else
    log "  -> NOT PROVEN: $chk   positive=$pb('$praw') negative=$nb('$nraw') - want True/False"
    printf 'CLASSPAIR\t%s\tPASS-UNPROVEN\ttwo-sided class attempt gave positive=%s [%s] negative=%s [%s]\t%s\n' \
      "$chk" "$pb" "$praw" "$nb" "$nraw" "$EV" >> "$V"; rc=1
  fi
}

# ---------------------------------------------------------------- standalone-nau-removed
# The updater carve-out: a StandaloneVM does not run the proxy updater, so NoAutoUpdate is
# REMOVED there and left in place (=1) on a Template, which does. Same query, two classes.
nau(){  # <vm> -> "ABSENT" | "PRESENT=<n>" | "?"
  psrun "$1" '$p="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
$v=(Get-ItemProperty -Path $p -Name NoAutoUpdate -EA SilentlyContinue).NoAutoUpdate
if ($null -eq $v) { Write-Output "NAU ABSENT" } else { Write-Output ("NAU PRESENT=" + $v) }' \
    | grep -ao 'NAU [A-Z=0-9]*' | awk '{print $2}' | head -1; }

log "=== standalone-nau-removed: StandaloneVM (removed) vs TemplateVM (kept) ==="
if ensure_up win10-p46 && ensure_up win10-tpl; then
  P=$(nau win10-p46); N=$(nau win10-tpl)
  log "  win10-p46 (StandaloneVM): NoAutoUpdate=$P"
  log "  win10-tpl (TemplateVM):   NoAutoUpdate=$N"
  # positive = the carve-out held (absent); negative = the SAME assertion on a class where it
  # must NOT hold. If the template also shows ABSENT the check cannot distinguish the classes.
  pb=$([ "$P" = ABSENT ] && echo True || echo False)
  nb=$([ "$N" = ABSENT ] && echo True || echo False)
  earn standalone-nau-removed "$P" "$N" "$pb" "$nb" \
    "the assertion 'NoAutoUpdate is removed' holds on the StandaloneVM the carve-out covers and FAILS on a TemplateVM, which keeps it by design"
else
  log "  -> SKIPPED: subjects unavailable"
  printf 'CLASSPAIR\tstandalone-nau-removed\tPASS-UNPROVEN\tsubjects unavailable for the class pair\t%s\n' "$EV" >> "$V"; rc=1
fi

# ---------------------------------------------------------------- appvm-private-reformatted
# An AppVM gets a private volume mounted as Q: and the installer formats it; a StandaloneVM has
# no separate private volume, so Q:\Users cannot exist there. The negative is the absence of a
# thing that is absent for a real product reason, not because anything was broken.
qusers(){ psrun "$1" 'Write-Output ("QUSERS " + (Test-Path "Q:\Users"))' | grep -ao 'QUSERS [A-Za-z]*' | awk '{print $2}' | head -1; }

log "=== appvm-private-reformatted: AppVM (Q:\\Users present) vs StandaloneVM (no Q: at all) ==="
if ensure_up win10-app; then
  P=$(qusers win10-app); N=$(qusers win10-p46)
  log "  win10-app (AppVM):        Q:\\Users -> $P"
  log "  win10-p46 (StandaloneVM): Q:\\Users -> $N"
  pb=$([ "$P" = True ] && echo True || echo False)
  nb=$([ "$N" = True ] && echo True || echo False)
  earn appvm-private-reformatted "$P" "$N" "$pb" "$nb" \
    "'the private volume is formatted and Q:\\Users exists' holds on the AppVM and FAILS on a StandaloneVM, which has no private volume"
else
  log "  -> SKIPPED: win10-app unavailable"
  printf 'CLASSPAIR\tappvm-private-reformatted\tPASS-UNPROVEN\twin10-app unavailable\t%s\n' "$EV" >> "$V"; rc=1
fi

log "=== finished rc=$rc ==="
exit $rc
