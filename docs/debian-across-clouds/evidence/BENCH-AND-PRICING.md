# Baseline benchmark + pricing evidence
Captured 2026-09-09. Companion to METHOD.md (default-install gap analysis).

## Build parity
All four runs built with compile_flags "-O2 -march=x86-64-v2", asserted
programmatically against each result JSON before the table below was produced.
This is the CLAUDE.md common-baseline rule. It matters: on AWS the same host
scored float 3.249e+09 under -march=native and 1.838e+09 under x86-64-v2,
a 43% drop, because native lets GCC use AVX-512 that the laptop's Raptor Lake
does not have at all. Native numbers are NOT cross-comparable.

## Run ids
LOCAL 20260909T182944Z-debian
AWS   20260909T181947Z-ip-172-31-6-191   (pristine instance i-07a6b25fe56ccca05)
GCE   20260909T182643Z-baseline-pristine-gce
AZURE 20260909T182313Z-baseline-pristine-azure

## Hosts
LOCAL  i7-1360P Raptor Lake      16 threads  15731 MiB  bare metal
AWS    Xeon Platinum 8488C SPR    2 threads   3826 MiB  c7i.large
GCE    Xeon Platinum 8581C EMR    2 threads   6936 MiB  c4-standard-2
AZURE  Xeon 6973P-C Granite Rap.  2 threads   7942 MiB  Standard_D2s_v7

## Measured medians (n=3 reps each)
METRIC                           LOCAL         AWS         GCE       AZURE  unit
cpu-single/int               5.507e+08   3.622e+08   4.433e+08   4.647e+08  ops/s
cpu-single/float              2.79e+09   1.838e+09   2.249e+09    2.72e+09  ops/s
cpu-single/sieve             6.304e+08   3.585e+08   4.921e+08   4.249e+08  ops/s
cpu-multi/threads_1            5.5e+08   3.622e+08   4.436e+08   4.644e+08  ops/s
cpu-multi/threads_all        6.386e+09   7.023e+08   8.606e+08   8.895e+08  ops/s
cpu-multi/scaling_efficiency     72.57       96.95       97.00       95.77  %
memory/read                      16.43       7.842       7.149       16.03  GiB/s
memory/write                     14.23       11.59        6.85       8.313  GiB/s
memory/copy                      41.99       19.64       26.32       26.11  GiB/s
memory/triad                     22.11       11.64        12.4       17.38  GiB/s
memory/latency                    98.9       130.3       81.83       136.4  ns
disk/seq_write                    3300         173         191         192  MB/s
disk/seq_read                     5400         131         178         207  MB/s
disk/fsync_latency              0.5268       3.225       1.489       3.256  ms
crypto/sha256                     2388        1568        1921        2014  MB/s
crypto/aes_256_cbc                1764        1159        1416        1487  MB/s

NOTE on threads_all: 16 threads vs 2. It is a machine-level fact, not a
per-core comparison. scaling_efficiency ~96-97% on all three clouds is
across 2 SMT siblings of ONE physical core; the laptop's 72.57% is across
16 threads on 12 real cores. The cloud figure is not "better scaling".

## Pricing -- retrieved from vendor APIs 2026-09-09, us-east region, Linux, on-demand
AWS   c7i.large          $0.089250 /hr   AWS Pricing API get-products
                         (API also reports "Intel Xeon Scalable (Sapphire
                         Rapids)", clockSpeed 3.2 GHz -- matches the 3271 MHz
                         measured under load in hw-analysis-evidence.md)
AZURE Standard_D2s_v7    $0.132000 /hr   prices.azure.com retail API
AZURE Standard_D2s_v7    $0.024394 /hr   same API, Spot
GCE   C4 Instance Core   $0.034650 /vCPU/hr  Cloud Billing Catalog API
GCE   C4 Instance Ram    $0.003938 /GiB/hr   service 6F81-5844-456A, us-east1

GCE quotes COMPONENTS, not a flat instance rate. c4-standard-2 total is
DERIVED ARITHMETIC, not a quoted price:
  2 vCPU x $0.034650 = $0.069300
  7 GiB  x $0.003938 = $0.027566
  total              = $0.096866 /hr

## Price/performance -- DERIVED ARITHMETIC from the two blocks above
CLOUD       USD/hr    int ops/s   int per $/hr   float per $/hr
AWS       0.089250    3.622e+08      4.058e+09        2.059e+10
GCE       0.096866    4.433e+08      4.576e+09        2.322e+10
AZURE     0.132000    4.647e+08      3.520e+09        2.061e+10
GCE leads on both int and float per dollar.
Azure is the fastest cloud in absolute terms and the worst per dollar.
AWS is the cheapest per hour and the slowest cloud on every CPU metric here.

## Spot / preemptible pricing -- retrieved from vendor APIs 2026-09-09
AWS   c7i.large spot, Linux/UNIX, us-east-1, describe-spot-price-history,
      most recent quote per AZ (this is a MARKET price that moves):
        us-east-1a  $0.031700   2026-09-09T15:00:00Z  <- AZ our instance runs in
        us-east-1b  $0.030700   2026-09-09T15:00:00Z
        us-east-1c  $0.032800   2026-09-09T15:00:00Z
        us-east-1d  $0.033400   2026-09-09T12:00:00Z
        us-east-1f  $0.028900   2026-09-09T10:00:00Z
      Range across AZs at capture time: $0.028900 - $0.033400.
      Figures below use us-east-1a ($0.031700) for consistency with the
      instance actually benchmarked.

AZURE Standard_D2s_v7 Spot  $0.024394 /hr   prices.azure.com retail API

GCE   Spot Preemptible C4 Instance Core  $0.019750 /vCPU/hr
      Spot Preemptible C4 Instance Ram   $0.002245 /GiB/hr
      Cloud Billing Catalog API, service 6F81-5844-456A, us-east1
      c4-standard-2 spot total is DERIVED ARITHMETIC, not a quoted price:
        2 vCPU x $0.019750 = $0.039500
        7 GiB  x $0.002245 = $0.015715
        total              = $0.055215 /hr

## On-demand vs spot, and the discount each vendor is actually giving
CLOUD     ondemand       spot   discount
AWS       0.089250   0.031700      64.5%
GCE       0.096866   0.055215      43.0%
AZURE     0.132000   0.024394      81.5%

Azure is the MOST expensive on demand and the CHEAPEST on spot. Its 81.5%
spot discount is nearly double GCE's 43.0%. The on-demand ranking inverts
completely at spot.

## Price/performance on SPOT -- DERIVED ARITHMETIC
CLOUD       USD/hr   int per $/hr   float per $/hr
AWS       0.031700      1.143e+10        5.798e+10
GCE       0.055215      8.029e+09        4.073e+10
AZURE     0.024394      1.905e+10        1.115e+11

On spot, Azure leads BOTH metrics, and by a wide margin -- 2.4x GCE on int.
Compare the on-demand table above, where GCE led both and Azure was last.
GCE is the only cloud that is worst-in-class on spot per dollar despite
leading on demand.

## Additional NOT-measured caveats for the spot figures
- AWS spot is a live market price. The quotes above are a single capture at
  2026-09-09 and will differ on any other day, in any other AZ or region.
  Do not present them as a rate card.
- Spot/preemptible capacity can be reclaimed at any time. No interruption
  rate, eviction rate or availability figure was measured here.
- GCE Spot pricing is a published discounted rate rather than a live market,
  and Azure spot varies by region and demand; the three numbers are therefore
  NOT the same kind of quantity even though they are compared side by side.
  Say so if these appear in an article.
- All spot figures are COMPUTE ONLY, same as the on-demand block.

## NOT measured -- do not assert as measured
- Storage cost. The quoted rates are COMPUTE ONLY. The three hosts also had
  different disks (AWS 20GB gp3, GCE 20GB hyperdisk-balanced, Azure 30GB
  Premium_LRS) which are billed separately and were NOT priced.
- Network egress, IP address, or any other line item.
- Sustained-use discounts (GCP applies these automatically and they are NOT
  reflected in the catalog rate above), reservations, savings plans.
- Whether the four regions are truly equivalent (us-east-1 / us-east1 /
  eastus are different physical places).
- Laptop 5.0 GHz peak boost -- lscpu spec value, never observed.
