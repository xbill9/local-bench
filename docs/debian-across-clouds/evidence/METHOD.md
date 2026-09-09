# Method — baseline Debian 13 gap analysis across four platforms
Captured 2026-09-09. All figures below come from scan-*.txt in this directory,
produced by baseline-scan.sh, which uses only bash/coreutils//proc//sys/dpkg so
it runs on a pristine image with nothing installed.

## Platforms and images
| Platform | Image | Shape | CPU |
|---|---|---|---|
| local  | Debian 13 installed on bare metal | Lenovo 83B1 | i7-1360P (Raptor Lake) |
| AWS    | ami-0871da4641e8b4413 debian-13-amd64-20260831-2587 | c7i.large | Xeon Platinum 8488C (Sapphire Rapids) |
| GCE    | debian-13-trixie-v20260908 (debian-cloud) | c4-standard-2 | Xeon Platinum 8581C (Emerald Rapids) |
| Azure  | Debian:debian-13:13-gen2:0.20260831.2587 | Standard_D2s_v7 | Xeon 6973P-C (Granite Rapids) |

AWS and Azure ship the SAME upstream Debian build (2587, 2026-08-31).
GCE builds its own, dated 2026-09-08.
All three clouds run kernel 6.12.107+deb13-cloud-amd64.
Local runs 7.1.8+deb13-amd64 from backports -- NOT the same kernel.

## Contamination note
The FIRST AWS instance (i-082de18635e2beb2b) had ~20 packages installed by
cloud-init before it was scanned and is NOT a baseline. It was discarded for
this analysis. A second pristine instance (i-07a6b25fe56ccca05) was launched
with no user-data and scanned before anything was installed.

## Correction to an earlier finding
An earlier laptop scan reported dmidecode, nvme-cli, smartmontools, hdparm,
ethtool, powertop and turbostat as MISSING. That was wrong: all are installed.
The check used bare `command -v` under a PATH containing no /usr/sbin, /sbin
or /usr/local/sbin. baseline-scan.sh sets an explicit PATH for its tool probe
and cross-checks against dpkg, so it does not repeat the error.
Laptop tools genuinely absent: hwinfo perf numactl hwloc fio stress-ng
sysbench iperf3 clinfo gawk cmake clang node npm.

## Default package count
local 1923 | AWS 337 | GCE 350 | Azure 328

## Package presence in the base image (dpkg, not PATH)
                       LOCAL  AWS  GCE  AZURE
pciutils               YES    YES  YES  YES
ethtool                YES    YES  YES  YES
curl / wget / python3  YES    YES  YES  YES
dmidecode              YES    -    YES  -
nvme-cli               YES    -    YES  -
usbutils               YES    -    -    -
lshw                   YES    -    -    -
smartmontools          YES    -    -    -
hdparm                 YES    -    -    -
lm-sensors             YES    -    -    -
sysstat                YES    -    -    -
linux-cpupower         YES    -    -    -
powertop               YES    -    -    -
intel-microcode        YES    -    -    -
fwupd                  YES    -    -    -
build-essential/gcc/make YES  -    -    -
git                    YES    -    -    -
unzip                  YES    -    -    -
numactl / hwloc / gawk -      -    -    -

## Hardware / instrumentation exposure
FIELD              LOCAL      AWS         GCE         AZURE
dmi.sys_vendor     LENOVO     Amazon EC2  Google      Microsoft Corporation
virt               none       amazon      google      microsoft
cpu_microcode      0x6134     0x2b000661  0xffffffff  0xffffffff
mem_total_kb       16108896   3918296     7102784     8133308
swap_total_kb      16509948   0           0           0
nvme_present       1          1           1           2
thermal_zones      10         0           0           0
cpufreq_present    yes        no          no          yes
rapl_present       yes        no          no          no
throttle_counters  yes        no          no          no
tpm_present        2          0           2           0
pci_device_count   24         46          16          3
usb_device_count   30         0           0           0

## Gaps the scan detected (hardware present, no tool to observe it)
AWS:   NVMe no nvme-cli; NVMe no smartmontools; DMI no dmidecode
GCE:   NVMe no smartmontools
Azure: NVMe no nvme-cli; NVMe no smartmontools; DMI no dmidecode;
       cpufreq present but no cpupower
local: none (its gaps are absent TOOLS, not unobservable hardware)

## Claude Code install on a pristine image
Command: curl -fsSL https://claude.ai/install.sh | bash
| Platform | Elapsed | Version | Installed size |
|---|---|---|---|
| AWS   | 10 s | 2.1.266 | 206 MB |
| GCE   |  8 s | 2.1.266 | 206 MB |
| Azure | 12 s | 2.1.266 | 206 MB |

Runtime deps (ldd on the AWS binary): linux-vdso, librt, libc, libpthread,
libdl, ld-linux. glibc 2.41 on all four hosts.
NO node, NO npm, NO unzip required -- all three were absent and it still worked.
All three emitted the same warning: "~/.local/bin is not in your PATH".

## NOT measured -- do not assert as measured
- Hourly price of any instance on any cloud. No pricing API was called.
- Whether Azure's cpufreq is writable/effective, only that the directory exists.
- Any performance number for GCE or Azure. local-bench was not run on them.
- Laptop 5.0 GHz peak boost -- that is lscpu's spec value, not an observation.
