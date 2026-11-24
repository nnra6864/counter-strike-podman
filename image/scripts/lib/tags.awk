# The tags file against the index: awk -v mode=<mode> -v q=<arg> -v indexf=<index> -f
# tagsfile.awk -f tags.awk <index> <tags file>. Modes: query <a+b>, match <name>, check, list
# (see tags() in packs.sh)
function warn(m) { print "[packs] " m > "/dev/stderr" }
# Mistakes in the file: once, by check
function bad(m) { if (mode == "check") warn(m) }
function glob2re(g,    r, i, j, c, n) {
	r = "^"
	n = length(g)
	for (i = 1; i <= n; i++) {
		c = substr(g, i, 1)
		if (c == "*") r = r ".*"
		else if (c == "?") r = r "."
		else if (c == "[" && (j = index(substr(g, i + 1), "]")) > 0) { r = r substr(g, i, j + 1); i += j }
		else if (index(".+^$(){}|\\[]", c)) r = r "\\" c
		else r = r c
	}
	return r "$"
}
function matches(m, j,    re) {
	if (!(m in RE)) RE[m] = glob2re(tolower(m))
	re = RE[m]
	return tolower(iname[j]) ~ re || tolower(imap[j]) ~ re || tolower(irel[j]) ~ re
}
function add(t, m) {
	t = tolower(t)
	sub(/^@/, "", t)
	known[t] = 1
	if (!(t in seen)) { seen[t] = 1; torder[++nt] = t }
	mem[t, ++nmem[t]] = m
	where[t, nmem[t]] = hdr
}
function set_of(t,    i, j, m, u) {
	if (t in done) return
	done[t] = 1
	for (i = 1; i <= nmem[t]; i++) {
		m = mem[t, i]
		if (m ~ /^@/) {
			u = tolower(substr(m, 2))
			set_of(u)
			for (j = 1; j <= n; j++) if ((u, j) in S) S[t, j] = 1
		} else
			for (j = 1; j <= n; j++) if (matches(m, j)) S[t, j] = 1
	}
}
FILENAME == indexf { n++; split($0, f, "\t"); irel[n] = f[1]; iname[n] = f[2]; imap[n] = f[3]; ipath[n] = f[4]; next }
{
	k = tf_words($0, wd)
	h = tf_hdr($0)
	if (h != "") {
		hdr = wd[1]
		hm = tf_type(h)
		key = tf_key(h)
		if (hm == "bad") bad("tags: " hdr ": not a header like [tag.snow] or [map.fy_snow], skipping what is under it")
	}
	for (i = h != "" ? 2 : 1; i <= k; i++) {
		if (tf_stray(wd[i])) { bad("tags: " wd[i] ": a header has to start its line, skipped"); continue }
		if (hm == "tag") add(key, wd[i])
		else if (hm == "item") add(wd[i], key)
		else if (hm == "" && !toplevel++) bad("tags: " wd[i] ": before any header, skipped")
	}
}
END {
	if (mode == "query") {
		np = split(tolower(q), parts, "+")
		for (p = 1; p <= np; p++) {
			if (!(parts[p] in known)) { warn("@" q ": no tag " parts[p] " in the tags file"); exit }
			set_of(parts[p])
		}
		for (j = 1; j <= n; j++) {
			all = 1
			for (p = 1; p <= np; p++) if (!((parts[p], j) in S)) { all = 0; break }
			if (all) print ipath[j] "\t" imap[j]
		}
	} else if (mode == "match") {
		for (j = 1; j <= n; j++) if (matches(q, j)) print ipath[j] "\t" imap[j]
	} else if (mode == "check") {
		for (t in nmem) for (i = 1; i <= nmem[t]; i++) {
			m = mem[t, i]
			if (m ~ /^@/) {
				if (!(tolower(substr(m, 2)) in known)) warn("tags: " where[t, i] ": " m ": no such tag")
				continue
			}
			hit = 0
			for (j = 1; j <= n; j++) if (matches(m, j)) { hit = 1; break }
			if (!hit) warn("tags: " where[t, i] ": " m ": no pack or map by that name in packs/")
		}
	} else if (mode == "list") {
		for (x = 1; x <= nt; x++) {
			t = torder[x]
			set_of(t)
			# Each name once, with the pack it is in when that is named otherwise, wrapped
			k = 0
			line = "  "
			for (j = 1; j <= n; j++) {
				if (!((t, j) in S)) continue
				w = imap[j] != "" ? imap[j] : iname[j]
				b = irel[j]
				sub(/.*\//, "", b)
				if (b != w) w = w " (" irel[j] ")"
				k++
				if (length(line) > 2 && length(line) + length(w) + 2 > 88) { body = body line "\n"; line = "  " }
				line = line (length(line) > 2 ? "  " : "") w
			}
			print t " (" k "):" (k ? "\n" body line : " nothing")
			body = ""
		}
	}
}
