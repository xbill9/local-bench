# shellcheck shell=bash
# Shared helpers for local-bench. Sourced by ./bench and by every bench module.
#
# Definitions here are consumed by the sourcing script, which ShellCheck
# cannot see from this file alone -- hence the blanket SC2034.
# shellcheck disable=SC2034

set -o pipefail

LB_ROOT="${LB_ROOT:?LB_ROOT must be set}"
LB_BUILD="$LB_ROOT/build"
LB_RESULTS="$LB_ROOT/results"

# --- terminal output -------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
	C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'
else
	C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""
fi

lb_say()  { printf '%s\n' "$*" >&2; }
lb_step() { printf '%s==>%s %s\n' "$C_CYA" "$C_RESET" "$*" >&2; }
lb_warn() { printf '%swarning:%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
lb_err()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
lb_die()  { lb_err "$*"; exit 1; }
lb_have() { command -v "$1" >/dev/null 2>&1; }

# --- record emission -------------------------------------------------------
# Modules append tab-separated records to $LB_OUT. The runner turns them into
# JSON in one pass (lib/tojson.awk), so no module ever has to format JSON.
#
#   M  suite  metric  unit  higher_is_better  v1,v2,...   a measurement
#   S  suite  status  note                                 suite outcome
#   I  key    value                                        host/system fact
#   W  message                                             run-level warning

lb_metric() {
	# lb_metric <suite> <metric> <unit> <hib:1|0> <sample>...
	local suite="$1" metric="$2" unit="$3" hib="$4"; shift 4
	local joined=""
	local v
	for v in "$@"; do
		[ -n "$v" ] || continue
		joined="${joined:+$joined,}$v"
	done
	[ -n "$joined" ] || return 0
	printf 'M\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$metric" "$unit" "$hib" "$joined" >>"$LB_OUT"
}

lb_status() {
	# lb_status <suite> <ok|skip|fail> [note]
	printf 'S\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$LB_OUT"
}

lb_info() {
	# lb_info <key> <value>   -- blank values are dropped rather than stored
	[ -n "${2:-}" ] || return 0
	printf 'I\t%s\t%s\n' "$1" "$2" >>"$LB_OUT"
}

lb_note() { printf 'W\t%s\n' "$1" >>"$LB_OUT"; }

# --- measurement helpers ---------------------------------------------------

# Run a kernel binary and echo the numeric field of its "RESULT <n> <chk>" line.
# Returns non-zero (and echoes nothing) if the kernel fails or prints nothing,
# so a caller can distinguish a failed sample from a slow one.
lb_kernel() {
	local bin="$1"; shift
	local line
	line=$("$LB_BUILD/$bin" "$@" 2>/dev/null) || return 1
	case "$line" in
		RESULT\ *) printf '%s' "$(printf '%s' "$line" | cut -d' ' -f2)" ;;
		*) return 1 ;;
	esac
}

# Number of CPUs this process may actually use. nproc already honours the
# affinity mask and cgroup quota where the coreutils build supports it, which
# matters inside a container where /proc/cpuinfo over-reports.
lb_ncpu() {
	local n
	n=$(nproc 2>/dev/null) || n=""
	[ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null && { printf '%s' "$n"; return; }
	printf '1'
}

lb_mem_total_mib() {
	awk '/^MemTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || printf '0'
}

lb_mem_avail_mib() {
	awk '/^MemAvailable:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || printf '0'
}

# Sum of per-core thermal throttle events. Compared before and after the run to
# detect a throttled (and therefore untrustworthy) measurement.
lb_throttle_count() {
	local total=0 f v
	for f in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
		[ -r "$f" ] || continue
		v=$(cat "$f" 2>/dev/null) || continue
		case "$v" in ''|*[!0-9]*) continue ;; esac
		total=$((total + v))
	done
	printf '%s' "$total"
}

# Hottest CPU thermal zone, in whole degrees C. Empty if unreadable.
#
# True package sensors are preferred and acpitz is only a fallback: acpitz
# zones are often chassis or skin sensors reading well below the die, so
# mixing them into the same max would understate how hot the CPU actually got.
lb_cpu_temp_c() {
	local tier best t z zt
	for tier in pkg acpi; do
		best=""
		for z in /sys/class/thermal/thermal_zone*; do
			# Both reads must succeed; the || arm is the intended fallthrough.
			# shellcheck disable=SC2015
			[ -r "$z/type" ] && [ -r "$z/temp" ] || continue
			zt=$(cat "$z/type" 2>/dev/null) || continue
			case "$tier:$zt" in
				pkg:x86_pkg_temp|pkg:coretemp|pkg:cpu-thermal) ;;
				acpi:acpitz) ;;
				*) continue ;;
			esac
			t=$(cat "$z/temp" 2>/dev/null) || continue
			case "$t" in ''|*[!0-9]*) continue ;; esac
			t=$((t / 1000))
			if [ -z "$best" ] || [ "$t" -gt "$best" ]; then
				best="$t"
			fi
		done
		[ -n "$best" ] && { printf '%s' "$best"; return; }
	done
	printf ''
}

# Mean current clock across all CPUs, in MHz. Empty if cpufreq is unavailable
# (common inside VMs and containers).
lb_cpu_mhz() {
	local sum=0 n=0 f v
	for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
		[ -r "$f" ] || continue
		v=$(cat "$f" 2>/dev/null) || continue
		case "$v" in ''|*[!0-9]*) continue ;; esac
		sum=$((sum + v / 1000)); n=$((n + 1))
	done
	[ "$n" -gt 0 ] || { awk '/^cpu MHz/ {printf "%d", $4; exit}' /proc/cpuinfo 2>/dev/null; return; }
	printf '%s' "$((sum / n))"
}

# Let the machine settle so one suite's heat does not contaminate the next.
lb_cooldown() {
	local s="${1:-$LB_COOLDOWN}"
	[ "${s:-0}" -gt 0 ] 2>/dev/null || return 0
	sleep "$s"
}

# Median of the numeric arguments. Used where a module needs a summary value
# during the run; the result file's own statistics are computed independently
# in lib/tojson.awk.
lb_median() {
	[ "$#" -gt 0 ] || return 1
	printf '%s\n' "$@" | sort -n | awk '
		{v[NR] = $1}
		END {
			if (NR == 0) exit 1
			print (NR % 2) ? v[(NR+1)/2] : (v[NR/2] + v[NR/2+1]) / 2.0
		}'
}
