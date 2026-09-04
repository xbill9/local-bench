#!/usr/bin/env bash
# Claude Code performance from this host.
#
# Opt-in (--claude), because unlike every other suite this one spends the
# user's Claude quota and leaves the machine.
#
# The measurements separate what the host controls from what the network and
# the service control, which is the only way a Debian-vs-ChromeOS comparison
# means anything:
#
#   cli_startup_ms      `claude --version`: binary load, disk, CPU. Pure local.
#   time_to_request_ms  CLI work before the request goes out. Local.
#   ttft_ms             first token back. Network + service, some local.
#   output_tok_per_sec  generation rate once streaming. Service-dominated.
#   total_ms            what the user actually waits.
#
# So a ChromeOS Flex box on the same LAN should differ from Debian mainly in
# the two local figures; a large ttft gap points at the network instead.
set -uo pipefail
source "$LB_ROOT/lib/common.sh"

if [ "${LB_CLAUDE:-0}" != "1" ]; then
	lb_status claude skip "not requested; re-run with --claude"
	exit 0
fi

if ! lb_have claude; then
	lb_status claude skip "claude CLI not installed"
	exit 0
fi

model="${LB_CLAUDE_MODEL:-haiku}"
lb_info claude_cli_version "$(claude --version 2>/dev/null | head -1)"
lb_info claude_model_requested "$model"

# Run from an empty directory: a project's CLAUDE.md and files change the
# prompt size, and a run whose context differs is not a run you can compare.
workdir=$(mktemp -d "${TMPDIR:-/tmp}/lb-claude.XXXXXX") || {
	lb_status claude fail "could not create temp dir"; exit 0; }
trap 'rm -rf "$workdir"' EXIT

# --- local startup ---------------------------------------------------------
# `claude --version` does no network I/O, so this isolates how long the host
# takes just to get the CLI running.
startup=()
for _ in $(seq 1 "$LB_REPS"); do
	s=$(date +%s%N)
	claude --version >/dev/null 2>&1 || break
	e=$(date +%s%N)
	startup+=("$(awk -v a="$s" -v b="$e" 'BEGIN {printf "%.1f", (b-a)/1e6}')")
done
[ ${#startup[@]} -gt 0 ] && lb_metric claude cli_startup "ms" 0 "${startup[@]}"

# --- one non-interactive query --------------------------------------------
# --strict-mcp-config keeps a machine's MCP servers out of the measurement so
# two hosts are compared on the same prompt.
ask() {
	( cd "$workdir" && timeout 180 claude -p "$1" \
		--output-format json \
		--model "$model" \
		--strict-mcp-config \
		--no-session-persistence 2>/dev/null )
}

# Pull a top-level numeric field out of the one-line result JSON. jq is used
# when present; the grep fallback keeps this working on a bare Crostini
# container where jq is not installed.
jnum() {
	local key="$1" json="$2"
	if lb_have jq; then
		printf '%s' "$json" | jq -r --arg k "$key" '..|objects|select(has($k))|.[$k]' 2>/dev/null | head -1
	else
		printf '%s' "$json" | grep -o "\"$key\":[0-9.]*" | head -1 | cut -d: -f2
	fi
}

ttft=(); total=(); api=(); pre=(); tps=()
cost_total=0; ok=0; errs=0

for _ in $(seq 1 "$LB_REPS"); do
	# A trivial prompt: the reply is short, so the timings describe the round
	# trip rather than how long the model chose to talk.
	json=$(ask 'Reply with exactly the word: ok')
	if [ -z "$json" ] || [ "${json#\{}" = "$json" ]; then
		errs=$((errs + 1))
		continue
	fi
	if [ "$(jnum is_error "$json")" = "true" ]; then errs=$((errs + 1)); continue; fi

	v=$(jnum ttft_ms "$json");              [ -n "$v" ] && ttft+=("$v")
	v=$(jnum duration_ms "$json");          [ -n "$v" ] && total+=("$v")
	v=$(jnum duration_api_ms "$json");      [ -n "$v" ] && api+=("$v")
	v=$(jnum time_to_request_ms "$json");   [ -n "$v" ] && pre+=("$v")
	c=$(printf '%s' "$json" | grep -o '"total_cost_usd":[0-9.]*' | head -1 | cut -d: -f2)
	[ -n "$c" ] && cost_total=$(awk -v a="$cost_total" -v b="$c" 'BEGIN {printf "%.6f", a+b}')
	ok=$((ok + 1))
	lb_cooldown
done

# --- generation rate -------------------------------------------------------
# A prompt with a fixed, non-trivial output length, so output tokens divided by
# the streaming window is a rate rather than an artefact of a two-word reply.
for _ in $(seq 1 "$LB_REPS"); do
	json=$(ask 'Count from 1 to 100. Output only the numbers, one per line, nothing else.')
	# Both checks must pass; the || arm is the intended error path.
	# shellcheck disable=SC2015
	[ -n "$json" ] && [ "${json#\{}" != "$json" ] || { errs=$((errs + 1)); continue; }

	out=$(jnum output_tokens "$json")
	dur=$(jnum duration_ms "$json")
	first=$(jnum ttft_ms "$json")
	c=$(printf '%s' "$json" | grep -o '"total_cost_usd":[0-9.]*' | head -1 | cut -d: -f2)
	[ -n "$c" ] && cost_total=$(awk -v a="$cost_total" -v b="$c" 'BEGIN {printf "%.6f", a+b}')

	# Rate over the streaming window only (total minus time to first token);
	# including the wait would make a slow network look like a slow model.
	r=$(awk -v o="${out:-0}" -v d="${dur:-0}" -v f="${first:-0}" \
		'BEGIN { w = (d - f) / 1000.0; if (o > 0 && w > 0.05) printf "%.2f", o / w }')
	[ -n "$r" ] && tps+=("$r")
	lb_cooldown
done

[ ${#pre[@]}   -gt 0 ] && lb_metric claude time_to_request "ms" 0 "${pre[@]}"
[ ${#ttft[@]}  -gt 0 ] && lb_metric claude ttft            "ms" 0 "${ttft[@]}"
[ ${#total[@]} -gt 0 ] && lb_metric claude total_roundtrip "ms" 0 "${total[@]}"
[ ${#api[@]}   -gt 0 ] && lb_metric claude api_duration    "ms" 0 "${api[@]}"
[ ${#tps[@]}   -gt 0 ] && lb_metric claude output_tok_per_sec "tok/s" 1 "${tps[@]}"

lb_info claude_queries_ok "$ok"
lb_info claude_cost_usd "$cost_total"

if [ "$ok" -eq 0 ]; then
	lb_status claude fail "no query succeeded (not logged in, offline, or rate limited)"
elif [ "$errs" -gt 0 ]; then
	lb_status claude ok "$errs of $((ok + errs)) queries failed; cost \$$cost_total"
else
	lb_status claude ok "cost \$$cost_total"
fi
