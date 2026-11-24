# plugins.ini with the packs' plugins (file wantfile) between the "; packs:" lines (see
# packs.sh)
function name(l,    t) {
	t = l
	sub(/^[ \t]+/, "", t)
	if (index(t, "; env-original: ") == 1) t = substr(t, 17)
	if (t ~ /^;[^; \t]/) t = substr(t, 2)
	else if (t ~ /^;/) return ""
	sub(/[ \t].*$/, "", t)
	return tolower(t)
}
BEGIN {
	B = "; packs: the plugins from data/packlist, rewritten by packs"
	E = "; packs: end"
	while ((getline l < wantfile) > 0)
		if (l != "" && !(tolower(l) in want)) { want[tolower(l)] = 1; order[++n] = l }
}
$0 == B { inb = 1; seenb = 1; next }
$0 == E { inb = 0; next }
!inb { print; k = name($0); if (k != "") listed[k] = 1; next }
/^; env-managed: / { pend = pend $0 "\n"; next }
{ blk[++nb] = pend $0; bk[nb] = name($0); pend = "" }
END {
	if (n == 0) exit
	print B
	for (i = 1; i <= nb; i++)
		if ((bk[i] in want) && !(bk[i] in listed)) { print blk[i]; kept[bk[i]] = 1 }
	for (k in kept) have[k] = 1
	for (i = 1; i <= n; i++) {
		k = tolower(order[i])
		if (!(k in listed) && !(k in have)) { print order[i]; have[k] = 1 }
	}
	print E
}
