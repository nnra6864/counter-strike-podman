# Every tag the tags file has, one per line (sort -u after): for cs save's picker
{
	k = tf_words($0, w)
	h = tf_hdr($0)
	if (h != "") {
		hm = tf_type(h)
		if (hm == "tag") print tf_key(h)
	}
	if (hm != "item") next
	for (i = h != "" ? 2 : 1; i <= k; i++) {
		if (tf_stray(w[i])) continue
		t = tolower(w[i])
		sub(/^@/, "", t)
		print t
	}
}
