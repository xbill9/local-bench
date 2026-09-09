# Debian 13 across local, AWS, GCE and Azure

Working data for a write-up comparing a baseline Debian 13 install on four
platforms, focused on two questions:

1. What does the stock image ship, and what does it fail to ship relative to
   the hardware it is running on?
2. What does it take to get Claude Code running, and what does Claude find
   when it analyses the machine it is running on?

Captured 2026-09-09. Nothing here is a published article yet.

## Platforms

| | Image | Shape | CPU |
|---|---|---|---|
| local | Debian 13, bare metal | Lenovo 83B1 | i7-1360P (Raptor Lake) |
| AWS | ami-0871da4641e8b4413 (2026-08-31, build 2587) | c7i.large | Xeon 8488C (Sapphire Rapids) |
| GCE | debian-13-trixie-v20260908 | c4-standard-2 | Xeon 8581C (Emerald Rapids) |
| Azure | Debian:debian-13:13-gen2:0.20260831.2587 | Standard_D2s_v7 | Xeon 6973P-C (Granite Rapids) |

AWS and Azure ship the same upstream Debian build (2587). GCE builds its own.

## evidence/

| File | What it is |
|---|---|
| `ROLLUP-DEBIAN-ACROSS-CLOUDS.md` | The four-way summary. Start here. |
| `METHOD.md` | Default-install gap analysis, package matrix, contamination note |
| `BENCH-AND-PRICING.md` | Benchmarks at build parity + on-demand and spot pricing |
| `hw-analysis-evidence.md` | Laptop vs AWS deep hardware comparison |
| `deep-analysis-prompt.txt` | The brief each machine was given |
| `deep-{local,aws,gce,azure}.txt` | Each machine's analysis OF ITSELF |
| `scan-{local-debian,aws,gce,azure}.txt` | Pristine baseline scans, pre-install |
| `claude-install-{aws,gce,azure}.txt` | Claude Code install transcripts |
| `baseline-scan.sh` | The dependency-free pristine scanner |

## Method

Baseline scans ran on pristine images before anything was installed. The
deep analyses ran with Claude Code installed and authenticated ON each machine,
each instance examining itself via `claude -p "<brief>" --allowedTools Bash`.

Benchmarks were built `-O2 -march=x86-64-v2` on all four and asserted as such
before comparison. This matters: the same AWS host scored float 3.249e+09
under `-march=native` and 1.838e+09 at x86-64-v2, because native lets GCC use
AVX-512 the laptop's Raptor Lake does not have.

## Reading these honestly

Every evidence file ends with a "NOT measured" section. Those are load-bearing.
The cloud benchmarks are n=1 on a single day. Four claims are inferences rather
than measurements and are marked as such. Pricing is compute-only.

The local run had a disclosed side effect (an initramfs rebuild) — see the
rollup. The brief did not say read-only; it should have.
