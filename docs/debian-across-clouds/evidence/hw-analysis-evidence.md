# Hardware analysis evidence — laptop vs EC2
Captured 2026-09-09 by Claude Code over SSH. Both hosts Debian 13 (trixie).

## Hosts
| | debian (laptop) | ip-172-31-9-2 (EC2) |
|---|---|---|
| CPU | 13th Gen Intel Core i7-1360P | Intel Xeon Platinum 8488C |
| Family/Model/Stepping | 6 / 186 / 2 (Raptor Lake) | 6 / 143 / 8 (Sapphire Rapids) |
| Topology | 12 cores / 16 threads | 1 core / 2 threads (c7i.large) |
| L3 | 18 MiB | 105 MiB (socket-visible) |
| RAM | 15 GiB + 15 GiB swap | 3.7 GiB, no swap |
| Kernel | 7.1.8+deb13-amd64 (backports) | 6.12.107+deb13-cloud-amd64 (stock) |
| Microcode | 0x6134 (from BIOS) | 0x2b000661 |
| Instance | Lenovo 83B1 | c7i.large, us-east-1a, ami-0871da4641e8b4413 |

## ISA divergence (decides -march=native)
EC2 Xeon 8488C has, laptop i7-1360P does NOT:
  avx512f avx512bw avx512cd avx512dq avx512vl avx512ifma avx512vbmi
  avx512_vbmi2 avx512_vnni avx512_bitalg avx512_vpopcntdq avx512_fp16 avx512_bf16
  amx_tile amx_bf16 amx_int8
Both have: avx2 avx_vnni sha_ni vaes sse4_2
Both built with compile_flags "-O2 -march=native -pipe" -> different ISA targets.

## Frequency under sustained all-core load (20 s)
EC2 (turbostat, 2 vCPU, stress-ng matrixprod):
  3271 3271 3271 3270 3270 3270 3271 3271 3271 3271 3271 3271 MHz
  Busy% 100.00 throughout. Variance: 1 MHz (0.03%).
  TSC_MHz 2400. PkgWatt reads 0.00 -- RAPL not exposed to guest.

Laptop (scaling_cur_freq mean of 16 CPUs, 16 busy loops):
  t+4s 3500 MHz / t+8s 3458 / t+12s 3445 / t+16s 3483
  Package temp after: 88.0 C
  core_throttle_count 15232 -> 16221 = 989 new throttle events in 20 s

## Environmental instrumentation available
| Facility | laptop | EC2 |
|---|---|---|
| cpufreq / governor | yes (intel_pstate, powersave, EPP performance) | ABSENT |
| thermal zones | 10 zones | none (2 cooling_device stubs only) |
| lm-sensors | coretemp, nvme, acpitz, BAT0 | "No sensors found!" |
| RAPL / powercap | intel-rapl present | ABSENT |
| thermal_throttle counters | yes | ABSENT |
| turbostat Bzy_MHz | n/a (not installed) | yes |
| turbostat PkgWatt | n/a | reads 0.00 |

## Driver / firmware state
EC2: kernel taint 0. Zero firmware load failures in dmesg.
  Devices without a bound driver (all emulated legacy, expected under KVM):
    00:00.0 440FX host bridge, 00:01.0 PIIX3 ISA,
    00:01.3 PIIX4 ACPI, 00:03.0 Amazon VGA
  ENA driver bound on enp39s0. Nitro shaping counters all zero:
    bw_in_allowance_exceeded 0, bw_out_allowance_exceeded 0,
    pps_allowance_exceeded 0, conntrack_allowance_exceeded 0
  Storage: Amazon EBS NVMe, FW 2.0, 20 GB gp3.
    smart-log: critical_warning 0, media_errors 0, percentage_used 0%,
    temperature reads -273 C (not implemented by EBS)
  dmesg noise (benign): systemd-ssh-generator AF_VSOCK failures x15,
    i8042 "Keylock active"
  DMI: Amazon EC2 / c7i.large / BIOS 1.0 dated 10/16/2017

Laptop: kernel taint 0. One real firmware failure:
  r8152 rtl_nic/rtl8156b-2.fw load failed (-2) at 2.72 s despite the file
  being present on disk AND in the initramfs -- switch_root race.
  Adapter runs at 2.5 Gb/s unpatched.
  iwl-debug-yoyo.bin failure is benign (debug-only, never shipped).

## Steal time
EC2 vmstat 1 3 under idle: st column 0 across all samples.

## Benchmark run compared (./bench compare debian ip-172-31-9-2)
  cpu-single int      5.509e+08 -> 3.62e+08   -34.3% ops/s
  cpu-single float    4.927e+09 -> 3.249e+09  -34.1% ops/s
  cpu-single sieve    6.243e+08 -> 3.468e+08  -44.5% ops/s
  cpu-multi threads_1 5.49e+08  -> 3.621e+08  -34.1% ops/s
  cpu-multi threads_all 6.363e+09 -> 7.014e+08 -89.0% ops/s  (16 thr vs 2)
  cpu-multi scaling_efficiency 72.43 -> 96.86 %
  memory read  23.28 -> 10.15 GiB/s   -56.4%
  memory copy  46.04 -> 18.59 GiB/s   -59.6%
  memory latency 90.17 -> 134.8 ns    +49.5%
  disk seq_write 3600 -> 173 MB/s     -95.2%
  disk seq_read  5400 -> 131 MB/s     -97.6%
  disk fsync_latency 0.507 -> 3.223 ms +535.7%
  crypto sha256 2396 -> 1568 MB/s     -34.5%
  crypto aes_256_cbc 1772 -> 1159 MB/s -34.6%

## NOT measured (do not assert as measured)
- EC2 hourly price. No Pricing API call was made. Any dollar figure is
  an estimate from model knowledge, not an artifact.
- Laptop single-thread peak boost clock (5.0 GHz is the lscpu CPU max MHz
  spec value, not an observed measurement).
