#!/usr/bin/env bash
# GPU transfer bandwidth and FP32 throughput, plus the clock and power state
# the run actually achieved.
#
# The clock matters for interpretation: this class of card boosts well above
# its base clock, so a GFLOPS figure is only judgeable next to the SM clock it
# was reached at. A thermally capped card looks broken without it.
set -uo pipefail
source "$LB_ROOT/lib/common.sh"

if ! lb_have nvidia-smi; then
	lb_status gpu skip "no nvidia-smi; no NVIDIA GPU detected"
	exit 0
fi
if ! nvidia-smi -L >/dev/null 2>&1; then
	lb_status gpu skip "nvidia-smi present but no GPU is accessible"
	exit 0
fi

lb_info gpu_clock_max_mhz "$(nvidia-smi --query-gpu=clocks.max.sm --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"

if [ ! -x "$LB_BUILD/gpu_bench" ]; then
	# Still worth recording that a GPU exists even when CUDA is missing.
	lb_status gpu skip "CUDA toolkit (nvcc) not available; GPU detected but not benchmarked"
	exit 0
fi

fail=0
declare -A units=([h2d]="GiB/s" [d2h]="GiB/s" [d2d]="GiB/s" [fp32]="GFLOPS")
for mode in h2d d2h d2d fp32; do
	samples=()
	for _ in $(seq 1 "$LB_REPS"); do
		v=$(lb_kernel gpu_bench "$mode" "$LB_DURATION") || { fail=1; break; }
		samples+=("$v")
		lb_cooldown
	done
	[ ${#samples[@]} -gt 0 ] && lb_metric gpu "$mode" "${units[$mode]}" 1 "${samples[@]}"
done

# Sampled immediately after the load, while the card is still boosted.
read -r sm_clock pwr temp <<<"$(nvidia-smi --query-gpu=clocks.sm,power.draw,temperature.gpu \
	--format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' | tr ',' ' ')"
[ -n "${sm_clock:-}" ] && lb_metric gpu sm_clock_under_load "MHz" 1 "$sm_clock"
[ -n "${pwr:-}" ]      && lb_metric gpu power_under_load "W" 1 "$pwr"
[ -n "${temp:-}" ]     && lb_metric gpu temp_under_load "C" 0 "$temp"

if [ "$fail" -eq 1 ]; then
	lb_status gpu fail "gpu_bench returned no result"
else
	lb_status gpu ok
fi
