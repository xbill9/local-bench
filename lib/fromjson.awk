# Flatten a local-bench result document into tab-separated records.
#
# This is not a general JSON parser. It relies on the fixed layout that
# lib/tojson.awk emits -- one field per line, two-space indent steps -- which
# is safe because the same project writes and reads the file, and it keeps the
# tool free of a jq dependency on machines that do not have it.
#
# Emits:
#   R  run_id  tag  started  finished  reps  duration
#   H  key     value
#   S  suite   status  note
#   M  suite   metric  unit  hib  median  spread_pct  min  max  n

function unq(s) { gsub(/^[ \t]*"|"[ \t]*[,}]?[ \t]*$/, "", s); return s }
function val(line,    v) {
	v = line
	sub(/^[^:]*:[ \t]*/, "", v)     # drop the key
	sub(/[ \t]*,[ \t]*$/, "", v)    # drop a trailing comma
	gsub(/^"|"$/, "", v)            # drop surrounding quotes
	return v
}
function indent(line,    n) { match(line, /^ */); return RLENGTH }

BEGIN { section = ""; suite = ""; metric = "" }

/^  "run_id":/    { run_id = val($0); next }
/^  "tag":/       { tag = val($0); next }
/^  "started_utc":/  { started = val($0); next }
/^  "finished_utc":/ { finished = val($0); next }
/^  "config":/ {
	# config is emitted inline on one line
	line = $0
	reps = line; sub(/.*"reps":[ \t]*/, "", reps); sub(/[ \t]*,.*/, "", reps)
	dur = line; sub(/.*"duration_sec":[ \t]*/, "", dur); sub(/[ \t]*,.*/, "", dur)
	next
}

/^  "host": \{/   { section = "host"; next }
/^  "suites": \{/ { section = "suites"; next }
/^  "warnings":/  {
	section = "warn"
	line = $0
	sub(/^  "warnings":[ \t]*\[/, "", line)
	sub(/\][ \t]*$/, "", line)
	n = split(line, parts, /", *"/)
	for (i = 1; i <= n; i++) {
		w = parts[i]
		gsub(/^"|"$/, "", w)
		if (w != "") printf "W\t%s\n", w
	}
	next
}

section == "host" && indent($0) == 4 && /:/ {
	k = $0; sub(/^[ \t]*"/, "", k); sub(/".*$/, "", k)
	printf "H\t%s\t%s\n", k, val($0)
	next
}

section == "suites" {
	# A 4-space key opening a brace starts a suite; 8 spaces starts a metric.
	if (indent($0) == 4 && /\{[ \t]*$/) {
		suite = $0; sub(/^[ \t]*"/, "", suite); sub(/".*$/, "", suite)
		status[suite] = ""; note[suite] = ""
		order[++nsuite] = suite
		next
	}
	if (indent($0) == 6 && /"status":/) { status[suite] = val($0); next }
	if (indent($0) == 6 && /"note":/)   { note[suite] = val($0); next }
	if (indent($0) == 8 && /\{[ \t]*$/) {
		metric = $0; sub(/^[ \t]*"/, "", metric); sub(/".*$/, "", metric)
		next
	}
	if (indent($0) == 10) {
		if (/"unit":/)        u[suite, metric] = val($0)
		else if (/"higher_is_better":/) h[suite, metric] = val($0)
		else if (/"median":/) md[suite, metric] = val($0)
		else if (/"spread_pct":/) sp[suite, metric] = val($0)
		else if (/"min":/)    mn[suite, metric] = val($0)
		else if (/"max":/)    mx[suite, metric] = val($0)
		else if (/"n":/) {
			cnt[suite, metric] = val($0)
			mo[suite, ++nmetric[suite]] = metric
		}
		next
	}
}

END {
	printf "R\t%s\t%s\t%s\t%s\t%s\t%s\n", run_id, tag, started, finished, reps, dur
	for (i = 1; i <= nsuite; i++) {
		s = order[i]
		printf "S\t%s\t%s\t%s\n", s, status[s], note[s]
		for (j = 1; j <= nmetric[s]; j++) {
			m = mo[s, j]
			printf "M\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
				s, m, u[s, m], h[s, m], md[s, m], sp[s, m],
				mn[s, m], mx[s, m], cnt[s, m]
		}
	}
}
