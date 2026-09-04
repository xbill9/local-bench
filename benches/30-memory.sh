#!/usr/bin/env bash
# Main-memory bandwidth and latency.
#
# Buffers are deliberately sized far beyond any last-level cache so these are
# DRAM numbers. copy allocates 2 buffers and triad 3, so the buffer size is
# chosen against available memory with the worst case in mind.
set -uo pipefail
source "$LB_ROOT/lib/common.sh"

if [ ! -x "$LB_BUILD/mem_bw" ]; then
	lb_status memory skip "mem_bw not built"
	exit 0
fi

avail=$(lb_mem_avail_mib)
# Cap at 512 MiB (plenty past any LLC) and never claim more than an eighth of
# free memory, so triad's 3 buffers stay well clear of swapping.
buf=512
[ "$avail" -gt 0 ] && [ $((avail / 8)) -lt "$buf" ] && buf=$((avail / 8))
if [ "$buf" -lt 32 ]; then
	lb_status memory skip "only ${avail} MiB available, need >=256 MiB free"
	exit 0
fi
lb_info mem_bench_buffer_mib "$buf"

fail=0
for mode in read write copy triad; do
	samples=()
	for _ in $(seq 1 "$LB_REPS"); do
		v=$(lb_kernel mem_bw "$mode" "$buf" "$LB_DURATION") || { fail=1; break; }
		samples+=("$v")
		lb_cooldown
	done
	[ ${#samples[@]} -gt 0 ] && lb_metric memory "$mode" "GiB/s" 1 "${samples[@]}"
done

# Latency needs two buffers of its own and is reported in ns, where lower wins.
lat_buf=$((buf / 2))
[ "$lat_buf" -lt 16 ] && lat_buf=16
samples=()
for _ in $(seq 1 "$LB_REPS"); do
	v=$(lb_kernel mem_bw latency "$lat_buf" "$LB_DURATION") || { fail=1; break; }
	samples+=("$v")
	lb_cooldown
done
[ ${#samples[@]} -gt 0 ] && lb_metric memory latency "ns" 0 "${samples[@]}"

if [ "$fail" -eq 1 ]; then
	lb_status memory fail "mem_bw returned no result (out of memory?)"
else
	lb_status memory ok
fi
