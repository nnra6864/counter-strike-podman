# The tags file's format, for every awk program that reads it (and the autotags file,
# which has only [tag.x] headers). Loaded first: awk -f tagsfile.awk -f <program>.
#
# A line is an optional header, then names; # starts a comment:
#   [tag.snow] fy_snow de_dust2_xmas
#   [map.fy_snow] winter arena          ([plugin.x] and [pack.x] are the same)
# A header has to be the first word on its line. Names under it run until the next one.

# The line without its comment
function tf_body(s) { sub(/#.*/, "", s); return s }
# The words of line s in a, its header among them: their number
function tf_words(s, a) { return split(tf_body(s), a) }
# Line s's header, lowercase and without the brackets ("tag.snow"), or ""
function tf_hdr(s,    a) {
	if (!tf_words(s, a) || a[1] !~ /^\[[^]]*\]$/) return ""
	return tolower(substr(a[1], 2, length(a[1]) - 2))
}
# Header h's kind ("tag") and key ("snow")
function tf_kind(h) { sub(/\..*$/, "", h); return h }
function tf_key(h) { return substr(h, length(tf_kind(h)) + 2) }
# What header h says: "tag" (names with this tag), "item" (tags this name has), or "bad"
function tf_type(h,    k) {
	k = tf_kind(h)
	if (tf_key(h) == "") return "bad"
	if (k == "tag") return "tag"
	if (k == "map" || k == "plugin" || k == "pack") return "item"
	return "bad"
}
# A word that looks like a header but isn't the first on its line
function tf_stray(w) { return w ~ /^\[[^]]*\]$/ }
