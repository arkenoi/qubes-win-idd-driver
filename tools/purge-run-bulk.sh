#!/bin/bash
# purge-run-bulk.sh - reclaim disk from per-run work trees by DELETING ONLY RE-DOWNLOADABLE BULK.
#
#   tools/purge-run-bulk.sh [--apply] [--keep <path>]... [--min-age-min <n>] [<root>...]
#
# Default is a DRY RUN. With no <root>, it uses the standard per-run trees (see ROOTS below).
#
# WHY BY FILE TYPE AND NOT BY DIRECTORY. Measured 2026-10-14 across eleven of these trees: 9.27 GB
# was ISOs, RPMs, EXEs, MSIs, setup-tree binaries and screenshots - every one of them a
# `gh run download` away, with the run id sitting in the directory name - against ~479 MB of actual
# data: logs, verdicts, manifests, benchmark transcripts and wedge forensics. Deleting whole
# directories would have thrown the data away with the weight. Deleting by type keeps every run's
# provenance and structure and still freed 9.27 GB (/home 83% -> 68%).
#
# THE FOUR THINGS THIS REFUSES TO TOUCH, each of which would have been a real loss:
#
#  1. ANY FILE BACKING A LIVE LOOP DEVICE, read from the kernel with `losetup -l`, never guessed.
#     When this was first written, scratchpad/ held a loop-mounted ISO and ~/win-iso held four
#     loop-attached answer sticks. A `qvm-device block assign --required` pointing at a deleted
#     backing file leaves the guest unstartable with nothing but "internal error: libxenlight
#     failed to create new domain" - a cause that looks nothing like a disk cleanup
#     (CLAUDE.md, findings/rig.md).
#
#  2. ANYTHING MATCHING *wedge* OR *forensics*. 12.8 MB in 259 files, and it is the one dataset here
#     that cannot be regenerated on demand: a wedge happens when it happens. Nine episodes between
#     2026-08-06 and 2026-10-06 are all that exist.
#
#  3. FILES YOUNGER THAN --min-age-min (default 60). A live harness is writing into evidence/ and
#     its campaign tree the whole time; everything this tool is for is days to weeks old, so an
#     hour of slack costs nothing and removes the chance of deleting under a running job.
#
#  4. WHATEVER --keep NAMES. Use it for the current campaign's tree and for an N-1 setup tree that
#     a fixture rebuild still needs - those are full of .exe/.msi and are otherwise indistinguishable
#     from bulk. There is no auto-detection on purpose: guessing which run is "current" is exactly
#     the kind of cleverness that deletes the wrong thing.
#
# The three Windows install ISOs in ~/win-iso are NOT in ROOTS and must never be added: re-downloading
# them fails Microsoft's Sentinel check, and the German one is the only route back to the win11de
# environment. Nor is ~/mirage-gso, which pairs with a docker image kept deliberately.
set -uo pipefail
APPLY=0; MINAGE=60; KEEP_PATHS=(); ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --keep) KEEP_PATHS+=("${2:?--keep needs a path}"); shift ;;
    --min-age-min) MINAGE="${2:?--min-age-min needs <n>}"; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    -*) echo "purge-run-bulk: unknown option '$1'" >&2; exit 2 ;;
    *) ROOTS+=("$1") ;;
  esac
  shift
done
if [ "${#ROOTS[@]}" -eq 0 ]; then
  R="$(cd "$(dirname "$0")/.." && pwd)"
  # GLOB, not a hand list. The first version named six ~/qwt-* trees explicitly and missed about
  # thirty others (qwt-fixtures, qwt-retest, qwt-v4test, qwt-431, qwt-iso-*, qwt-backup-* ...)
  # holding another 0.53 GB of the same ISOs. A hand-maintained list of per-run directories is
  # always behind the runs that create them.
  ROOTS=( "$HOME"/qwt-* "$HOME/rel" "$HOME/rel-idd" "$HOME/tmp"
          "$R/scratchpad" "$R/artifacts" "$R/evidence" )
  # VENDOR BINARIES A REPORTER ENVIRONMENT NEEDS ARE NOT BULK. Measured the hard way 2026-10-14:
  # this tool deleted scratchpad/openshell/OpenShellSetup_4_4_198.exe - an .exe under scratchpad,
  # older than the age guard, matched by no keep rule - and the next full acceptance died with
  # "the reporter asserts Open-Shell and win11de-tup does not have it". A release gate's required
  # suite was taken out by a disk cleanup. These files are re-fetchable but NOT from our CI, so
  # they are not "a gh run download away" the way every other binary here is.
  KEEP_PATHS+=( "$R/artifacts/chromerepro.exe" "$R/scratchpad/gweck" "$R/scratchpad/openshell" )
fi

BULK=( -name '*.iso' -o -name '*.exe' -o -name '*.rpm' -o -name '*.msi' -o -name '*.cab'
       -o -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' -o -name '*.png'
       -o -name '*.jpg' -o -name '*.dll' -o -name '*.sys' -o -name '*.pdb' -o -name '*.img'
       -o -name '*.core' -o -name '*.vhd' -o -name '*.wim' -o -name '*.esd' )

mapfile -t LOOPFILES < <(losetup -l 2>/dev/null | awk 'NR>1 && $6!=""{print $6}')
printf 'loop-backed files excluded: %d\n' "${#LOOPFILES[@]}"
is_excluded(){ local f="$1" x
  case "$f" in *wedge*|*forensics*) return 0 ;; esac
  for x in "${LOOPFILES[@]}"; do [ "$f" = "$x" ] && return 0; done
  for x in "${KEEP_PATHS[@]}"; do case "$f" in "$x"|"$x"/*) return 0 ;; esac; done
  return 1; }

LIST=$(mktemp); bytes=0; n=0; kept=0
for r in "${ROOTS[@]}"; do
  [ -d "$r" ] || continue
  while IFS= read -r -d '' f; do
    if is_excluded "$f"; then kept=$((kept+1)); continue; fi
    sz=$(stat -c%s "$f" 2>/dev/null) || continue
    bytes=$((bytes+sz)); n=$((n+1)); printf '%s\n' "$f" >> "$LIST"
  done < <(find "$r" -type f -mmin "+$MINAGE" \( "${BULK[@]}" \) -print0 2>/dev/null)
done

printf '%s: %d file(s), %.2f GB   (kept by rule: %d)\n' \
  "$( [ "$APPLY" = 1 ] && echo deleting || echo 'would delete' )" \
  "$n" "$(python3 -c "print($bytes/1073741824)")" "$kept"
if [ -s "$LIST" ]; then
  echo "largest 8:"
  xargs -a "$LIST" -d '\n' stat -c '%s %n' 2>/dev/null | sort -rn | head -8 \
    | awk '{printf "  %7.1f MB  %s\n", $1/1048576, $2}'
fi

if [ "$APPLY" = 1 ]; then
  # RECORD WHAT WENT. Without this the only way to answer "did the cleanup delete X" is inference,
  # which is exactly the position the Open-Shell deletion left me in.
  MANIFEST="${PURGE_MANIFEST:-scratchpad/purge-deleted-$(date -u +%Y%m%dT%H%M%SZ).txt}"
  mkdir -p "$(dirname "$MANIFEST")" 2>/dev/null
  cp "$LIST" "$MANIFEST" 2>/dev/null && echo "deleted-file manifest: $MANIFEST"
  xargs -a "$LIST" -d '\n' rm -f -- 2>/dev/null
  for r in "${ROOTS[@]}"; do [ -d "$r" ] && find "$r" -mindepth 1 -type d -empty -delete 2>/dev/null; done
  echo "PURGE-RESULT applied=$n"
else
  echo "DRY RUN - nothing deleted; re-run with --apply"
fi
rm -f "$LIST"
