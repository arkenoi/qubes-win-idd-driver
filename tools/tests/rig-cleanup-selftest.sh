#!/usr/bin/env bash
# rig-cleanup-selftest.sh - a cleanup that can delete the wrong thing is worse than no cleanup.
#
# mgmt/harness/rig-cleanup.sh removes leftover subjects to reclaim the thin pool. Everything it
# touches is irreversible, so every protection it claims is driven here against stubs: no real qube
# is read and none is removed. The protected set is DERIVED (seal records, the preflight's own
# ENTRY_FIXTURES default, the matrix's cell_appvm templates, every TemplateVM, dom0 and the
# management qube) and each of those derivations is checked separately - a protection that comes
# from the wrong place is the one that fails on the day the list changes.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T="$(mktemp -d "${TMPDIR:-/tmp}/rig-cleanup-XXXXXX")"
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT
pass=0; fail=0
ok(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

mkdir -p "$T/bin" "$T/goldens"

# ---- the rig, as a fixture ----------------------------------------------------------------------
# NAME|STATE and NAME|CLASS, the two listings the script asks for.
cat > "$T/rig" <<'EOF'
dom0|Halted|AdminVM
win-idd-mgmt|Halted|AppVM
win10-base|Halted|StandaloneVM
win11r-base|Halted|StandaloneVM
win10-iqi|Halted|StandaloneVM
win11-iqi|Halted|StandaloneVM
win10-tpl|Halted|TemplateVM
win11de-sm|Halted|TemplateVM
win11r-qwt|Halted|StandaloneVM
leftover-a|Halted|StandaloneVM
leftover-b|Halted|StandaloneVM
ckpt-leftover-a-installed|Halted|StandaloneVM
busy-one|Running|StandaloneVM
untagged-one|Halted|StandaloneVM
EOF
cat > "$T/bin/qvm-ls" <<'EOF'
#!/bin/bash
f=""; for a in "$@"; do case "$a" in *NAME,STATE*) f=state ;; *NAME,CLASS*) f=class ;; esac; done
while IFS='|' read -r n s c; do
  case "$f" in state) echo "$n|$s" ;; class) echo "$n|$c" ;; esac
done < "${RIG:?}"
EOF
# every fixture qube is tagged EXCEPT untagged-one - the "not ours" case
cat > "$T/bin/qvm-tags" <<'EOF'
#!/bin/bash
[ "$1" = untagged-one ] && exit 0
echo win-idd-testbed
EOF
cat > "$T/bin/qvm-remove" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in -*) ;; *) echo "$a" >> "${REMOVED:?}" ;; esac; done
EOF
chmod +x "$T/bin"/*
# seal records: these two names must be protected BECAUSE a seal exists, not because they are typed
: > "$T/goldens/win10-base.json"; : > "$T/goldens/win11r-base.json"
# AND ONE SEALED GOLDEN THAT IS NOT A FIXTURE BASE. win10-base and win11r-base are protected TWICE -
# by their seal record and as the bases named in ENTRY_FIXTURES - so deleting one record cannot show
# where the protection came from. win11r-qwt is sealed and is nobody's base, which is the only shape
# that tests the seal derivation on its own. The first cut of this suite used win10-base and its
# "seen to fail" leg passed while proving nothing.
: > "$T/goldens/win11r-qwt.json"
# a preflight whose ENTRY_FIXTURES names the entry images, parsed out of it by the script
printf 'ENTRY_FIXTURES="${ENTRY_FIXTURES:-win10-iqi:win10-base win11-iqi:win11r-base}"\n' > "$T/preflight.sh"
# a matrix whose cell_appvm lines name the templates
printf 'cell_appvm - win10-tpl WIN10 win10-app "$A10" ;;\n' > "$T/matrix.sh"

run(){ # -> rc; removals in $T/removed, output in $T/out
  : > "$T/removed"
  PATH="$T/bin:$PATH" RIG="$T/rig" REMOVED="$T/removed" \
  QVM_LS="$T/bin/qvm-ls" QVM_REMOVE="$T/bin/qvm-remove" \
  GOLDENS_DIR="$T/goldens" PREFLIGHT="$T/preflight.sh" MATRIX="$T/matrix.sh" \
    bash mgmt/harness/rig-cleanup.sh "$@" > "$T/out" 2>&1
  echo $?
}
removed_list(){ tr '\n' ' ' < "$T/removed"; }

# ---- 1. DRY IS THE DEFAULT ---------------------------------------------------------------------
rc=$(run)
if [ "$rc" = 0 ] && [ ! -s "$T/removed" ] && grep -qa 'DRY: nothing removed' "$T/out"; then
  ok "with no --go it removes NOTHING and says so"
else no "dry is the default" "rc=$rc removed='$(removed_list)'"; fi

# ---- 2. what it removes, and only that ---------------------------------------------------------
rc=$(run --go)
got=$(removed_list)
want="leftover-a leftover-b ckpt-leftover-a-installed "
if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then
  ok "it removes exactly the leftovers, checkpoint included: $got"
else no "it removes exactly the leftovers" "rc=$rc got='$got' want='$want'"; fi

# ---- 3. each protection, driven on its own ------------------------------------------------------
case " $got " in *" win10-base "*|*" win11r-base "*) no "a SEALED GOLDEN is never removed" "got='$got'" ;;
  *) ok "a SEALED GOLDEN is never removed - protection comes from the seal record on disk" ;; esac
case " $got " in *" win10-iqi "*|*" win11-iqi "*) no "an ENTRY FIXTURE is never removed" "got='$got'" ;;
  *) ok "an ENTRY FIXTURE is never removed - parsed from the preflight's own ENTRY_FIXTURES" ;; esac
case " $got " in *" win10-tpl "*|*" win11de-sm "*) no "a TEMPLATE is never removed" "got='$got'" ;;
  *) ok "a TEMPLATE is never removed - every TemplateVM on the rig, whatever it is called" ;; esac
case " $got " in *" dom0 "*|*" win-idd-mgmt "*) no "dom0 and the management qube are never removed" "got='$got'" ;;
  *) ok "dom0 and this management qube are never removed - they are not ours to touch" ;; esac
case " $got " in *" busy-one "*) no "a RUNNING guest is never removed" "got='$got'" ;;
  *) ok "a RUNNING guest is never removed, and is named as skipped" ;; esac
grep -qa 'SKIP busy-one' "$T/out" && ok "and the running one is reported, not silently dropped" \
  || no "the running one is reported" "$(grep -a busy-one "$T/out" | head -1)"
case " $got " in *" untagged-one "*) no "an UNTAGGED qube is never removed" "got='$got'" ;;
  *) ok "an UNTAGGED qube is never removed - not tagged win-idd-testbed means not ours" ;; esac

# ---- 4. --keep, and the seal-record derivation seen to MATTER -----------------------------------
rc=$(run --go --keep "leftover-a")
got=$(removed_list)
case " $got " in *" leftover-a "*) no "--keep protects a named subject" "got='$got'" ;;
  *) ok "--keep protects a named subject ($got)" ;; esac

# THE DERIVATION IS LOAD-BEARING, seen to fail: with win11r-qwt's seal record gone it is no longer
# protected and WOULD be removed. That is what proves the protection comes from the record rather
# than from a name that happens to be absent from the candidate list.
rc=$(run --go)
got=$(removed_list)
case " $got " in *" win11r-qwt "*) no "a sealed golden that is nobody's base is protected" "got='$got'" ;;
  *) ok "a sealed golden that is NOBODY'S fixture base is still protected - by its seal record alone" ;; esac
rm -f "$T/goldens/win11r-qwt.json"
rc=$(run --go)
got=$(removed_list)
case " $got " in *" win11r-qwt "*) ok "SEEN TO FAIL: delete that seal record and win11r-qwt becomes a candidate - the protection really IS the record on disk" ;;
  *) no "the seal-record derivation is load-bearing" "got='$got' - removing the record changed nothing, so that protection is coming from somewhere else" ;; esac
: > "$T/goldens/win11r-qwt.json"

echo
printf 'rig-cleanup-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
