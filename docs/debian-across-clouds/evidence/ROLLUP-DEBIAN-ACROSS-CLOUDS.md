# Debian 13 across three clouds -- roll-up
Method: Claude Code installed and authenticated ON each VM, then each instance
analysed ITSELF via `claude -p "<brief>" --allowedTools Bash`. Raw reports in
deep-aws.txt / deep-gce.txt / deep-azure.txt; brief in deep-analysis-prompt.txt.
The LOCAL laptop was given the IDENTICAL brief via the same command
(deep-local.txt), so all four platforms are methodologically symmetric.
2026-09-09.

## SIDE EFFECT ON THE LOCAL RUN -- disclosed, verified, not reverted
The laptop's Claude instance ran `update-initramfs -u -k 7.1.8+deb13-amd64`
during its analysis, rebuilding /boot/initrd.img-7.1.8+deb13-amd64 at 16:27.
It disclosed this at the top of its own report. The brief said "use your Bash
tool" and did NOT say read-only -- that omission is the brief's, not the
model's. Verified afterwards: initrd lists 1903 files, both installed kernels
have matching initrds, the 6.12 fallback is untouched, /boot has 406G free.
The rebuild also fixed the r8152 firmware gap described below. The three cloud
instances took no write actions. If this method is reused, the brief should
say read-only explicitly.

## LOCAL (bare metal) -- what the symmetric run added
- Root cause of the r8152 firmware failure, better than the earlier guess:
  firmware-realtek was installed 2026-09-07 17:35, AFTER the initrd in use was
  built. The NIC probed at t=2.718s with only the initrd visible; root mounted
  at t=4.073s. So it was a stale initrd, not merely a switch_root race.
  The boot-time adapter was also unplugged at t=436s; the currently attached
  one reports firmware-version "rtl8156b-2 v3 10/20/23" via ethtool.
- Microcode direction is the reverse of the usual complaint: intel-microcode
  ships rev 0x6133 for sig 0x000b06a2 while the L4CN31WW BIOS already supplies
  0x6134, so the kernel correctly refuses the downgrade. lscpu agrees:
  "Old microcode: Not affected".
- 24 PCI functions, 20 bound, 4 unbound (GNA, PCH Shared SRAM, LPC/eSPI, SPI).
  None is a gap. The SPI/BIOS-flash controller is deliberately left unbound by
  Debian to prevent OS-side BIOS writes.
- Kernel taint 0. ~69 ACPI AE_ALREADY_EXISTS errors from Lenovo's DSDT
  declaring USB _UPC/_PLD twice -- vendor defect, cosmetic.
- Zero machine checks; EDAC mc0/mc1 ce_count=0 ue_count=0.
- UEFI with Secure Boot ENABLED and TPM present -- the only one of the four
  with Secure Boot on. Azure has it available but disabled; AWS boots legacy
  BIOS; GCE has a vTPM but the brief found no Secure Boot claim.
- /lib/firmware is 227 MB and five firmware-* packages are installed. All three
  clouds have ZERO firmware packages.

## Clean on all three
- kernel taint 0
- systemctl --failed: 0 units; is-system-running: running
- every PCI device with a real function has a driver bound
- ZERO firmware-load attempts, successes or failures in dmesg
- ZERO firmware packages installed (no linux-firmware, no *-microcode)
  -> consistent, not a hidden failure: para-virtual drivers (ena/gve/mana,
     nvme, virtio, pcieport) request no firmware blobs.

## The sharpest divergence: same GPT error, opposite verdicts
AWS   "GPT:16777215 != 41943039", "Alt. header is not at the end of the disk"
      PERSISTS. The 8->20 GiB EBS resize never relocated the backup GPT header.
      AWS instance verdict ranked it action item #1: sudo sgdisk -e /dev/nvme0n1
GCE   Same GPT warning at 1.95s and 2.23s, then SELF-CORRECTED in the same boot
      by Google's `gce-disk-expand`, which resizes the partition and moves the
      backup header. Transient, nothing to fix.
AZURE No GPT error at all.
=> GCP ships a disk-expand agent in the image; AWS does not. A user who grows
   an EBS volume is left with a broken backup GPT table and no warning outside
   dmesg.

## Platform shape
                       AWS              GCE                AZURE
hypervisor             KVM (Nitro)      KVM (Google)       Hyper-V
boot mode              legacy BIOS      -                  Gen2 UEFI
                       (ESP present
                        but unused)
PCI devices            ~45              15                 3
PCI unbound            4 (440FX, PIIX3  3 (440FX, PIIX4    0
                       ISA, PIIX4 ACPI,    ISA, PIIX4 ACPI)
                       Amazon VGA)
                       all legacy stubs all legacy stubs   no legacy chipset
                                                           emulated at all
NIC driver             ena              gve (gVNIC)        mana + hv_netvsc
                                                           (bonded, Accel Net)
storage driver         nvme             nvme               nvme (x2 ctrl)
extra bus              --               --                 VMBus, 13 devices
                                                           all bound
microcode in guest     0x2b000661       0xffffffff         0xffffffff
                       (real value)     (masked)           (masked)

## Instrumentation: what the hypervisor hides
                       AWS              GCE                AZURE
/sys/class/hwmon       absent           absent             absent
/sys/class/powercap    EMPTY but        absent             absent
  (RAPL)               kernel rapl
                       modules LOADED
                       and psys PMU
                       registered
thermal_zone*          none             none (only 2       none (only 2
                                        cooling_device)    cooling_device)
edac                   absent           absent             absent
TPM                    none             /dev/tpm0 +        none
                                        /dev/tpmrm0        (virtualTpmEnabled
                                        (Shielded VM vTPM)  = false per IMDS)

AWS RAPL is the interesting case: the instance reported that intel_rapl_msr /
intel_rapl_common are loaded and KVM registered a psys RAPL PMU domain, but
/sys/class/powercap is empty and the msr module is not loaded -- so power IS
partly exposed and is recoverable with linux-cpupower + modprobe msr. On GCE
and Azure RAPL is not virtualised at all and no tooling can recover it.

## Default tool set (dpkg-verified, sbin-inclusive PATH)
                       AWS   GCE   AZURE
pciutils (lspci)       YES   YES   YES
ethtool                YES   YES   YES
dmidecode              -     YES   -
nvme-cli               -     YES   -
smartmontools          -     -     -
lm-sensors             -     -     -
lshw / hwinfo / lsusb  -     -     -
turbostat / powertop   -     -     -
perf / numactl / hwloc -     -     -
rasdaemon / edac-utils -     -     -
tpm2-tools             -     -     -
GCE ships the most complete base image of the three.
AWS additionally ships amazon-ec2-utils (ec2-metadata, ebsnvme-id) and the aws CLI.

## Platform-specific findings worth acting on
AWS    1. Backup GPT header broken by volume resize -- sgdisk -e. Only real
          defect found on any of the three.
       2. No nvme-cli -> zero SMART/health visibility on the only volume.
       3. No dmidecode/lshw -> no hardware inventory tool at all.
GCE    1. `hwclock` binary absent, so google_guest_agent's clock-skew-setup
          step FAILS EVERY BOOT. Low impact (kvm-clock is authoritative).
       2. vTPM 2.0 present and entirely unmanaged -- no tpm2-tools.
AZURE  1. `Vulnerability Retbleed: Vulnerable` per lscpu -- a real Spectre-class
          exposure tied to the microcode Hyper-V presents. Not fixable in-guest;
          depends on Azure host-side updates. NOT present on AWS or GCE.
       2. Secure Boot disabled and vTPM disabled (IMDS confirms both) -- both
          are available on Azure and were simply not enabled for this VM.
       3. nvme1 "Identify NS List failed (status=0xb)" -- benign; that
          controller fronts an unprovisioned resource disk (IMDS size 0).

## Benign noise common to the fleet
- systemd-ssh-generator AF_VSOCK failures every boot on ALL THREE (no working
  vsock CID in any of these guests). Cosmetic.
- "nvme nvme0: using unchecked data buffer" on AWS and Azure. Cosmetic.
- i8042 "Keylock active" on AWS and GCE (emulated PS/2). Absent on Azure,
  which emulates no PS/2 controller.
- Azure "eth0 speed is unknown, defaulting to 1000" x4 -- synthetic NIC has no
  physical link speed.

## Method note that changed a result
The brief explicitly instructed each instance to probe tools with an sbin-
inclusive PATH and cross-check dpkg, citing that this project had already made
that error once. The Azure instance independently flagged ethtool as "the tool
a bare login-PATH command -v missed earlier in this project". Without that
instruction all three would likely have reported false MISSING entries.

## NOT measured -- do not assert as measured
- No performance claim here; this is a configuration/driver analysis only.
- Retbleed status was read from lscpu's vulnerability line, not independently
  verified with a PoC or against Azure's published guidance.
- AWS RAPL recoverability was NOT tested -- no modprobe msr was attempted and
  no power value was ever read. The instance reported the modules as loaded
  and inferred recoverability; that inference is untested.
- GCE's gce-disk-expand self-correction was inferred from boot timing and the
  agent's presence, not verified by re-reading the backup GPT header after boot.
