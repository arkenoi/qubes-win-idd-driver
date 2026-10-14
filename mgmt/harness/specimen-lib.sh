#!/bin/bash
# specimen-lib.sh - a SPENT SPECIMEN is marked, so nothing starts it by hand afterwards.
#
# WHAT A SPENT SPECIMEN IS. A cell fails and leaves its subject as it stands - matrix.sh's H3.5
# path, "guest LEFT AS IT STANDS" - because a failed install is the only interrogable form of the
# defect and three specimens were already lost to cleanup. From that moment the guest is EVIDENCE,
# not a machine: its volume carries the pre-damage state, and its revisions are two shutdowns wide.
#
# WHY A MARKER AND NOT A RULE IN PROSE. On 2026-10-14 I started win10-acc by hand to read its logs
# minutes after the campaign had deliberately left it alone, with the owner watching: "starting WHAT
# THE FUCK to read the logs, we agreed to move the logs off to stick". Two things were wrong and
# only one of them was the boot. The logs do not need the guest at all - the secondary log volume is
# an image FILE in this qube and logvol_pull reads it with mtools while the guest runs, wedges or
# sits Halted. And the boot could not even work: the ISO cell had left a `--required` claim on a
# loop device that no longer existed, so the domain could not be created.
#
# So the harness writes down what it left behind, and tools/hooks/golden-boot-gate.sh refuses to
# start a marked name. The hook sees ONLY hand-typed commands - a harness starts its guests from
# inside its own script, where no PreToolUse hook is involved - so this cannot block the harnesses.
#
# THE MARKER IS CLEARED BY THE CELL THAT LEGITIMATELY RECREATES THE SUBJECT, never by hand on a
# hunch: prime-run removes and recreates its target, and the reclone cells clone over its volumes.
# A marker that outlived its specimen would block the next campaign, which is how a guard becomes
# something to switch off.
set -uo pipefail

SPECIMEN_DIR="${SPECIMEN_DIR:-scratchpad/specimens}"

_sp_say(){ echo "specimen: $*" >&2; }

specimen_file(){ # <vm> -> the marker path
  printf '%s/%s.spent\n' "$SPECIMEN_DIR" "${1:?[ERROR] specimen_file <vm>}"
}

specimen_mark(){ # <vm> <why> [where] - record that this guest is being kept as evidence
  local vm="${1:?[ERROR] specimen_mark <vm> <why> [where]}" why="${2:?[ERROR] specimen_mark <vm> <why> [where]}" where="${3:-}" f
  f=$(specimen_file "$vm")
  mkdir -p "$SPECIMEN_DIR" || { _sp_say "[ERROR] could not create $SPECIMEN_DIR"; return 1; }
  # Single-line fields, so the hook can read them without a parser. The guest's own text is
  # sanitised the same way logvol-lib does it: a CR or a bracket from a guest string must not
  # reshape a line we later grep.
  {
    printf 'vm=%s\n' "$vm"
    printf 'marked_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'why=%s\n'   "$(printf '%s' "$why"   | tr -d '\r\n' | tr '[]' '()' | cut -c1-200)"
    printf 'where=%s\n' "$(printf '%s' "$where" | tr -d '\r\n' | cut -c1-200)"
  } > "$f" || { _sp_say "[ERROR] could not write $f"; return 1; }
  echo "SPECIMEN-MARKED vm=$vm file=$f"
}

specimen_clear(){ # <vm> - the subject is about to be recreated or recloned, so it is no longer evidence
  local vm="${1:?[ERROR] specimen_clear <vm>}" f
  f=$(specimen_file "$vm")
  [ -e "$f" ] || return 0
  rm -f "$f" || { _sp_say "[ERROR] could not remove $f"; return 1; }
  echo "SPECIMEN-CLEARED vm=$vm"
}

specimen_why(){ # <vm> -> the recorded reason, empty when not marked
  local f; f=$(specimen_file "${1:?[ERROR] specimen_why <vm>}")
  [ -f "$f" ] || return 1
  sed -n 's/^why=//p' "$f" | head -1
}
