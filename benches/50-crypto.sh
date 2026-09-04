#!/usr/bin/env bash
# Crypto throughput via openssl speed.
#
# Mostly a check that hardware acceleration is present and enabled: on this
# class of CPU, AES-NI and the SHA extensions are the difference between
# hundreds of MB/s and several GB/s, and a VM that masks those CPU flags shows
# up here immediately.
set -uo pipefail
source "$LB_ROOT/lib/common.sh"

if ! lb_have openssl; then
	lb_status crypto skip "openssl not installed"
	exit 0
fi
lb_info openssl_version "$(openssl version 2>/dev/null)"

# openssl speed prints one row per algorithm with a column per block size, and
# -seconds applies to EACH block size -- so without -bytes a "1 second" run
# actually takes six. Pinning one 16 KiB buffer keeps the suite inside the
# duration the caller asked for and reports the steady-state large-block rate.
# Values are in 1000s of bytes/sec, so /1000 gives MB/s.
speed_raw() {
	local alg="$1"
	openssl speed -elapsed -seconds "$LB_DURATION" -bytes 16384 "$alg" 2>/dev/null && return 0
	# -bytes predates neither every fork nor every old build; fall back to the
	# default block sweep and take its largest block.
	openssl speed -elapsed -seconds "$LB_DURATION" "$alg" 2>/dev/null
}

speed_mb() {
	local alg="$1"
	speed_raw "$alg" | awk -v alg="$alg" '
		$1 == alg && NF >= 2 {
			v = $NF
			sub(/k$/, "", v)
			if (v + 0 > 0) { printf "%.2f", v / 1000; found = 1 }
		}
		END { if (!found) exit 1 }'
}

ok=0
for alg in sha256 aes-256-cbc; do
	samples=()
	for _ in $(seq 1 "$LB_REPS"); do
		v=$(speed_mb "$alg") || continue
		samples+=("$v")
		lb_cooldown
	done
	if [ ${#samples[@]} -gt 0 ]; then
		lb_metric crypto "${alg//-/_}" "MB/s" 1 "${samples[@]}"
		ok=1
	fi
done

if [ "$ok" -eq 1 ]; then
	lb_status crypto ok
else
	lb_status crypto fail "could not parse openssl speed output"
fi
