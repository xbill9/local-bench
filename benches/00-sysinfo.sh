#!/usr/bin/env bash
# Host fingerprint. Records no timings; everything here exists so that two
# result files can be judged comparable (or not) before their numbers are
# diffed.
set -uo pipefail
source "$LB_ROOT/lib/common.sh"

lb_info hostname   "$(hostname 2>/dev/null)"
lb_info os         "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")"
lb_info kernel     "$(uname -r)"
lb_info arch       "$(uname -m)"

lb_info cpu_model  "$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)"
lb_info cpu_threads "$(lb_ncpu)"
lb_info cpu_cores  "$(lscpu 2>/dev/null | awk -F': +' '/^Core\(s\) per socket:/ {c=$2} /^Socket\(s\):/ {s=$2} END {if (c && s) print c*s}')"
lb_info cpu_mhz_max "$(awk '{printf "%d", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)"
lb_info cpu_governor "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
lb_info cpu_flags_notable "$(awk '/^flags/ {n=""; if (/avx512f/) n=n" avx512"; else if (/avx2/) n=n" avx2"; else if (/avx/) n=n" avx"; if (/ sse4_2/) n=n" sse4.2"; print substr(n,2); exit}' /proc/cpuinfo 2>/dev/null)"

lb_info mem_total_mib "$(lb_mem_total_mib)"
lb_info mem_avail_mib "$(lb_mem_avail_mib)"
lb_info swap_total_mib "$(awk '/^SwapTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null)"

# Virtualisation and container context. A container sharing a host with noisy
# neighbours produces numbers that cannot be compared against bare metal.
if lb_have systemd-detect-virt; then
	lb_info virt "$(systemd-detect-virt 2>/dev/null || printf 'none')"
fi
if [ -f /.dockerenv ]; then
	lb_info container docker
elif grep -qa 'docker\|containerd\|lxc' /proc/1/cgroup 2>/dev/null; then
	lb_info container "$(grep -ao 'docker\|containerd\|lxc' /proc/1/cgroup 2>/dev/null | head -1)"
fi
# Crostini (ChromeOS Linux) identifies itself here; worth recording because its
# storage is virtio-backed and its disk numbers are not host numbers.
[ -e /dev/.cros_milestone ] && lb_info platform crostini

lb_info uptime_sec "$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)"
lb_info loadavg_1m "$(awk '{print $1}' /proc/loadavg 2>/dev/null)"

# The kernels are compiled locally, so the toolchain is part of the result.
lb_info compiler "$(${CC:-cc} --version 2>/dev/null | head -1)"
lb_info compile_flags "$LB_CFLAGS"

lb_info root_fs "$(df -PT "$LB_ROOT" 2>/dev/null | awk 'NR==2 {print $2}')"
lb_info root_dev "$(df -P "$LB_ROOT" 2>/dev/null | awk 'NR==2 {print $1}')"

if lb_have nvidia-smi; then
	gpu=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1)
	if [ -n "$gpu" ]; then
		lb_info gpu_name "$(printf '%s' "$gpu" | cut -d, -f1 | sed 's/^ *//')"
		lb_info gpu_mem "$(printf '%s' "$gpu" | cut -d, -f2 | sed 's/^ *//')"
		lb_info gpu_driver "$(printf '%s' "$gpu" | cut -d, -f3 | sed 's/^ *//')"
	fi
fi

lb_status sysinfo ok
