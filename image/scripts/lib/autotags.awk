# The autotags file as <tag> <tab> <pattern> lines, lowercase
function bad(m) { print "[packs] " m > "/dev/stderr" }
{
	k = tf_words($0, w)
	h = tf_hdr($0)
	if (h != "") {
		t = tf_key(h)
		if (tf_kind(h) != "tag" || t !~ /^[a-z0-9_-]+$/) {
			bad("autotags: " w[1] ": not a header like [tag.snow], skipping what is under it")
			t = "-"
		}
	}
	for (i = h != "" ? 2 : 1; i <= k; i++) {
		if (tf_stray(w[i])) { bad("autotags: " w[i] ": a header has to start its line, skipped"); continue }
		if (t == "") { if (!top++) bad("autotags: " w[i] ": before any header, skipped") }
		else if (t != "-") print t "\t" tolower(w[i])
	}
}
