#!/usr/bin/env bash
# Single-threaded CPU throughput across three workload shapes.
#
#   int    dependent integer chain  -> ALU latency and sustained clock
#   float  independent FP chains    -> FPU throughput
#   sieve  branchy, few-MB working set -> branch prediction and L2/L3
set -uo pipefail
source "$LB_ROOT/lib/common.sh"

if [ ! -x "$LB_BUILD/cpu_kernel" ]; then
	lb_status cpu-single skip "cpu_kernel not built"
	exit 0
fi

fail=0
for wl in int float sieve; do
	samples=()
	for _ in $(seq 1 "$LB_REPS"); do
		v=$(lb_kernel cpu_kernel "$wl" "$LB_DURATION") || { fail=1; break; }
		samples+=("$v")
		lb_cooldown
	done
	[ ${#samples[@]} -gt 0 ] && lb_metric cpu-single "$wl" "ops/s" 1 "${samples[@]}"
done

if [ "$fail" -eq 1 ]; then
	lb_status cpu-single fail "cpu_kernel returned no result"
else
	lb_status cpu-single ok
fi
