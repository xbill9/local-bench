#!/usr/bin/env bash
# Multi-core scaling: the same integer workload at 1 thread and at every
# available thread, measured back to back so the two are directly comparable.
#
# Aggregate throughput is the sum across workers. Scaling efficiency is that
# aggregate over (single-thread rate x thread count); on a machine with SMT or
# an aggressive thermal cap it lands well below 100%, which is the point of
# measuring it rather than assuming it.
set -uo pipefail
source "$LB_ROOT/lib/common.sh"

if [ ! -x "$LB_BUILD/cpu_kernel" ]; then
	lb_status cpu-multi skip "cpu_kernel not built"
	exit 0
fi

ncpu=$(lb_ncpu)
workdir=$(mktemp -d "${TMPDIR:-/tmp}/lb-multi.XXXXXX") || {
	lb_status cpu-multi fail "could not create temp dir"; exit 0; }
trap 'rm -rf "$workdir"' EXIT

# Sum the throughput of n concurrently running workers.
run_parallel() {
	local n="$1" i pid
	local pids=()
	rm -f "$workdir"/w.*
	for ((i = 0; i < n; i++)); do
		( "$LB_BUILD/cpu_kernel" int "$LB_DURATION" >"$workdir/w.$i" 2>/dev/null ) &
		pids+=("$!")
	done
	for pid in "${pids[@]}"; do wait "$pid" || true; done
	awk '/^RESULT/ {s += $2} END {if (s > 0) printf "%.6f", s}' "$workdir"/w.* 2>/dev/null
}

single=(); multi=()
for _ in $(seq 1 "$LB_REPS"); do
	v=$(run_parallel 1);     [ -n "$v" ] && single+=("$v"); lb_cooldown
	v=$(run_parallel "$ncpu"); [ -n "$v" ] && multi+=("$v"); lb_cooldown
done

if [ ${#single[@]} -eq 0 ] || [ ${#multi[@]} -eq 0 ]; then
	lb_status cpu-multi fail "no successful parallel run"
	exit 0
fi

lb_metric cpu-multi threads_1  "ops/s" 1 "${single[@]}"
lb_metric cpu-multi threads_all "ops/s" 1 "${multi[@]}"

# Efficiency from the two medians rather than pairwise, so a single noisy
# sample cannot push the ratio above a physically possible value.
med_single=$(lb_median "${single[@]}")
med_multi=$(lb_median "${multi[@]}")
eff=$(awk -v m="$med_multi" -v s="$med_single" -v c="$ncpu" \
	'BEGIN { if (s > 0 && c > 0) printf "%.3f", m / (s * c) * 100 }')

lb_info cpu_multi_threads "$ncpu"
[ -n "$eff" ] && lb_metric cpu-multi scaling_efficiency "%" 1 "$eff"
lb_status cpu-multi ok
