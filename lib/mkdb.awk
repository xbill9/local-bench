# Build results/RESULTS.md from the staged record stream that ./bench db
# produces: every line is a lib/fromjson.awk record prefixed with the run_id
# and hostname it came from.
#
#   run_id host R  run_id tag started finished reps duration
#   run_id host H  key value
#   run_id host S  suite status note
#   run_id host M  suite metric unit hib median spread min max n
#   run_id host W  message
#
# The output is three markdown tables. Measurements are kept in long form --
# one row per (run, suite, metric) -- rather than a wide matrix, because that
# stays readable as machines are added and is trivial to grep or awk against.

function cell(s) {
	if (s == "") return "-"
	gsub(/\|/, "\\|", s)   # a literal pipe would break the table
	return s
}

# Trim a CPU model string to something that fits a table column.
function shortcpu(s) {
	gsub(/\(R\)|\(TM\)|\(tm\)|CPU |Processor|@.*/, "", s)
	gsub(/^ +| +$/, "", s)
	gsub(/  +/, " ", s)
	return s
}

BEGIN { FS = "\t" }

{ id = $1; host = $2; type = $3 }

!(id in runseen) { runseen[id] = 1; runorder[++nrun] = id; runhost[id] = host }

type == "R" { tag[id] = $5; started[id] = $6; reps[id] = $8; dur[id] = $9; next }

type == "H" {
	hv[id, $4] = $5
	# Host facts are keyed by machine, not by run: the newest run wins, so the
	# Hosts table describes each box as it was most recently seen.
	if (!(host in hostseen)) { hostseen[host] = 1; hostorder[++nhost] = host }
	hf[host, $4] = $5
	hostlast[host] = id
	hostruns[host]++   # counted once per host fact stream, corrected below
	next
}

type == "S" {
	nsuite[id]++
	if ($5 == "ok") nok[id]++
	else if ($5 == "skip") nskip[id]++
	else nfail[id]++
	next
}

type == "M" {
	k = id SUBSEP $4 SUBSEP $5
	if (!(k in mseen)) { mseen[k] = 1; morder[++nm] = k
		msuite[k] = $4; mmetric[k] = $5; munit[k] = $6; mhib[k] = $7
		mmed[k] = $8; msp[k] = $9; mmin[k] = $10; mmax[k] = $11; mn[k] = $12
		mrun[k] = id; mhost[k] = host }
	next
}

type == "W" { warn[++nw] = id SUBSEP $4; next }

END {
	# hostruns was incremented per host-fact line; recount properly.
	for (i = 1; i <= nrun; i++) runsper[runhost[runorder[i]]]++

	print "## Hosts"
	print ""
	print "| host | os | platform | cpu | threads | mem MiB | gpu | runs | latest run |"
	print "|---|---|---|---|---|---|---|---|---|"
	for (i = 1; i <= nhost; i++) {
		h = hostorder[i]
		plat = hf[h, "platform"]
		if (plat == "") plat = hf[h, "container"]
		if (plat == "" && hf[h, "virt"] != "" && hf[h, "virt"] != "none") plat = hf[h, "virt"]
		if (plat == "") plat = "bare metal"
		printf "| %s | %s | %s | %s | %s | %s | %s | %d | `%s` |\n",
			cell(h), cell(hf[h, "os"]), cell(plat),
			cell(shortcpu(hf[h, "cpu_model"])), cell(hf[h, "cpu_threads"]),
			cell(hf[h, "mem_total_mib"]),
			cell(hf[h, "gpu_name"]), runsper[h], hostlast[h]
	}

	print ""
	print "## Runs"
	print ""
	print "| run_id | started (UTC) | host | tag | reps | sec/sample | ok | skip | fail |"
	print "|---|---|---|---|---|---|---|---|---|"
	for (i = 1; i <= nrun; i++) {
		r = runorder[i]
		printf "| `%s` | %s | %s | %s | %s | %s | %d | %d | %d |\n",
			r, cell(started[r]), cell(runhost[r]), cell(tag[r]),
			cell(reps[r]), cell(dur[r]), nok[r], nskip[r], nfail[r]
	}

	print ""
	print "## Measurements"
	print ""
	print "| run_id | host | suite | metric | median | unit | dir | spread% | n |"
	print "|---|---|---|---|---|---|---|---|---|"
	for (i = 1; i <= nm; i++) {
		k = morder[i]
		printf "| `%s` | %s | %s | %s | %.6g | %s | %s | %.1f | %s |\n",
			mrun[k], cell(mhost[k]), cell(msuite[k]), cell(mmetric[k]),
			mmed[k] + 0, cell(munit[k]), (mhib[k] == "true" ? "^" : "v"),
			msp[k] + 0, cell(mn[k])
	}

	if (nw > 0) {
		print ""
		print "## Warnings"
		print ""
		print "| run_id | warning |"
		print "|---|---|"
		for (i = 1; i <= nw; i++) {
			split(warn[i], p, SUBSEP)
			printf "| `%s` | %s |\n", p[1], cell(p[2])
		}
	}
}
