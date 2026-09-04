# shellcheck shell=bash
# Stable platform identity for local-bench.
#
# A "system" is a platform, not a piece of hardware: the same laptop running
# Debian bare-metal, a Crostini container and ChromeOS Flex is three systems,
# because telling those apart is the entire point of the comparison.
#
# The id is a pure function of host facts that every run already records, so it
# can be recomputed for runs written before this file existed. Nothing needs
# migrating and no run stores a foreign key that could go stale.

# Short, stable hash. md5sum where available, cksum as the POSIX fallback, so
# this works on a stripped-down container with no coreutils extras.
lb_hash() {
	if command -v md5sum >/dev/null 2>&1; then
		printf '%s' "$1" | md5sum | cut -c1-8
	elif command -v cksum >/dev/null 2>&1; then
		printf '%s' "$1" | cksum | awk '{printf "%08x", $1}'
	else
		# Last resort: a deterministic checksum in awk.
		printf '%s' "$1" | awk '{
			for (i = 1; i <= length($0); i++)
				h = (h * 31 + index(" " substr($0, i, 1), substr($0, i, 1))) % 4294967296
		} END { printf "%08x", h }'
	fi
}

# Human-readable platform class, derived from what the run recorded.
# Answers "what kind of machine is this", which is what a leaderboard row needs
# next to the raw numbers.
lb_platform_label() {
	local platform="$1" container="$2" virt="$3"
	if [ -n "$platform" ]; then printf '%s' "$platform"; return; fi
	if [ -n "$container" ]; then printf '%s' "$container"; return; fi
	if [ -n "$virt" ] && [ "$virt" != "none" ]; then printf '%s' "$virt"; return; fi
	printf 'bare-metal'
}

# Compute the system_id (and the fingerprint it came from) for one flattened
# run. Echoes: "<system_id>\t<platform>\t<fingerprint>".
#
# Memory is rounded to whole GiB deliberately: MemTotal shifts by a few MiB
# across kernels and when a GPU reserves memory, and that must not fork one
# machine into several systems.
lb_system_of_flat() {
	local flat="$1"
	awk -F'\t' '
		$1 == "H" { h[$2] = $3 }
		END {
			gib = int((h["mem_total_mib"] + 512) / 1024)
			platform = h["platform"]
			if (platform == "") platform = h["container"]
			if (platform == "" && h["virt"] != "none") platform = h["virt"]
			if (platform == "") platform = "bare-metal"
			printf "%s|%s|%s|%s|%s|%dGiB|%s\n",
				h["hostname"], h["os"], h["arch"],
				h["cpu_model"], h["cpu_threads"], gib, platform
		}' "$flat"
}
