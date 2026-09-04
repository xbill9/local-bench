# Roll every run up into one record per system (platform).
#
# Input is the staged stream built by bench: each line is
#   system_id \t run_id \t host \t <flattened record from lib/fromjson.awk>
# so the original record type sits in $4 and its fields follow.
#
# Output (tab separated):
#   META <sysid> <platform> <hostname> <os> <nruns> <first_seen> <last_seen>
#   SPEC <sysid> <key> <value>
#   CAP  <sysid> <suite/metric> <unit> <hib> <median> <best> <nruns>
#
# A system's capability is the MEDIAN of each run's median, not the best run.
# Best-of flatters whichever machine was measured most often; the median is
# what that platform actually delivers on a normal day. The best figure is
# carried alongside so a thermal or noise gap is visible rather than hidden.

function isort(a, n,   i, j, t) {
	for (i = 2; i <= n; i++) {
		t = a[i]; j = i - 1
		while (j >= 1 && a[j] + 0 > t + 0) { a[j+1] = a[j]; j-- }
		a[j+1] = t
	}
}

BEGIN { FS = "\t"; OFS = "\t" }

{
	sid = $1
	if (!(sid in seen)) { seen[sid] = 1; order[++nsys] = sid }
}

# Host facts. First run wins for specs; they are identity fields, so a later
# run disagreeing would have produced a different system_id anyway.
$4 == "H" {
	if (!((sid SUBSEP $5) in spec)) { spec[sid, $5] = $6; speckeys[sid, ++nspec[sid]] = $5 }
	next
}

$4 == "R" {
	rid = $5
	if (!((sid SUBSEP rid) in runseen)) {
		runseen[sid, rid] = 1
		nruns[sid]++
	}
	started = $7
	if (first[sid] == "" || started < first[sid]) first[sid] = started
	if (last[sid]  == "" || started > last[sid])  last[sid]  = started
	next
}

$4 == "M" {
	key = $5 "/" $6
	if (!((sid SUBSEP key) in capseen)) {
		capseen[sid, key] = 1
		capkeys[sid, ++ncap[sid]] = key
	}
	if (!(key in metricseen)) { metricseen[key] = 1 }
	unit[sid, key] = $7
	hib[sid, key]  = $8
	vals[sid, key, ++vn[sid, key]] = $9
	next
}

END {
	for (i = 1; i <= nsys; i++) {
		sid = order[i]
		platform = spec[sid, "platform"]
		if (platform == "") platform = spec[sid, "container"]
		if (platform == "" && spec[sid, "virt"] != "none") platform = spec[sid, "virt"]
		if (platform == "") platform = "bare-metal"

		print "META", sid, platform, spec[sid, "hostname"], spec[sid, "os"], \
			nruns[sid], first[sid], last[sid]

		for (j = 1; j <= nspec[sid]; j++) {
			k = speckeys[sid, j]
			print "SPEC", sid, k, spec[sid, k]
		}

		for (j = 1; j <= ncap[sid]; j++) {
			key = capkeys[sid, j]
			n = vn[sid, key]
			for (q = 1; q <= n; q++) tmp[q] = vals[sid, key, q]
			isort(tmp, n)
			med = (n % 2) ? tmp[(n+1)/2] + 0 : (tmp[n/2] + tmp[n/2+1]) / 2.0
			# "Best" follows the metric's direction: for latency the best
			# run is the fastest, which is the smallest number.
			best = (hib[sid, key] == "true") ? tmp[n] + 0 : tmp[1] + 0
			print "CAP", sid, key, unit[sid, key], hib[sid, key], med, best, n
			for (q = 1; q <= n; q++) delete tmp[q]
		}
	}
}
