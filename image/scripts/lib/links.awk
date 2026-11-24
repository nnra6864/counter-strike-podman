# The links packs.sh makes: what each pack in packlist order gives cstrike, compared with
# what is there (see the Links part of packs.sh, which writes its inputs)
function say(m) { print "[packs] " m > "/dev/stderr" }
# A shell pattern as a regex, built once
function re(g,    r, i, j, c, n) {
	if (g in RE) return RE[g]
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
	return RE[g] = r "$"
}
function excluded(m,    i) {
	for (i = 1; i <= nx; i++) if (m ~ re(X[i])) { hit[X[i]] = 1; return 1 }
	return 0
}
# An empty filter has every map
function in_filter(m, f,    k, a, i) {
	if (f == "") return 1
	k = split(f, a, " ")
	for (i = 1; i <= k; i++) if (m ~ re(a[i])) return 1
	return 0
}
function base(r) { sub(/.*\//, "", r); return r }
# ../ for each dir in r
function up(r,    n, s) {
	n = gsub(/\//, "/", r)
	s = ""
	while (n-- > 0) s = s "../"
	return s
}
# Something of the server's own there: a file, or a link that isn't ours
function theirs(r) { return (r in real) || ((r in lt) && !(r in ours)) }

function dopack(i,    k, all, wanted, linked, maps, kept, out, dup, plugins, copied, r, src, top, map, b, plugin, tgt, msg) {
	if (XP[i]) { say(L[i] ": left out"); return }
	# A pack with maps, none of them wanted: none of its files either
	all = wanted = 0
	for (k = 1; k <= npm[i]; k++) {
		all++
		if (!excluded(PM[i, k]) && in_filter(PM[i, k], F[i])) wanted++
	}
	if (all > 0 && wanted == 0) { say(L[i] ": left out, none of its " all " maps are wanted"); return }
	linked = maps = kept = out = dup = plugins = copied = 0
	for (k = 1; k <= nf[i]; k++) {
		r = R[i, k]
		src = S[i, k]
		if (r ~ /^addons\/amxmodx\/scripting\//) continue
		if (r ~ /^addons\/amxmodx\// && !amxx_ok) { amxx_skipped = 1; continue }
		if (index(r, "/")) {
			top = r
			sub(/\/.*/, "", top)
			if (!index(content, " " top " ")) continue
		} else if (r !~ /\.(wad|WAD)$/) continue
		# A map's own files go with it
		map = ""
		if (r ~ /^(maps|overviews)\/.*\./) {
			b = base(r)
			sub(/\.[^.]*$/, "", b)
			sub(/_detail$/, "", b)
			if ((i, b) in hasmap) map = b
		}
		if (map != "" && (excluded(map) || !in_filter(map, F[i]))) {
			if (r == "maps/" map ".bsp") out++
			continue
		}
		# Configs are copied, once: each server changes its own, and CVAR_ writes into
		# them, which through a link would change the library's
		if (r ~ /^addons\/amxmodx\/configs\// || r ~ /\.(cfg|ini)$/) {
			if (!theirs(r) && !(r in copying)) {
				copying[r] = 1
				print src "\t" r > (T "/copy")
				copied++
			}
			continue
		}
		plugin = r ~ /^addons\/amxmodx\/plugins\/.*\.amxx$/ ? base(r) : ""
		if (r in W) { dup++; continue }
		if (theirs(r)) {
			kept++
			if (plugin != "") print plugin > (T "/plugins")
			continue
		}
		# Relative, so the link works on the host too (./cstrike next to ./data)
		tgt = src
		if (!shared && index(src, data "/") == 1) tgt = up(r) "../data/" substr(src, length(data) + 2)
		W[r] = tgt
		print r > (T "/links")
		# What players may download: not the default pack, they have it, and nothing of
		# the server's own (addons, configs)
		if (P[i] != default && r !~ /^addons\//) print src "\t" r > (T "/fastdl")
		linked++
		if (plugin != "") { plugins++; print plugin > (T "/plugins") }
		if (r == "maps/" map ".bsp") { maps++; LM[i, map] = 1 }
	}
	for (k = 1; k <= nc[i]; k++) if ((i, C[i, k]) in LM) print C[i, k] > (T "/maps")
	msg = L[i] ": " maps " maps, " linked " files"
	if (plugins) msg = msg ", " plugins " plugins"
	if (copied) msg = msg ", " copied " configs copied"
	if (out) msg = msg ", " out " maps left out"
	if (dup) msg = msg ", " dup " already from a pack before it"
	if (kept) msg = msg ", " kept " already in cstrike (kept those)"
	# A line per pack with -v, or when something about it is worth knowing
	if (verbose || kept || out) say(msg)
	npacks++; tmaps += maps; tfiles += linked; tplugins += plugins
}

FILENAME == T "/oldlinks" { ours[$0] = 1; next }
FILENAME == T "/scan" { if ($1 == "l") lt[$2] = $3; else real[$2] = 1; next }
FILENAME == T "/excludes" { if ($0 != "") X[++nx] = $0; next }
FILENAME == T "/packinfo" { np = $1; P[$1] = $2; F[$1] = $3; L[$1] = $4; XP[$1] = $5; next }
FILENAME == T "/cycles" { C[$1, ++nc[$1]] = $2; next }
# allfiles: the first of a path in a pack wins (a compiled plugin over its .amxx)
{
	i = $1
	if ((i, $2) in seen) next
	seen[i, $2] = 1
	R[i, ++nf[i]] = $2
	S[i, nf[i]] = $3
	if ($2 ~ /^maps\/[^\/]*\.bsp$/) {
		m = substr($2, 6, length($2) - 9)
		hasmap[i, m] = 1
		PM[i, ++npm[i]] = m
	}
}
END {
	for (i = 1; i <= np; i++) dopack(i)
	for (r in ours) if ((r in lt) && !(r in W)) { print r > (T "/rm"); gone++ }
	for (r in W) {
		if ((r in lt) && lt[r] == W[r]) same++
		else { print r "\t" W[r] > (T "/ln"); made++ }
	}
	for (g in hit) print g > (T "/xhit")
	if (amxx_skipped) say("warning: cstrike has no AMX Mod X (ENABLE_AMXMODX), the packs' plugins aren't used")
	say(npacks + 0 " packs: " tmaps + 0 " maps, " tfiles + 0 " files, " tplugins + 0 " plugins" (verbose ? "" : " (cs reload -v: each pack)"))
	if (made || gone) say("links: " made + 0 " made, " gone + 0 " taken down, " same + 0 " as they were")
}
