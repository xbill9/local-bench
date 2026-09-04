#!/usr/bin/env bash
# Storage throughput and durability latency.
#
# Sequential read and write use O_DIRECT where the filesystem supports it, so
# the numbers describe the device instead of the page cache. fsync latency is
# measured separately because it, not streaming bandwidth, is what bounds
# databases and any write-ahead log on this box.
set -uo pipefail
source "$LB_ROOT/lib/common.sh"

dir="${LB_DISK_DIR:-$LB_ROOT/.disktmp}"
size_mib="${LB_DISK_MIB:-512}"

mkdir -p "$dir" 2>/dev/null || { lb_status disk skip "cannot create $dir"; exit 0; }
tmpfile="$dir/lb-disk.dat"
# Always clean up: this file is a large chunk of the user's disk.
trap 'rm -f "$tmpfile"; rmdir "$dir" 2>/dev/null || true' EXIT

avail_mib=$(df -PBM "$dir" 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}')
if [ -n "$avail_mib" ] && [ "$avail_mib" -lt $((size_mib * 2)) ]; then
	lb_status disk skip "only ${avail_mib} MiB free in $dir, need $((size_mib * 2))"
	exit 0
fi
lb_info disk_test_dir "$dir"
lb_info disk_test_mib "$size_mib"

# Probe O_DIRECT once. tmpfs and some network filesystems reject it, in which
# case results are cache-influenced and are labelled as such.
direct_w="oflag=direct"; direct_r="iflag=direct"; mode="O_DIRECT"
if ! dd if=/dev/zero of="$tmpfile" bs=1M count=1 oflag=direct >/dev/null 2>&1; then
	direct_w="conv=fdatasync"; direct_r=""; mode="buffered+fdatasync"
	lb_note "disk: O_DIRECT unavailable in $dir; read figures include page cache"
fi
lb_info disk_io_mode "$mode"
rm -f "$tmpfile"

# dd reports throughput on its last stderr line; take the value and normalise
# GB/s to MB/s so every sample shares a unit.
dd_rate_mb() {
	awk '/copied/ {
		for (i = 1; i <= NF; i++) {
			if ($i == "MB/s") { print $(i-1); exit }
			if ($i == "GB/s") { print $(i-1) * 1000; exit }
			if ($i == "kB/s") { print $(i-1) / 1000; exit }
		}
	}'
}

wr=(); rd=()
for _ in $(seq 1 "$LB_REPS"); do
	v=$(dd if=/dev/zero of="$tmpfile" bs=1M count="$size_mib" $direct_w 2>&1 | dd_rate_mb)
	[ -n "$v" ] && wr+=("$v")

	# Without O_DIRECT the file we just wrote is hot in cache; ask the kernel
	# to drop it if we are privileged enough, so the read is not a memory test.
	if [ "$mode" != "O_DIRECT" ] && [ -w /proc/sys/vm/drop_caches ]; then
		sync; echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
	fi
	v=$(dd if="$tmpfile" of=/dev/null bs=1M $direct_r 2>&1 | dd_rate_mb)
	[ -n "$v" ] && rd+=("$v")
	lb_cooldown
done

[ ${#wr[@]} -gt 0 ] && lb_metric disk seq_write "MB/s" 1 "${wr[@]}"
[ ${#rd[@]} -gt 0 ] && lb_metric disk seq_read  "MB/s" 1 "${rd[@]}"

# fsync latency: 200 small synchronous writes, reported as mean ms per commit.
sync_samples=()
for _ in $(seq 1 "$LB_REPS"); do
	v=$(dd if=/dev/zero of="$tmpfile.sync" bs=4k count=200 oflag=dsync 2>&1 \
		| awk '/copied/ {for (i=1;i<=NF;i++) if ($i=="s,") {print ($(i-1)/200)*1000; exit}}')
	[ -n "$v" ] && sync_samples+=("$v")
	rm -f "$tmpfile.sync"
done
[ ${#sync_samples[@]} -gt 0 ] && lb_metric disk fsync_latency "ms" 0 "${sync_samples[@]}"

if [ ${#wr[@]} -eq 0 ] && [ ${#rd[@]} -eq 0 ]; then
	lb_status disk fail "dd produced no parseable throughput"
else
	lb_status disk ok
fi
