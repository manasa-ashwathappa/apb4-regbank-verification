#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# regress.sh - run every test over a set of seeds and summarise.
#
# A run counts as passing only if the scoreboard printed TEST PASSED *and*
# the simulator reported no errors at all. The second condition matters:
# an SVA failure in apb_if.sv does not touch the scoreboard's counter, so
# grepping for PASSED alone would miss a protocol violation.
#
# Coverage is merged by taking the union of the bin table printed at the end
# of each log. It is a text-level merge, not a database merge, but it answers
# the question "did the regression as a whole close coverage".
#
# Usage: ./regress.sh [num_seeds] [BUG_DEFINE]
# -----------------------------------------------------------------------------
set -u
cd "$(dirname "$0")"

NUM_SEEDS=${1:-5}
BUG=${2:-}
TESTS="reset_test strb_test irq_w1c_test err_test rand_test"

make -s build BUG="$BUG" >/dev/null || { echo "build failed"; exit 2; }
mkdir -p logs

pass=0; fail=0; logs_this_run=()
printf "%-14s %-6s %-6s %s\n" "test" "seed" "result" "detail"
for t in $TESTS; do
    for s in $(seq 1 "$NUM_SEEDS"); do
        log="logs/${t}_s${s}${BUG:+_$BUG}.log"
        logs_this_run+=("$log")
        make -s run TEST="$t" SEED="$s" BUG="$BUG" > /dev/null 2>&1
        errs=$(grep -c "%Error" "$log")
        if grep -q "TEST PASSED" "$log" && [ "$errs" -eq 0 ]; then
            pass=$((pass+1)); res=PASS; detail=""
        else
            fail=$((fail+1)); res=FAIL
            detail=$(grep -m1 "%Error" "$log" | cut -c1-90)
        fi
        printf "%-14s %-6s %-6s %s\n" "$t" "$s" "$res" "$detail"
    done
done

echo
echo "runs passed: $pass   runs failed: $fail"
echo
echo "merged functional coverage (bins hit by at least one run):"
cat "${logs_this_run[@]}" | grep "^\[COV\] [a-z_A-Z0-9]* *[0-9]" \
  | awk '{bins[$2]+=$3} END {n=0; h=0; for (b in bins) {n++; if (bins[b]>0) h++; else print "  hole: " b}
         printf "  %d / %d bins  (%.1f%%)\n", h, n, 100.0*h/n}'

[ "$fail" -eq 0 ]
