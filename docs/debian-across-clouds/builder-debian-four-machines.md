# Four Debian 13 Boxes, One Brief: 1,923 Packages on Metal, 328 in the Cloud, and the Backup GPT Header Nobody Relocated

*Subtitle: What the default cloud image cannot see about the hardware underneath it*

This article covers one afternoon of running the same Debian 13 on four machines — one laptop and three clouds — and asking each of them the same question about its own hardware.

**A cloud image is not a small Debian. It is a different bet about what you will need.** The laptop install carries 1,923 packages. The three cloud images carry 328, 337 and 350. That is not a rounding difference, and the interesting part is not the count — it is that all four are booting from NVMe, and only two of them ship anything that can read an NVMe health log.

What that creates is a gap with two halves. The hardware is present and the kernel can see it. The default toolset cannot. And because nothing fails, nothing tells you:

- Every cloud image ships **zero firmware packages** and logs **zero firmware load attempts** — consistent, not broken, and you have to check to know which.
- **AWS and Azure ship no `nvme-cli`**, on machines whose only disk is NVMe.
- **GCE alone** ships `dmidecode` and `nvme-cli`. It is the most complete of the three by a clear margin.
- Azure reports **`Vulnerability Retbleed: Vulnerable`**. AWS and GCE do not.
- AWS carries a **backup GPT header its own volume resize never relocated** — `GPT:16777215 != 41943039`, still wrong at the boot I measured. GCE emits the identical warning and **fixes it in the same boot**.

That last pair is the whole article. Same kernel, same message, opposite correct answers.

https://github.com/xbill9/local-bench

## The Machines

Four hosts, all Debian 13 (trixie), all measured on 2026-09-09:

| | Image | Shape | CPU | Kernel |
|---|---|---|---|---|
| **local** | installed, bare metal | Lenovo 83B1 | i7-1360P, Raptor Lake, 16 threads | `7.1.8+deb13-amd64` (backports) |
| **AWS** | `ami-0871da4641e8b4413` | c7i.large | Xeon 8488C, Sapphire Rapids, 2 vCPU | `6.12.107+deb13-cloud-amd64` |
| **GCE** | `debian-13-trixie-v20260908` | c4-standard-2 | Xeon 8581C, Emerald Rapids, 2 vCPU | `6.12.107+deb13-cloud-amd64` |
| **Azure** | `Debian:debian-13:13-gen2:0.20260831.2587` | `Standard_D2s_v7` | Xeon 6973P-C, Granite Rapids, 2 vCPU | `6.12.107+deb13-cloud-amd64` |

One detail decides how to read everything below. **The AWS and Azure images are the same upstream Debian build** — `2587`, dated 2026-08-31 — running the same kernel. GCE builds its own, a week newer. So where AWS and Azure differ, the distro is not the variable. The platform is.

## At This Point You Should Have

- An account on whichever clouds you want to compare, and the CLI for each already authenticated
- The ability to launch a VM and throw it away
- `ssh`, and a key you are willing to put on a throwaway host
- Somewhere durable to write findings that is not your shell scrollback

Steps 0 through 2 are reads and launches. Step 3 installs software, and **Step 3 is the point of no return for the baseline** — see Step 1 for why that ordering is not optional.

## Step 0 — Pin the Image, Not the Family

An image family is a moving target, and "Debian 13" is not a measurement. Resolve it to an ID before you launch anything, and write the ID down.

```bash
# AWS — the official Debian account is 136693071363
aws ec2 describe-images --owners 136693071363 \
  --filters "Name=name,Values=debian-13-amd64-*" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].{Name:Name,ID:ImageId,Date:CreationDate}'

# GCE — resolve the family to the image it currently points at
gcloud compute images describe-from-family debian-13 \
  --project debian-cloud --format="value(name)"

# Azure — the stable offer is debian-13; debian-13-daily is a different thing
az vm image list --publisher Debian --offer debian-13 --sku 13-gen2 --all \
  --query "[?offer=='debian-13'] | sort_by(@,&version)[-1].urn" -o tsv
```

That third one has a trap in it. Asking Azure for `--offer debian-13` with `--all` will happily return `debian-13-daily` URNs alongside the stable ones, because the filter matches loosely. The `[?offer=='debian-13']` clause is doing real work — without it you will pin a daily build and not notice.

This is also where the AWS/Azure coincidence shows up: both resolved to build `2587`, dated 2026-08-31. That is not a fluke, it is the same upstream Debian cloud image, and it is the single most useful fact for interpreting the rest.

## Step 1 — Scan Before You Install Anything

**This step exists because I got it wrong the first time.**

The first EC2 instance I launched had a `user-data` script that installed about twenty packages before I ever logged in. Then I scanned it and wrote down what was present. Every one of those findings was worthless: I was measuring my own cloud-init, not Debian's image. That instance had to be discarded and relaunched with no `user-data` at all.

A default-install analysis has exactly one chance to be correct, and it is before the first `apt-get install`.

The scanner has to run on a machine where nothing is installed, which means it can only use what a minimal cloud image actually ships — bash, coreutils, `/proc`, `/sys`, `dpkg`. No `jq`. No `lspci`, because `pciutils` might not be there. Absence is the data, so nothing may fail:

```bash
# hardware, without needing dmidecode
for f in sys_vendor product_name bios_version bios_date; do
  [ -r "/sys/class/dmi/id/$f" ] && printf '%-16s %s\n' "$f" "$(cat /sys/class/dmi/id/$f)"
done

# what the image actually ships, by dpkg, not by PATH
for p in pciutils usbutils dmidecode nvme-cli smartmontools lm-sensors \
         ethtool intel-microcode fwupd build-essential gcc git unzip; do
  s=$(dpkg-query -f '${db:Status-Status}' -W "$p" 2>/dev/null)
  [ "$s" = installed ] && echo "PRESENT $p" || echo "absent  $p"
done
```

**Check packages with `dpkg`, not with `command -v`.** This is the second thing I got wrong, and it is worth more than the first. My initial pass over the laptop reported `dmidecode`, `nvme-cli`, `smartmontools`, `hdparm`, `ethtool`, `powertop` and `turbostat` as missing. All seven were installed. My login `PATH` contained no `/usr/sbin`, no `/sbin`, no `/usr/local/sbin`, and a bare `command -v` cannot see a binary it has no path to. Seven false negatives from one unstated assumption, on the machine I know best.

The full scanner is `evidence/baseline-scan.sh` in the repo. Run it, keep the output, then install things.

## Step 2 — Launch Pristine

No `user-data`, no startup script, no custom image. Lock SSH to your own address rather than the world — every one of these CLIs will happily open port 22 to `0.0.0.0/0` if you let it.

```bash
MYIP=$(curl -s https://checkip.amazonaws.com)/32

# AWS
aws ec2 run-instances --image-id <ami> --instance-type c7i.large \
  --key-name <key> --security-group-ids <sg> --subnet-id <subnet> \
  --associate-public-ip-address --metadata-options 'HttpTokens=required'

# GCE
gcloud compute instances create baseline --zone=us-east1-b \
  --machine-type=c4-standard-2 --image-family=debian-13 --image-project=debian-cloud

# Azure — --nsg-rule SSH opens 22 to the internet; narrow it afterwards
az vm create -g <rg> -n baseline --image <urn> --size Standard_D2s_v7 \
  --admin-username azureuser --ssh-key-values ~/.ssh/id_ed25519.pub --nsg-rule SSH
az network nsg rule update -g <rg> --nsg-name baselineNSG --name default-allow-ssh \
  --source-address-prefixes "$MYIP"
```

Azure will also refuse a size that is not offered to your subscription in that region, and the CLI reports it badly — mine crashed inside its own error handler with `RuntimeError: The content for this response was already consumed`, having created nothing. The real cause was that `Standard_D2s_v6` does not exist for that subscription in `eastus`. Ask before you launch:

```bash
az vm list-skus -l eastus --size Standard_D2s_v7 \
  --query "[].{Name:name,Restrictions:restrictions[].reasonCode}" -o json
```

An empty array means the SKU is not available to you. That is the answer the failed deployment was trying to give.

## Step 3 — Install Claude Code, and Notice What It Does Not Need

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

On all three clouds, on images with **no `node`, no `npm`, no `unzip` and no compiler**:

| | AWS | GCE | Azure |
|---|---|---|---|
| Elapsed | 10 s | **8 s** | 12 s |
| Version | 2.1.266 | 2.1.266 | 2.1.266 |
| Installed size | 206 MB | 206 MB | 206 MB |

`ldd` on the binary returns `linux-vdso`, `librt`, `libc`, `libpthread`, `libdl`, `ld-linux` — glibc 2.41 and nothing else. The prerequisites are `curl` and a writable `$HOME`, and every one of these images has both.

All three printed the same warning: `~/.local/bin is not in your PATH`. Debian's `~/.profile` adds that directory only if it exists **at login**, and the installer creates it mid-session. Three for three, and it resolves itself on the next login.

## Step 4 — Give Each Machine the Same Brief

This is the part that changes the result. Rather than SSH-ing in and running commands from outside, install Claude Code on each box and have it examine the machine it is running on:

```bash
claude -p "$(cat brief.txt)" --allowedTools Bash
```

`--allowedTools Bash` pre-approves the one tool the job needs. The blunter `--permission-mode bypassPermissions` disables the permission system wholesale and is the wrong instrument here.

The brief asks for seven things in order — identity, drivers, firmware, kernel errors, failed units, system tools, gaps — and ends by asking for a verdict of at most eight lines. The full text is `evidence/deep-analysis-prompt.txt`.

One clause in it earned its place:

> IMPORTANT: check with an explicit PATH that includes /usr/sbin, /sbin and
> /usr/local/sbin, and cross-check against dpkg — a tool in /usr/sbin is NOT
> missing just because a bare `command -v` under a login PATH cannot see it.
> This exact mistake has already been made once in this project.

Without it, four machines would have independently reproduced my Step 1 error. With it, the Azure instance flagged `ethtool` as "the tool a bare login-PATH `command -v` missed earlier in this project" — it had read the warning and applied it.

**One caveat, and it is mine.** The brief says "use your Bash tool" and never says read-only. The laptop's instance ran `update-initramfs -u` during its analysis, rebuilt the boot image, and said so at the top of its report. The result was benign — it incidentally shipped the `rtl8156b-2.fw` blob that had been missing from that initrd — and the three cloud instances wrote nothing. But that was the brief's luck, not its design. **If you reuse this, say read-only.**

## What the Default Image Ships

`dpkg`-verified, on pristine images, before anything was installed:

| Package | local | AWS | GCE | Azure |
|---|---|---|---|---|
| `pciutils` | YES | YES | YES | YES |
| `ethtool` | YES | YES | YES | YES |
| `curl` / `wget` / `python3` | YES | YES | YES | YES |
| `dmidecode` | YES | — | **YES** | — |
| `nvme-cli` | YES | — | **YES** | — |
| `smartmontools` | YES | — | — | — |
| `lm-sensors` | YES | — | — | — |
| `lshw` / `usbutils` | YES | — | — | — |
| `linux-cpupower` / `powertop` | YES | — | — | — |
| `intel-microcode` / `fwupd` | YES | — | — | — |
| `build-essential` / `gcc` / `git` | YES | — | — | — |
| `numactl` / `hwloc` / `gawk` | — | — | — | — |
| **Total installed** | **1,923** | **337** | **350** | **328** |

Five packages are universal. Everything else is a choice, and **GCE makes the most generous one** — it is the only image of the three that can inspect its own disk or decode its own SMBIOS out of the box.

## What the Hypervisor Takes Away

The gap has a second half that no package closes. Some facilities are absent because the hypervisor does not expose them, and installing the tool achieves nothing:

| | local | AWS | GCE | Azure |
|---|---|---|---|---|
| `/sys/class/hwmon` | present | **absent** | **absent** | **absent** |
| `thermal_zone*` | 10 | none | none | none |
| `/sys/class/powercap` (RAPL) | present | **empty, modules loaded** | absent | absent |
| `thermal_throttle` counters | present | absent | absent | absent |
| EDAC | present | absent | absent | absent |
| TPM | present | none | **vTPM present** | disabled by config |
| microcode revision | `0x6134` | `0x2b000661` | **`0xffffffff`** | **`0xffffffff`** |

Two of these repay a second look.

**AWS's RAPL is not simply missing.** The instance found `intel_rapl_msr` and `intel_rapl_common` loaded and a `psys` PMU domain registered — KVM is exposing the MSRs — but `/sys/class/powercap` is empty because the `msr` module is not loaded and no reader is installed. On AWS, power is recoverable with `linux-cpupower` and a `modprobe`. On GCE and Azure, RAPL is not virtualised at all, and no tooling will bring it back. Those two states look identical from a distance and are not the same problem.

**GCE and Azure mask the microcode revision** to `0xffffffff`. AWS reports a real one. If your compliance story involves auditing microcode level in-guest, it works on one of these three.

## The GPT Header, and Why Only the Machine Could Tell

AWS and GCE both emit this during boot:

```
GPT:16777215 != 41943039
GPT: Use GNU Parted to correct GPT errors.
```

16,777,215 sectors is 8 GiB. 41,943,039 is 20 GiB. Both disks were created at 8 GiB and requested at 20; the primary GPT was updated and the backup header at the end of the disk was not moved to match. The kernel falls back to the primary and boots.

On AWS it is **still wrong**. The instance ranked it as action item #1 and gave the fix:

```bash
sudo sgdisk -e /dev/nvme0n1
```

On GCE the same warning appears at t=1.95s and t=2.23s and is then **corrected inside the same boot**, because Google ships `gce-disk-expand` in the image and AWS ships nothing equivalent. Azure never emits it at all.

Same kernel. Same message. On one machine it is a defect you must fix; on another it is a transient you must ignore. Nothing in the message says which, and no amount of reading the message from outside the machine would tell you — you need the boot timeline, the package list and the agent's behaviour together.

## Three Findings You Only Get From the Inside

**Azure is exposed to Retbleed.** `lscpu` reports `Vulnerability Retbleed: Vulnerable`, tied to the microcode Hyper-V presents to the guest. AWS and GCE report no such thing. There is no in-guest fix; it depends on Azure host-side updates. Azure also has Secure Boot **and** vTPM available and **both disabled** on a default VM.

**GCE fails a boot step every time.** The `hwclock` binary is absent, so `google_guest_agent`'s clock-skew-setup step fails on every boot. Impact is near zero — `kvm-clock` is authoritative — but it is a permanent error in a log nobody reads.

**Azure has zero unbound PCI devices.** It presents three PCI devices, all bound, plus thirteen VMBus devices, all bound. AWS presents about 45 with four unbound legacy stubs (440FX, PIIX3 ISA, PIIX4 ACPI, an emulated VGA); GCE presents 15 with three. Hyper-V Gen2 emulates no legacy chipset at all, and AWS still boots **legacy BIOS** with an unused EFI System Partition mounted at `/boot/efi`.

## Where They're Alike

Worth stating plainly, because it is the larger part of the result. On all four machines: **kernel taint 0**, **zero failed systemd units**, `is-system-running: running`, and every PCI device with a real function had its driver bound. On all three clouds: **zero firmware-load attempts and zero firmware packages** — which is consistent rather than broken, because `ena`, `gve`, `mana`, `nvme` and `virtio` request no blobs.

The shared noise is shared exactly: `systemd-ssh-generator` fails its `AF_VSOCK` probe every boot on all three clouds, none of which expose a working vsock CID.

## Cheat Sheet

```bash
# 0. pin the image to an ID, never a family
aws ec2 describe-images --owners 136693071363 --filters "Name=name,Values=debian-13-amd64-*" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId'
gcloud compute images describe-from-family debian-13 --project debian-cloud --format="value(name)"
az vm image list --publisher Debian --offer debian-13 --sku 13-gen2 --all \
  --query "[?offer=='debian-13'] | sort_by(@,&version)[-1].urn" -o tsv

# 1. confirm the SKU is actually offered to you before launching
az vm list-skus -l eastus --size Standard_D2s_v7 --query "[].name" -o tsv

# 2. scan BEFORE installing anything -- packages by dpkg, never by command -v
dpkg-query -f '${db:Status-Status}\n' -W nvme-cli dmidecode smartmontools
dpkg-query -f '.\n' -W | wc -l

# 3. tools by an sbin-inclusive PATH, or you will invent false negatives
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin command -v nvme smartctl turbostat

# 4. is the facility absent, or just unreadable? absent = no package will help
ls /sys/class/hwmon /sys/class/powercap /sys/devices/system/edac 2>&1
lsmod | grep -c rapl        # loaded modules + empty powercap = recoverable
grep -m1 microcode /proc/cpuinfo   # 0xffffffff = hypervisor is masking it

# 5. the backup GPT header, on any volume you have ever grown
sudo dmesg | grep -i 'GPT:'
sudo sgdisk -e /dev/nvme0n1        # only if the mismatch persists after boot

# 6. install Claude Code and let the machine read itself
curl -fsSL https://claude.ai/install.sh | bash
claude -p "$(cat brief.txt)" --allowedTools Bash
```

## Summary

The goal was to find out what a stock Debian 13 cloud image knows about the hardware underneath it. The answer is: less than the hardware is willing to say, and the shortfall is different on every platform, in ways that a package list alone does not predict.

The key to getting a usable answer was giving each machine the same brief and letting it read its own boot log, because the two most interesting findings — a broken partition table on one cloud and a self-correcting one on another — are the same kernel message, and only the machine can tell you which one it is looking at.

The method's own two mistakes are in the article on purpose. Both were unstated assumptions, both produced confident wrong answers, and one of them was on the machine I know best.

---

**Repo:** [github.com/xbill9/local-bench](https://github.com/xbill9/local-bench) — `docs/debian-across-clouds/` carries the four self-analyses, the pristine baseline scans, the brief, and the benchmark and pricing data. Every evidence file ends with a "NOT measured" section listing which claims are inferences rather than measurements.
