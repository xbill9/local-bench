#!/bin/bash
# baseline-scan.sh -- default-install vs hardware gap analysis.
# MUST run before installing anything. Dependency-free: uses only bash,
# coreutils, /proc, /sys, dpkg. Never fails on a missing tool; absence is data.
set -uo pipefail
say() { printf '%s\n' "$*"; }
kv()  { printf '  %-30s %s\n' "$1" "${2:-}"; }

say "##### BASELINE SCAN $(date -Is) #####"

say ""; say "### PLATFORM ###"
kv hostname "$(cat /proc/sys/kernel/hostname)"
kv os "$(. /etc/os-release; echo "$PRETTY_NAME")"
kv kernel "$(uname -r)"
# DMI via sysfs -- needs no dmidecode
for f in sys_vendor product_name bios_version bios_date chassis_asset_tag; do
  [ -r "/sys/class/dmi/id/$f" ] && kv "dmi.$f" "$(cat /sys/class/dmi/id/$f 2>/dev/null)"
done
kv virt "$(systemd-detect-virt 2>/dev/null; true)"

say ""; say "### HARDWARE PRESENT ###"
kv cpu_model "$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
kv cpu_threads "$(grep -c ^processor /proc/cpuinfo)"
kv cpu_microcode "$(grep -m1 '^microcode' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
kv mem_total_kb "$(grep MemTotal /proc/meminfo | awk '{print $2}')"
kv swap_total_kb "$(grep SwapTotal /proc/meminfo | awk '{print $2}')"
# ISA features that imply tooling/library needs
ISA=""
for f in avx2 avx512f avx512_bf16 avx512_fp16 amx_tile amx_bf16 amx_int8 sha_ni vaes aes rdrand; do
  grep -qm1 " $f\( \|$\)" /proc/cpuinfo && ISA="$ISA $f"
done
kv cpu_isa_notable "${ISA# }"
kv pci_device_count "$(ls -1 /sys/bus/pci/devices 2>/dev/null | wc -l)"
kv usb_device_count "$(ls -1d /sys/bus/usb/devices/*-* 2>/dev/null | wc -l)"
kv block_devices "$(lsblk -dno NAME,SIZE 2>/dev/null | tr '\n' ';' || echo unavailable)"
kv nvme_present "$(ls -1d /sys/class/nvme/nvme* 2>/dev/null | wc -l)"
kv net_ifaces "$(ls -1 /sys/class/net | grep -v '^lo$' | tr '\n' ' ')"
kv thermal_zones "$(ls -1d /sys/class/thermal/thermal_zone* 2>/dev/null | wc -l)"
kv cpufreq_present "$([ -d /sys/devices/system/cpu/cpu0/cpufreq ] && echo yes || echo no)"
kv rapl_present "$([ -d /sys/class/powercap/intel-rapl ] && echo yes || echo no)"
kv throttle_counters "$([ -d /sys/devices/system/cpu/cpu0/thermal_throttle ] && echo yes || echo no)"
kv tpm_present "$(ls -1 /dev/tpm* 2>/dev/null | wc -l)"
kv gpu_drm_nodes "$(ls -1 /dev/dri/ 2>/dev/null | wc -l)"

say ""; say "### DEFAULT PACKAGE SET ###"
kv dpkg_installed_count "$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)"
kv apt_sources "$(grep -rhoE '^(deb|Types:)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | wc -l) entries"
say "  -- diagnostic/firmware packages present in the base image --"
for p in pciutils usbutils dmidecode lshw hwinfo nvme-cli smartmontools hdparm \
         lm-sensors ethtool sysstat linux-cpupower powertop numactl hwloc \
         intel-microcode amd64-microcode firmware-linux-free fwupd \
         build-essential gcc make git curl wget ca-certificates \
         gawk mawk jq python3 unzip ripgrep; do
  s=$(dpkg-query -f '${db:Status-Status}' -W "$p" 2>/dev/null)
  [ "$s" = "installed" ] && printf '    PRESENT  %s\n' "$p" || printf '    absent   %s\n' "$p"
done

say ""; say "### OBSERVABILITY TOOL AVAILABILITY ###"
for t in lspci lsusb dmidecode lshw nvme smartctl hdparm sensors ethtool \
         turbostat powertop cpupower perf numactl lstopo iostat \
         gcc make git curl wget unzip python3 jq awk; do
  p=$(PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin" command -v "$t" 2>/dev/null)
  [ -n "$p" ] && printf '    OK       %-12s %s\n' "$t" "$p" || printf '    MISSING  %-12s\n' "$t"
done

say ""; say "### GAP: HARDWARE PRESENT, NO TOOL TO OBSERVE IT ###"
gap() { printf '    GAP  %-22s %s\n' "$1" "$2"; }
have() { PATH="/usr/local/sbin:/usr/sbin:/sbin:/usr/bin:/bin" command -v "$1" >/dev/null 2>&1; }
[ "$(ls -1 /sys/bus/pci/devices 2>/dev/null | wc -l)" -gt 0 ] && ! have lspci && \
  gap "PCI bus" "$(ls -1 /sys/bus/pci/devices | wc -l) devices, no lspci (pciutils)"
[ "$(ls -1d /sys/class/nvme/nvme* 2>/dev/null | wc -l)" -gt 0 ] && ! have nvme && \
  gap "NVMe storage" "present, no nvme-cli"
[ "$(ls -1d /sys/class/nvme/nvme* 2>/dev/null | wc -l)" -gt 0 ] && ! have smartctl && \
  gap "Disk health" "NVMe present, no smartmontools"
[ -r /sys/class/dmi/id/product_name ] && ! have dmidecode && \
  gap "DMI/SMBIOS" "readable via sysfs, no dmidecode for full tables"
[ "$(ls -1d /sys/class/thermal/thermal_zone* 2>/dev/null | wc -l)" -gt 0 ] && ! have sensors && \
  gap "Thermal sensors" "zones present, no lm-sensors"
[ -d /sys/devices/system/cpu/cpu0/cpufreq ] && ! have cpupower && \
  gap "CPU frequency" "cpufreq present, no cpupower"
[ -d /sys/class/powercap/intel-rapl ] && ! have turbostat && \
  gap "RAPL power" "present, no turbostat"
[ -n "$(ls -1 /sys/class/net | grep -v '^lo$')" ] && ! have ethtool && \
  gap "Network adapter" "NIC present, no ethtool"
grep -qm1 ' avx512f' /proc/cpuinfo && ! have lscpu && gap "AVX-512" "present, no lscpu"
echo "    (end of gaps)"

say ""; say "### CLAUDE CODE PREREQUISITES ###"
kv arch "$(uname -m)"
kv glibc "$(ldd --version 2>/dev/null | head -1)"
for t in curl node npm unzip; do
  p=$(command -v "$t" 2>/dev/null); [ -n "$p" ] && kv "$t" "$p" || kv "$t" "MISSING"
done
kv claude_installed "$(command -v claude 2>/dev/null || echo no)"
kv home_writable "$([ -w "$HOME" ] && echo yes || echo no)"
kv outbound_https "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://claude.ai/install.sh 2>/dev/null || echo FAILED)"

say ""; say "##### END BASELINE SCAN #####"
