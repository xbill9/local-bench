# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`local-bench` compares system performance and Claude Code CLI performance across
the author's own machines (a Debian 13 laptop, one or more ChromeOS Flex /
Crostini boxes). Bash orchestration, awk for all JSON, C/CUDA for the
measurement kernels. There is no package manager, no test framework and no CI.

## Commands

Everything runs through `./bench`; there is no Makefile.

```
./bench build [--force]   # compile src/*.c (and src/gpu_bench.cu if nvcc exists)
./bench run               # ~4 min; writes results/<run_id>.json
./bench list | show | compare <hostA> <hostB> | rank <suite/metric> | matrix
./bench import <path>     # merge a result file from another machine
./bench db                # regenerate results/RESULTS.md from results/*.json
./bench sysdb             # regenerate results/SYSTEMS.md
```

`./bench` with no arguments prints full usage, generated from its own header
comment block.

## Testing

```
./tests/smoke.sh          # ~15s; end-to-end run + assertions
./tests/smoke.sh --keep   # leave the sandbox in place for inspection
```

There is no unit-test framework. `tests/smoke.sh` runs the hardware-independent
suites under `--quick` and asserts each one reported `ok` with all its expected
metrics present and positive, that `lib/fromjson.awk` can still read the
result, and that `db`/`sysdb`/`show` all succeed. Run it after touching a
suite, a kernel, or either awk JSON file.

It runs `./bench` from a **sandbox of symlinks** in `$TMPDIR`, because `LB_ROOT`
is derived from the script's own location and cannot be overridden — a plain
`./bench run` would drop a junk file in `results/` and rewrite `RESULTS.md`.
The test asserts that no such leak happened. Keep any new test on that pattern.

`--quick` numbers are meaningless as measurements; the test only checks shape.
A suite that reports `skip` is counted as skipped, not failed, matching the
project's own skip-vs-fail rule. Adding a metric to a suite means adding it to
the `EXPECTED` table at the top of the test.

## Non-obvious rules

- **Rebuild after touching `src/`.** `./bench run` uses whatever is already in
  `build/`; it does not rebuild. Use `./bench build --force`.
- **`build/` binaries are `-march=native`** (default `LB_CFLAGS='-O2
  -march=native -pipe'`), so they are not portable between machines. Comparing
  two machines fairly means either accepting the divergence (the flags are
  recorded in each result JSON) or forcing a common baseline on both:
  `LB_CFLAGS='-O2 -march=x86-64-v2' ./bench build --force`.
- **Never hand-edit `results/RESULTS.md` or `results/SYSTEMS.md`.** They are
  generated wholesale from `results/*.json`. Change the JSON, then run
  `./bench db` / `./bench sysdb`.
- **Use awk, not `jq`.** All JSON reading and writing goes through
  `lib/*.awk` specifically so the tool has no dependency beyond a POSIX
  userland. Do not introduce `jq`.
- **Indent with tabs** in shell and awk, matching the existing files.
- **ShellCheck is the linter**, invoked as:
  `shellcheck -e SC1091,SC2119 bench lib/*.sh benches/*.sh`
  The whole project is currently clean under that. SC1091 and SC2119 are
  excluded project-wide because both are structural false positives here: every
  suite sources `$LB_ROOT/lib/common.sh`, a path ShellCheck cannot resolve, and
  `lb_cooldown` is deliberately called with no arguments. Anything else gets an
  inline `# shellcheck disable=NNNN` with a comment saying why — never a broader
  exclusion. A `PostToolUse` hook in `.claude/settings.json` runs this on every
  edited shell file.

## Adding a benchmark suite

Drop `benches/NN-name.sh` — the runner discovers it by filename glob, there is
no registration step anywhere. It must `set -uo pipefail`, `source
"$LB_ROOT/lib/common.sh"`, and emit results only through the helpers:

```
lb_metric <suite> <metric> <unit> <higher_is_better:1|0> <sample>...
lb_status <suite> <ok|skip|fail> [note]
lb_info   <key> <value>          # host/system fact
lb_note   <message>              # run-level warning
```

A suite whose tool is missing must `lb_status <suite> skip "..."` and `exit 0` —
absent hardware or an uninstalled dependency is not a failure. See
`benches/50-crypto.sh` for the shape.

## Environment variables

Flags win over env. `LB_REPS` (3), `LB_DURATION` (3s), `LB_COOLDOWN` (1s),
`LB_CFLAGS`, `LB_NET` (0), `LB_CLAUDE` (0), `LB_CLAUDE_MODEL` (haiku),
`LB_DISK_DIR` (`$LB_ROOT/.disktmp`), `LB_DISK_MIB` (512), `CC`.

## Gotchas when interpreting a run

- `--quick` (reps=1, duration=1, cooldown=0) is for checking the tool runs at
  all. Its numbers are not comparable between machines.
- The disk suite writes and deletes a 512 MiB file in `.disktmp/` during a run.
- Thermal throttling and a `powersave` governor are detected and annotated in
  the result, not treated as errors. Existing results show thousands of
  throttle events on the laptop — that is expected, not a bug.
- The GPU suite is NVIDIA/CUDA only and skips cleanly elsewhere. ChromeOS Flex
  never has GPU passthrough, and its disk figures are virtio figures — a
  ceiling, not the hardware's real number.
- The Claude suite runs from an empty temp dir with `--strict-mcp-config` and
  `--no-session-persistence`, so it deliberately does **not** read this
  CLAUDE.md. That is what keeps the measured prompt size stable across machines.
- Results are read from both `results/<run_id>.json` and
  `results/<host>/<ts>.json`; duplicates are deduped by run_id, and `import`
  refuses to overwrite an existing run_id whose content differs.
