# local-bench

Compare **system** and **Claude Code** performance across your own machines --
here, a Debian 13 laptop and one or more ChromeOS Flex boxes.

Results are self-contained JSON, one file per run, plus a single markdown file
(`results/RESULTS.md`) that acts as the database: readable in any editor,
greppable, diffable, and regenerated from the JSON so it can never drift.

## Quick start

```sh
./bench build                 # compile the measurement kernels for THIS cpu
./bench run                   # ~4 minutes; writes results/<run_id>.json
./bench run --claude --net    # also measure Claude and external network
./bench list                  # what has been recorded
./bench compare yoga9i flex   # diff two machines by hostname
```

A **ref** in `show`/`compare` is a run_id, a hostname (meaning its newest run),
`latest`, or a path to a JSON file.

## Comparing two machines

Runs are portable: measure on each box, then bring the JSON together.

```sh
# on the ChromeOS Flex machine
./bench run --claude --tag flex-baseline

# copy its result anywhere the other machine can read, then
./bench import /path/to/20260904T141046Z-flexbox.json
./bench compare yoga9i flexbox
```

`import` refuses to silently overwrite an existing run_id with different
content, so pulling in the same file twice is safe.

`compare` is direction-aware: it knows latency should go down and throughput
should go up, so a green figure always means "better" regardless of the metric.
Differences under 1% are treated as noise and not scored.

## Running on ChromeOS Flex

ChromeOS Flex needs the Linux development environment (Crostini):
**Settings -> Advanced -> Developers -> Linux development environment**. Then,
inside the Linux terminal:

```sh
sudo apt update && sudo apt install -y build-essential openssl
./bench build && ./bench run
```

Read Flex numbers with its architecture in mind, and the tool records the facts
you need to do that:

- Everything runs inside a **VM container**, not on the metal. `00-sysinfo`
  detects this and records `platform=crostini`, and the Hosts table shows it.
- **Disk figures are virtio figures.** They describe the container's storage
  path, not the SSD. Treat them as a ceiling for what Linux apps will see, not
  as a measurement of the drive.
- **No GPU passthrough**, so the `gpu` suite skips. That is a correct result,
  not a failure.
- CPU and memory numbers are close to native and are the fair comparison.

## What is measured

| suite | measures | notes |
|---|---|---|
| `sysinfo` | host fingerprint | no timings; decides whether two runs are comparable at all |
| `cpu-single` | integer / float / sieve throughput | three workload shapes: ALU latency, FPU throughput, branchy cache-resident work |
| `cpu-multi` | 1-thread vs all-thread, scaling efficiency | efficiency well under 100% is normal with SMT or a thermal cap |
| `memory` | read / write / copy / triad bandwidth, latency | buffers sized past any LLC, so these are DRAM numbers |
| `disk` | sequential read/write, fsync latency | uses `O_DIRECT` when the filesystem allows; falls back and says so |
| `crypto` | SHA-256, AES-256-CBC | mostly a check that AES-NI and SHA extensions are present and exposed |
| `gpu` | H2D / D2H / D2D bandwidth, FP32, clock, power, temp | NVIDIA + CUDA only; skips cleanly everywhere else |
| `network` | loopback pipe throughput | DNS, ping and HTTPS are opt-in behind `--net` |
| `claude` | Claude Code performance | opt-in behind `--claude`; **spends your Claude quota** |

### The `claude` suite

It separates what your **host** controls from what the **network and service**
control, which is the only way the Debian-vs-Flex question means anything:

| metric | dominated by |
|---|---|
| `cli_startup` | the host -- binary load, disk, CPU |
| `time_to_request` | the host -- CLI work before the request leaves |
| `ttft` | network + service |
| `output_tok_per_sec` | the service (measured over the streaming window only) |
| `total_roundtrip` | what you actually wait |

So if Flex feels slower, a gap in the first two rows is a machine problem and a
gap in `ttft` is a network problem.

Each query runs from an empty temp directory with `--strict-mcp-config`, so a
project's `CLAUDE.md` and MCP servers cannot change the prompt size between
machines. Cost is recorded per run (`claude_cost_usd`) and shown in the suite
note. Default model is `haiku`; override with `--claude-model`.

## Getting numbers worth trusting

- **Defaults over `--quick`.** `--quick` is one 1-second sample -- fine for
  checking the tool works, useless for comparing machines. The defaults take 3
  samples of 3 seconds and report the spread between them.
- **Watch `spread%`.** Above roughly 10%, the machine was too noisy and the
  number should not be compared. It is in the terminal output and in the DB.
- **Thermal throttling is detected and reported** as a run warning. A laptop
  that throttled produced a floor, not a measurement -- let it cool, or compare
  only against other throttled runs.
- **Use `--tag`** to record the condition: `--tag battery` vs `--tag plugged-in`
  on the same laptop is often a bigger difference than between two machines.
- **Kernels are built with `-march=native`** so each box is measured at its real
  capability. That means the binary genuinely differs between machines; the
  compiler and flags are recorded in every result so the comparison is honest
  rather than hidden. Set `LB_CFLAGS` to force a common baseline if you would
  rather compare like for like:
  `LB_CFLAGS='-O2 -march=x86-64-v2' ./bench build --force`

## Layout

```
bench                 the runner: build, run, list, show, compare, import, db
benches/*.sh          one file per suite; drop a new one in and it is picked up
lib/common.sh         helpers every suite uses (metrics, thermal, medians)
lib/tojson.awk        records -> result JSON
lib/fromjson.awk      result JSON -> records (no jq dependency)
lib/mkdb.awk          records -> results/RESULTS.md
src/*.c, src/*.cu     the measurement kernels
results/              one JSON per run, plus RESULTS.md
```

### Adding a suite

Create `benches/90-yours.sh`, source `lib/common.sh`, and emit measurements
with `lb_metric <suite> <metric> <unit> <higher_is_better:1|0> <sample>...`
followed by `lb_status <suite> ok|skip|fail [note]`. The runner discovers it,
the JSON, the markdown DB and `compare` all pick it up with no other changes.
Skip rather than fail when a dependency is missing -- a machine that lacks a
GPU has produced a valid result, not a broken one.

## Environment variables

`LB_REPS`, `LB_DURATION`, `LB_COOLDOWN`, `LB_CFLAGS`, `LB_NET`, `LB_CLAUDE`,
`LB_CLAUDE_MODEL`, `LB_DISK_DIR`, `LB_DISK_MIB`, `CC`. Flags win over the
environment.
