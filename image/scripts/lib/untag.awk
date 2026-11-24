# The tags file without the names in "names", and what went into file rep (see packs.sh
# remove)
function out(s) {
	if (s ~ /^[ \t]*$/) { if (blank++) return } else blank = 0
	print s
}
BEGIN { k = split(names, a, " "); for (i = 1; i <= k; i++) N[a[i]] = 1 }
{
	h = tf_hdr($0)
	if (h != "") {
		sec = h
		drop = tf_type(h) == "item" && (tf_key(h) in N)
		if (drop) print "[" h "]\t(all of it)" >rep
	}
	if (drop) next
	if (sec !~ /^tag\./) { out($0); next }
	c = index($0, "#")
	body = c ? substr($0, 1, c - 1) : $0
	com = c ? substr($0, c) : ""
	k = split(body, w)
	line = ""
	gone = 0
	for (j = 1; j <= k; j++) {
		if (!(h != "" && j == 1) && (tolower(w[j]) in N)) {
			print "[" sec "]\t" w[j] >rep
			gone = 1
			continue
		}
		line = line (line == "" ? "" : " ") w[j]
	}
	if (!gone) { out($0); next }
	# A line that had only them goes
	if (line == "" && com == "") next
	out(line (com == "" ? "" : (line == "" ? "" : "  ") com))
}
