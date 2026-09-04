#!/usr/bin/env bash
# Smoke test: run the tool end-to-end and assert the result document has the
# shape the reporting code expects.
#
# This is not a benchmark. --quick numbers are meaningless for comparing
# machines; the point is to catch a suite that stopped emitting a metric, a
# kernel that no longer builds, or a change to the JSON layout that
# lib/fromjson.awk can no longer read.
#
# The run happens in a sandbox directory of symlinks so that LB_ROOT -- which
# ./bench derives from its own location and does not let you override -- points
# somewhere disposable. Without that, every test run would drop a junk file in
# results/ and rewrite RESULTS.md.
#
# Usage: ./tests/smoke.sh [--keep]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

keep=0
[ "${1:-}" = "--keep" ] && keep=1

# Suites that need no special hardware, no network and no money. gpu, network
# and claude are deliberately excluded: their correct behaviour on a machine
# without a GPU, offline, or without --claude is to skip, which tells us
# nothing about whether they work.
#
# One line per suite: <name> <comma-separated metrics the suite must emit>.
EXPECTED='
sysinfo   -
cpu-single int,float,sieve
cpu-multi  threads_1,threads_all,scaling_efficiency
memory     read,write,copy,triad,latency
crypto     sha256,aes_256_cbc
disk       seq_write,seq_read,fsync_latency
'

pass=0; fail=0; skipped=0
ok()   { printf '  ok       %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  FAIL     %s\n' "$*" >&2; fail=$((fail + 1)); }
skip() { printf '  skipped  %s\n' "$*"; skipped=$((skipped + 1)); }

# --- build -----------------------------------------------------------------

if [ ! -x "$ROOT/build/cpu_kernel" ] || [ ! -x "$ROOT/build/mem_bw" ]; then
	printf '==> building kernels\n'
	"$ROOT/bench" build >/dev/null || { printf 'FAIL: ./bench build failed\n' >&2; exit 1; }
fi

# --- sandbox ---------------------------------------------------------------

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/lb-smoke.XXXXXX") || { printf 'FAIL: cannot create sandbox\n' >&2; exit 1; }
if [ "$keep" -eq 1 ]; then
	trap 'printf "sandbox kept at %s\n" "$sandbox"' EXIT
else
	trap 'rm -rf "$sandbox"' EXIT
fi

for item in bench lib benches src build; do
	ln -s "$ROOT/$item" "$sandbox/$item" || exit 1
done
mkdir -p "$sandbox/results" "$sandbox/disktmp"

# Reference point for the leak check below. Anything appearing in the real
# results/ newer than this came from the test run.
marker="$sandbox/.started"
touch "$marker"

# --- run -------------------------------------------------------------------

only=$(printf '%s\n' "$EXPECTED" | awk 'NF { printf "%s%s", sep, $1; sep = "," }')

printf '==> running: %s\n' "$only"
log="$sandbox/run.log"
LB_DISK_DIR="$sandbox/disktmp" LB_DISK_MIB=64 \
	"$sandbox/bench" run --quick --tag smoke-test --only "$only" >"$log" 2>&1
run_rc=$?

if [ "$run_rc" -ne 0 ]; then
	printf 'FAIL: ./bench run exited %d\n' "$run_rc" >&2
	sed 's/^/    | /' "$log" >&2
	exit 1
fi

# --- locate the result -----------------------------------------------------

result=$(find "$sandbox/results" -maxdepth 1 -name '*.json' -print -quit)
if [ -z "$result" ]; then
	printf 'FAIL: run wrote no JSON into the sandbox\n' >&2
	sed 's/^/    | /' "$log" >&2
	exit 1
fi

# Nothing may have leaked into the real results directory.
printf '==> checking the run\n'
if [ -n "$(find "$ROOT/results" -newer "$marker" -name '*.json' 2>/dev/null)" ]; then
	bad "the test run wrote into $ROOT/results (sandbox leaked)"
else
	ok "results/ untouched"
fi

# --- parse -----------------------------------------------------------------

# Reuse the project's own reader rather than a second parser, so a change to
# the JSON layout that breaks reporting also breaks this test.
flat="$sandbox/flat.tsv"
if ! awk -f "$ROOT/lib/fromjson.awk" "$result" >"$flat" 2>"$sandbox/parse.err"; then
	printf 'FAIL: lib/fromjson.awk could not read the result\n' >&2
	sed 's/^/    | /' "$sandbox/parse.err" >&2
	exit 1
fi

if [ -s "$flat" ]; then
	ok "lib/fromjson.awk parsed the result"
else
	bad "lib/fromjson.awk produced no records"
fi

# Run-level identity must survive the round trip.
if awk -F'\t' '$1 == "R" && $2 != "" { found = 1 } END { exit !found }' "$flat"; then
	ok "run_id present"
else
	bad "no run_id in the parsed result"
fi

if awk -F'\t' '$1 == "H" && $2 == "hostname" && $3 != "" { found = 1 } END { exit !found }' "$flat"; then
	ok "host facts recorded"
else
	bad "no hostname among the host facts"
fi

# --- assert per suite ------------------------------------------------------

while read -r suite metrics; do
	[ -n "$suite" ] || continue

	status=$(awk -F'\t' -v s="$suite" '$1 == "S" && $2 == s { print $3; exit }' "$flat")
	note=$(awk -F'\t' -v s="$suite" '$1 == "S" && $2 == s { print $4; exit }' "$flat")

	case "$status" in
		'')   bad "$suite: no status recorded"; continue ;;
		skip) skip "$suite: ${note:-no reason given}"; continue ;;
		fail) bad "$suite: reported fail (${note:-no reason given})"; continue ;;
		ok)   ;;
		*)    bad "$suite: unknown status '$status'"; continue ;;
	esac

	[ "$metrics" = "-" ] && { ok "$suite: ok"; continue; }

	missing=""
	bogus=""
	old_ifs=$IFS; IFS=,; read -r -a wanted <<<"$metrics"; IFS=$old_ifs
	for metric in "${wanted[@]}"; do
		# Fields: M suite metric unit hib median spread_pct min max n
		line=$(awk -F'\t' -v s="$suite" -v m="$metric" '$1 == "M" && $2 == s && $3 == m { print; exit }' "$flat")
		if [ -z "$line" ]; then
			missing="${missing:+$missing }$metric"
			continue
		fi
		median=$(printf '%s' "$line" | cut -f6)
		n=$(printf '%s' "$line" | cut -f10)
		awk -v v="$median" -v n="$n" 'BEGIN { exit !(v + 0 > 0 && n + 0 >= 1) }' \
			|| bogus="${bogus:+$bogus }$metric(median=$median,n=$n)"
	done

	if [ -n "$missing" ]; then
		bad "$suite: missing metrics: $missing"
	elif [ -n "$bogus" ]; then
		bad "$suite: non-positive or unsampled metrics: $bogus"
	else
		ok "$suite: ok, all metrics present and positive"
	fi
done <<EOF
$EXPECTED
EOF

# --- reporting path --------------------------------------------------------

printf '==> checking the reporting path\n'
for sub in db sysdb; do
	if "$sandbox/bench" "$sub" >/dev/null 2>&1; then
		ok "./bench $sub"
	else
		bad "./bench $sub exited non-zero"
	fi
done

for doc in RESULTS.md SYSTEMS.md; do
	if [ -s "$sandbox/results/$doc" ]; then
		ok "$doc regenerated"
	else
		bad "$doc missing or empty after regeneration"
	fi
done

if "$sandbox/bench" show "$result" >/dev/null 2>&1; then
	ok "./bench show"
else
	bad "./bench show exited non-zero"
fi

# --- verdict ---------------------------------------------------------------

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
