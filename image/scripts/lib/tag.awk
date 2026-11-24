# Adds name n to tag t in the tags file (see packs.sh tag). Exits 3 when it has it already
{ L[NR] = $0; H[NR] = tf_hdr($0) }
END {
	ln = tolower(n)
	for (i = 1; i <= NR; i++) if (H[i] == "tag." t) { s = i; break }
	if (!s) {
		for (i = 1; i <= NR; i++) if (H[i] ~ /^tag\./ && substr(H[i], 5) > t) { at = i; break }
		for (i = 1; i <= NR; i++) {
			if (i == at) { print "[tag." t "]"; print n; print "" }
			print L[i]
		}
		if (!at) {
			if (NR && L[NR] !~ /^[ \t]*$/) print ""
			print "[tag." t "]"
			print n
		}
		exit 0
	}
	e = NR + 1
	for (i = s + 1; i <= NR; i++) if (H[i] != "") { e = i; break }
	for (i = s; i < e; i++) {
		k = tf_words(L[i], w)
		for (j = (i == s ? 2 : 1); j <= k; j++) if (tolower(w[j]) == ln) exit 3
	}
	last = 0
	at = 0
	for (i = s + 1; i < e; i++) if (tf_words(L[i], w)) { last = i; if (!at && tolower(w[1]) > ln) at = i }
	before = 0
	after = 0
	hl = ""
	if (last) { if (at) before = at; else after = last }
	else if ((k = tf_words(L[s], w)) > 1) {
		hl = w[1]
		put = 0
		for (j = 2; j <= k; j++) {
			if (!put && tolower(w[j]) > ln) { hl = hl " " n; put = 1 }
			hl = hl " " w[j]
		}
		if (!put) hl = hl " " n
		if ((c = index(L[s], "#"))) hl = hl "  " substr(L[s], c)
	} else after = s
	for (i = 1; i <= NR; i++) {
		if (i == before) print n
		print (i == s && hl != "" ? hl : L[i])
		if (i == after) print n
	}
}
