---
name: add-suite
description: Scaffold a new local-bench benchmark suite at benches/NN-name.sh following the project's conventions. Use when adding a new measurement to local-bench.
---

Create a new benchmark suite for local-bench.

## Before writing

1. `ls benches/` and pick an unused `NN` prefix. The prefix sets run order —
   cheap/informational suites first, expensive ones later. `00-sysinfo.sh` must
   stay first; anything network- or Claude-facing belongs at the end.
2. Read a nearby suite for the current idiom. `benches/50-crypto.sh` is the
   clearest example of the full shape (dependency check, sampling loop,
   parsing, status).
3. Confirm what the suite measures and its unit, and whether higher is better.

There is **no registration step** — the runner discovers `benches/*.sh` by
glob. Do not add the file to a list anywhere.

## Required shape

```bash
#!/usr/bin/env bash
# One-line summary of what this measures.
#
# A short paragraph on why the number matters and what a bad value indicates.
set -uo pipefail
source "$LB_ROOT/lib/common.sh"

if ! lb_have <tool>; then
	lb_status <suite> skip "<tool> not installed"
	exit 0
fi

samples=()
for _ in $(seq 1 "$LB_REPS"); do
	v=$(measure_once) || continue
	samples+=("$v")
	lb_cooldown
done

if [ ${#samples[@]} -gt 0 ]; then
	lb_metric <suite> <metric> <unit> <1|0> "${samples[@]}"
	lb_status <suite> ok
else
	lb_status <suite> fail "could not parse <tool> output"
fi
```

## Rules

- Emit results **only** through `lb_metric` / `lb_status` / `lb_info` /
  `lb_note`. Never write to `$LB_OUT` directly.
- Every suite must end with exactly one `lb_status` call on every path.
- Missing hardware or an uninstalled dependency is `skip` + `exit 0`, never
  `fail` and never a non-zero exit. `fail` means the tool was present but the
  measurement or its parsing broke.
- Honour `LB_REPS`, `LB_DURATION` and `lb_cooldown`. A suite that ignores
  `LB_DURATION` breaks `--quick` and makes run times unpredictable — see the
  `-bytes` comment in `50-crypto.sh` for how easily this goes wrong.
- Parse with awk, not `jq`. The project has no non-POSIX dependencies.
- Indent with tabs.
- `chmod +x` the new file.

## After writing

- Run `shellcheck -e SC1091,SC2119 benches/NN-name.sh` and fix what it reports.
  (A `PostToolUse` hook already does this on every edit.)
- Try the suite alone: `./bench run --quick --only <suite>`, then `./bench show`
  to confirm the metrics landed.
- **Add the suite and its metrics to the `EXPECTED` table in `tests/smoke.sh`**
  — but only if it needs no special hardware, no network and no money. A suite
  whose correct behaviour on this machine is to skip belongs outside that table.
- Run `./tests/smoke.sh` and confirm it still passes.
