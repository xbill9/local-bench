#!/usr/bin/env bash
# Network checks.
#
# Loopback throughput and DNS resolution are local and always run. Anything
# that leaves the machine is opt-in via --net, so a plain `bench run` never
# generates outbound traffic you did not ask for.
set -uo pipefail
source "$LB_ROOT/lib/common.sh"

# Loopback throughput: 1 GiB through a pipe. This is really a memory and
# scheduler measurement, and it is the ceiling for any localhost service.
if lb_have dd; then
	samples=()
	for _ in $(seq 1 "$LB_REPS"); do
		v=$( { dd if=/dev/zero bs=1M count=1024 2>/dev/null | dd of=/dev/null bs=1M 2>&1; } \
			| awk '/copied/ {for (i=1;i<=NF;i++) {
				if ($i=="MB/s") {print $(i-1); exit}
				if ($i=="GB/s") {print $(i-1)*1000; exit}}}')
		[ -n "$v" ] && samples+=("$v")
	done
	[ ${#samples[@]} -gt 0 ] && lb_metric network pipe_throughput "MB/s" 1 "${samples[@]}"
fi

if [ "${LB_NET:-0}" != "1" ]; then
	lb_status network ok "local checks only; re-run with --net for external latency"
	exit 0
fi

# --- opt-in, leaves the machine ---

if lb_have getent; then
	samples=()
	for _ in $(seq 1 "$LB_REPS"); do
		start=$(date +%s%N)
		getent hosts deb.debian.org >/dev/null 2>&1 || break
		end=$(date +%s%N)
		samples+=("$(awk -v a="$start" -v b="$end" 'BEGIN {printf "%.3f", (b-a)/1e6}')")
	done
	[ ${#samples[@]} -gt 0 ] && lb_metric network dns_resolve "ms" 0 "${samples[@]}"
fi

if lb_have ping; then
	# Debian's own mirror CDN: relevant to this box's actual apt traffic.
	v=$(ping -c 5 -q -W 2 deb.debian.org 2>/dev/null \
		| awk -F'/' '/^(rtt|round-trip)/ {printf "%.3f", $5}')
	[ -n "$v" ] && lb_metric network ping_deb_debian_org "ms" 0 "$v"
fi

if lb_have curl; then
	samples=()
	for _ in $(seq 1 "$LB_REPS"); do
		v=$(curl -o /dev/null -s -w '%{time_total}' --max-time 15 \
			https://deb.debian.org/debian/dists/stable/Release 2>/dev/null) || break
		samples+=("$(awk -v t="$v" 'BEGIN {printf "%.1f", t*1000}')")
	done
	[ ${#samples[@]} -gt 0 ] && lb_metric network https_fetch "ms" 0 "${samples[@]}"
fi

lb_status network ok "includes external checks"
