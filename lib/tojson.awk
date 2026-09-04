# Turn local-bench tab-separated records into one JSON result document.
#
# Records (see lib/common.sh):
#   M  suite  metric  unit  hib  v1,v2,...
#   S  suite  status  note
#   I  key    value
#   W  message
#
# Insertion order is preserved for suites and metrics so the JSON reads in the
# order the run actually executed.

function esc(s,    out, i, c, n) {
	out = ""
	n = length(s)
	for (i = 1; i <= n; i++) {
		c = substr(s, i, 1)
		if (c == "\\") out = out "\\\\"
		else if (c == "\"") out = out "\\\""
		else if (c == "\n") out = out "\\n"
		else if (c == "\r") out = out "\\r"
		else if (c == "\t") out = out "\\t"
		else out = out c
	}
	return out
}

# Emit a number bare if it is one, otherwise as a JSON string. Keeps numeric
# host facts (core counts, sizes) usable by consumers without reparsing.
function numOrStr(v) {
	if (v ~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) return v
	return "\"" esc(v) "\""
}

function isort(arr, n,    i, j, t) {
	for (i = 2; i <= n; i++) {
		t = arr[i]
		j = i - 1
		while (j >= 1 && arr[j] + 0 > t + 0) { arr[j+1] = arr[j]; j-- }
		arr[j+1] = t
	}
}

BEGIN { FS = "\t"; nsuite = 0; ninfo = 0; nwarn = 0 }

$1 == "I" { if (!(($2) in infoseen)) { infoseen[$2] = 1; infokey[++ninfo] = $2 } infoval[$2] = $3; next }
$1 == "W" { warn[++nwarn] = $2; next }

$1 == "S" {
	s = $2
	if (!(s in suiteseen)) { suiteseen[s] = 1; suiteorder[++nsuite] = s; nmetric[s] = 0 }
	status[s] = $3
	note[s] = $4
	next
}

$1 == "M" {
	s = $2; m = $3
	if (!(s in suiteseen)) { suiteseen[s] = 1; suiteorder[++nsuite] = s; nmetric[s] = 0; status[s] = "ok" }
	k = s SUBSEP m
	if (!(k in metricseen)) { metricseen[k] = 1; metricname[s, ++nmetric[s]] = m }
	unit[k] = $4
	hib[k] = ($5 + 0) ? "true" : "false"
	samples[k] = $6
	next
}

END {
	printf "{\n"
	printf "  \"schema\": 1,\n"
	printf "  \"run_id\": \"%s\",\n", esc(run_id)
	printf "  \"tag\": \"%s\",\n", esc(tag)
	printf "  \"started_utc\": \"%s\",\n", esc(started)
	printf "  \"finished_utc\": \"%s\",\n", esc(finished)
	printf "  \"config\": { \"reps\": %d, \"duration_sec\": %s, \"cooldown_sec\": %s },\n", reps, duration, cooldown

	printf "  \"host\": {\n"
	for (i = 1; i <= ninfo; i++) {
		printf "    \"%s\": %s%s\n", esc(infokey[i]), numOrStr(infoval[infokey[i]]), (i < ninfo ? "," : "")
	}
	printf "  },\n"

	printf "  \"suites\": {\n"
	for (si = 1; si <= nsuite; si++) {
		s = suiteorder[si]
		printf "    \"%s\": {\n", esc(s)
		printf "      \"status\": \"%s\",\n", esc(status[s])
		printf "      \"note\": \"%s\",\n", esc(note[s])
		printf "      \"metrics\": {\n"
		for (mi = 1; mi <= nmetric[s]; mi++) {
			m = metricname[s, mi]
			k = s SUBSEP m
			n = split(samples[k], v, ",")
			isort(v, n)
			# Median of an even-sized sample set is the mean of the two
			# middle values.
			if (n % 2) med = v[(n+1)/2] + 0
			else med = (v[n/2] + v[n/2+1]) / 2.0
			sum = 0
			for (q = 1; q <= n; q++) sum += v[q] + 0
			mean = sum / n
			lo = v[1] + 0; hi = v[n] + 0
			# Spread relative to the median: how noisy this measurement
			# was. Large spread means the number should not be trusted.
			spread = (med != 0) ? (hi - lo) / med * 100.0 : 0
			printf "        \"%s\": {\n", esc(m)
			printf "          \"unit\": \"%s\",\n", esc(unit[k])
			printf "          \"higher_is_better\": %s,\n", hib[k]
			printf "          \"median\": %.6g,\n", med
			printf "          \"mean\": %.6g,\n", mean
			printf "          \"min\": %.6g,\n", lo
			printf "          \"max\": %.6g,\n", hi
			printf "          \"spread_pct\": %.3f,\n", spread
			printf "          \"n\": %d,\n", n
			printf "          \"samples\": ["
			for (q = 1; q <= n; q++) printf "%s%.6g", (q > 1 ? ", " : ""), v[q] + 0
			printf "]\n"
			printf "        }%s\n", (mi < nmetric[s] ? "," : "")
		}
		printf "      }\n"
		printf "    }%s\n", (si < nsuite ? "," : "")
	}
	printf "  },\n"

	printf "  \"warnings\": ["
	for (i = 1; i <= nwarn; i++) printf "%s\"%s\"", (i > 1 ? ", " : ""), esc(warn[i])
	printf "]\n"
	printf "}\n"
}
