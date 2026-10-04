#!/usr/bin/env bash
# stock-ab-selftest.sh - drive mgmt/harness/stock-ab.sh against a STUB harness (no guest, no rig) and check that every outcome is
# graded as pre-registered, that each arm gets its own job and arguments, the ABBA order, the STOP boundary and the Fisher result.
# A check is only evidence once seen to fail: KNOB=<name> breaks one expectation on purpose and the run must then FAIL.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tree"; echo '@echo stub' > "$T/tree/install.cmd"; echo '{"package_version": "stub-1"}' > "$T/tree/MANIFEST.json"
# The stub harness: the Nth call prints and exits as line N of $T/plan says, and records its argv + quiet env.
cat > "$T/fakepr.sh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$STUB_DIR/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/count"
echo "argv: $* | QB=${QUIET_BOOT_SECS-unset} QAF=${QUIET_AFTER_FIRST-unset}" >> "$STUB_DIR/calls"
line=$(sed -n "${n}p" "$STUB_DIR/plan"); rc=${line%%|*}; text=${line#*|}
[ -n "$text" ] && printf '%b\n' "$text"
[ -n "${STUB_STOP_AFTER:-}" ] && [ "$n" -eq "$STUB_STOP_AFTER" ] && touch "$STOCK_AB_OUT/STOP"
exit "$rc"
EOF
chmod +x "$T/fakepr.sh"
fail=0; ok(){ echo "  ok   $*"; }; bad(){ echo "  FAIL $*"; fail=1; }
run(){ rm -f "$T/count" "$T/calls"; rm -rf "$T/out"; STUB_DIR="$T" PRIME_RUN="$T/fakepr.sh" STOCK_AB_OUT="$T/out" \
       bash mgmt/harness/stock-ab.sh "$T/tree" "$1" win10-base win10-acc > "$T/console" 2>&1; }

echo "== case 1: every verdict class, 3 pairs"
ev_s='evidence/prime-stock-422-win10-acc-20261004-120000'; ev_o='evidence/prime-ours-win10-acc-20261004-121500'
cat > "$T/plan" <<EOF
0|OK: up. Evidence in /x/$ev_s.
2|DEADLINE: qrexec dead\nFROZEN stall\nEvidence in /x/$ev_o.
2|DEADLINE: qrexec dead\nEXECUTING-BUT-UNREACHABLE
2|no deadline text
2|DEADLINE: x\nFROZEN stall\ncpu_time UNREADABLE
1|TERMINAL: refused
EOF
run 3
tsv="$T/out/runs.tsv"
want=$(printf '%s\n' "1 STOCK OK -" "1 OURS STALL FLAT" "2 OURS STALL MOVING" "2 STOCK OTHER -" "3 STOCK OTHER UNREADABLE" "3 OURS OTHER -")
got=$(awk -F'\t' 'NR>1{print $1, $2, $6, $7}' "$tsv")
[ "${KNOB:-}" = verdicts ] && want=$(echo "$want" | sed '2s/STALL FLAT/OK -/')
[ "$got" = "$want" ] && ok "verdicts, classes and ABBA order as registered" || { bad "verdicts/order"; echo "$got" | sed 's/^/       got: /'; }
[ "$(awk -F'\t' 'NR==2{print $8}' "$tsv")" = "$ev_s" ] && ok "a stock evidence dir is extracted" || bad "stock evidence path: $(awk -F'\t' 'NR==2{print $8}' "$tsv")"
[ "$(awk -F'\t' 'NR==3{print $8}' "$tsv")" = "$ev_o" ] && ok "an ours evidence dir is extracted" || bad "ours evidence path"
c1=$(sed -n 1p "$T/calls"); c2=$(sed -n 2p "$T/calls")
case "$c1" in "argv: win10-base win10-acc stock-422 --deadline 1800 | QB=0 QAF=0") ok "STOCK: job stock-422, no payload, no quiet window" ;; *) bad "STOCK argv: $c1" ;; esac
exp2="argv: win10-base win10-acc ours --payload $T/tree --deadline 1800 | QB=0 QAF=0"
[ "${KNOB:-}" = args ] && exp2="${exp2/ours/stock-422}"
[ "$c2" = "$exp2" ] && ok "OURS: job ours with the payload, no quiet window" || bad "OURS argv: $c2"
grep -q "STOCK 0/1 " "$T/out/RESULT.txt" && grep -q "OURS 2/2 " "$T/out/RESULT.txt" && ok "OTHER excluded from the graded counts" || { bad "graded counts"; cat "$T/out/RESULT.txt"; }

echo "== case 2: the Fisher arithmetic (STOCK 0/5 vs OURS 4/5 -> p = 5/210 = 0.0238)"
: > "$T/plan"; for i in 1 2 3 4 5; do
  if [ $((i % 2)) -eq 1 ]; then echo "0|OK" >> "$T/plan"; if [ "$i" -le 4 ]; then echo "2|DEADLINE: x\nFROZEN stall" >> "$T/plan"; else echo "0|OK" >> "$T/plan"; fi
  else if [ "$i" -le 4 ]; then echo "2|DEADLINE: x\nFROZEN stall" >> "$T/plan"; else echo "0|OK" >> "$T/plan"; fi; echo "0|OK" >> "$T/plan"; fi
done
run 5
want_p="p = 0.0238"; [ "${KNOB:-}" = fisher ] && want_p="p = 0.0500"
grep -q "STOCK 0/5" "$T/out/RESULT.txt" && grep -q "OURS 4/5" "$T/out/RESULT.txt" && grep -q "MORE than STOCK: $want_p" "$T/out/RESULT.txt" \
  && ok "one-sided Fisher in the registered direction" || { bad "Fisher"; cat "$T/out/RESULT.txt"; }

echo "== case 3: STOP ends the A/B at the next run boundary, never mid-run"
printf '0|OK\n0|OK\n0|OK\n0|OK\n' > "$T/plan"
STUB_STOP_AFTER=2; [ "${KNOB:-}" = stop ] && STUB_STOP_AFTER=99
export STUB_STOP_AFTER; run 2; unset STUB_STOP_AFTER
n=$(cat "$T/count"); [ "$n" = 2 ] && grep -q "STOP file present" "$T/console" && ok "stopped after the 2nd run, before the 3rd" || bad "STOP: harness ran $n times"

[ "$fail" = 0 ] && { echo "PASS (stock-ab.sh, stub harness)"; exit 0; } || { echo "FAIL"; exit 1; }
