# Rewrites HLDS/AMXX/Metamod config files from environment variables.
# Driven by env-config.sh, which passes:
#   mode     cvar | kv | list | mm
#   prefix   env var prefix, e.g. CVAR_
#   cc       comment marker for the file type ("//" or ";")
#   ext      list mode: file extension of entries (".amxx" for plugins, "" for modules)
#   tmpdir   where the rewritten copies go (one per input file, named by argv index)
#   fallback file that receives settings not found anywhere else ("" = don't append)
#   show     1 = only list what is customizable, change nothing
#
# Every change is reversible. A replaced line is kept, commented, as
#   <cc> env-original: <line>
# and each line written from the environment follows a marker line
#   <cc> env-managed: <VAR>
# Each run first undoes the previous run's changes, so removing a variable
# restores the file as it was.

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function falsy(v)  { v = tolower(trim(v)); return v ~ /^(0|off|false|no|disabled?)$/ }
function truthy(v) { v = tolower(trim(v)); return v ~ /^(1|on|true|yes|enabled?)$/ }
function firsttok(s) { s = trim(s); if (match(s, /^[^ \t]+/)) return substr(s, 1, RLENGTH); return "" }
function say(msg) { print "[env] " msg > "/dev/stderr" }

# Returns the setting this line defines (lowercased), or "" if none.
# Sets cur_name / cur_path / cur_on / cur_val as a side effect.
function keyof(line,    t, tok, n, f, base) {
	t = trim(line)
	cur_on = 1; cur_val = ""
	if (mode == "cvar" || mode == "kv") {
		if (t ~ /^(\/\/|#|;)/) return ""
		tok = firsttok(t)
		cur_val = trim(substr(t, length(tok) + 1))
		gsub(/"/, "", tok)
		if (mode == "cvar" && (tok !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || tolower(tok) ~ NOTCVAR)) return ""
		return tolower(tok)
	}
	if (mode == "list") {
		# "name.amxx [debug]" or ";name.amxx" (commented entry: exactly one ';', no space)
		if (t ~ /^;[^; \t]/) { cur_on = 0; t = substr(t, 2) }
		else if (t ~ /^;/) return ""
		tok = firsttok(t)
		if (tok == "") return ""
		if (ext != "") {
			if (tolower(substr(tok, length(tok) - length(ext) + 1)) != ext) return ""
			tok = substr(tok, 1, length(tok) - length(ext))
		}
		cur_name = tok
		cur_val = trim(substr(t, length(tok ext) + 1))
		sub(/[ \t]*;.*$/, "", cur_val)
		return tolower(tok)
	}
	if (mode == "mm") {
		# "linux addons/x/x_mm_i386.so", possibly commented out with // # ;
		if (t ~ /^(\/\/|#|;)/) { cur_on = 0; sub(/^(\/\/|#|;)[ \t]*/, "", t) }
		n = split(t, f, /[ \t]+/)
		if (n < 2 || f[1] != "linux") return ""
		cur_path = f[2]
		base = f[2]; sub(/^.*\//, "", base)
		sub(/(_mm)?(_i386)?\.so$/, "", base)
		return tolower(base)
	}
	return ""
}

function quote(v) { return (index(v, "\"") ? v : "\"" v "\"") }

# Writes the managed line(s) for setting k into file o. Returns 1 if written.
function emit(k, o, where, found,    v, n, parts, i, line, nm) {
	v = want[k]
	if (mode == "cvar") {
		n = split(v, parts, "\n")
		if (n == 0) { n = 1; parts[1] = "" }
		for (i = 1; i <= n; i++) {
			print M var[k] > o
			print k " " quote(parts[i]) > o
		}
		say(var[k] " -> " where)
		return 1
	}
	if (mode == "kv") {
		sub(/\n.*/, "", v)
		print M var[k] > o
		print k " " v > o
		say(var[k] " -> " where)
		return 1
	}
	if (mode == "list") {
		nm = (k in name) ? name[k] : ((k in avail) ? avail[k] : k)
		if (falsy(v)) { if (!found) return 0; line = ";" nm ext }
		else if (truthy(v)) line = nm ext
		else line = nm ext " " v
		if (!found && ext != "" && !(k in avail)) say("warning: " var[k] ": no " nm ext " in the plugins dir")
		print M var[k] > o
		print line > o
		say(var[k] " -> " where ": " line)
		return 1
	}
	if (mode == "mm") {
		if (falsy(v)) { if (!found) return 0; line = cc " linux " mmpath[k] }
		else if (truthy(v)) {
			if (!found) { say("warning: " var[k] "=" v ": no such metamod plugin, give a path instead"); return 0 }
			line = "linux " mmpath[k]
		}
		else line = "linux " v
		print M var[k] > o
		print line > o
		say(var[k] " -> " where ": " line)
		return 1
	}
}

BEGIN {
	# Console commands that show up in cfgs but aren't settings
	NOTCVAR = "^(echo|exec|alias|bind|say|wait|map|changelevel|banid|addip|removeid|removeip|writeid|writeip|meta)$"
	M = cc " env-managed: "
	O = cc " env-original: "
	for (e in ENVIRON)
		if (index(e, prefix) == 1 && length(e) > length(prefix)) {
			k = tolower(substr(e, length(prefix) + 1))
			want[k] = ENVIRON[e]; var[k] = e
		}
	if (navail = split(availlist, a, "|"))
		for (i = 1; i <= navail; i++) if (a[i] != "") avail[tolower(a[i])] = a[i]
	if (!show)
		for (i = 1; i < ARGC; i++) { out[ARGV[i]] = tmpdir "/" i; printf "" > out[ARGV[i]] }
}

FNR == 1 { skip = 0 }

show {
	if (index($0, M) == 1 || index($0, O) == 1) next
	k = keyof($0)
	if (k == "" || (mode != "list" && mode != "mm" && !cur_on)) next
	if ((k in seen)) next
	seen[k] = 1
	if (mode == "list") st = cur_on ? "enabled" : "disabled"
	else if (mode == "mm") st = (cur_on ? "enabled " : "disabled ") cur_path
	else st = cur_val
	printf "%s%s\t%s\t%s\n", prefix, toupper(k), FILENAME, st
	next
}

{
	line = $0
	if (index(line, M) == 1) { skip = 1; next }   # marker: drop it and the managed line after it
	if (skip) { skip = 0; next }
	if (index(line, O) == 1) line = substr(line, length(O) + 1)
	k = keyof(line)
	if (k != "" && (k in want)) {
		if (mode == "list") name[k] = cur_name
		if (mode == "mm") mmpath[k] = cur_path
		print O line > out[FILENAME]
		if (!((FILENAME, k) in done)) {
			done[FILENAME, k] = 1
			found[k] = 1
			emit(k, out[FILENAME], FILENAME, 1)
		}
	} else
		print line > out[FILENAME]
}

END {
	if (show) {
		if (mode == "list" && ext != "")
			for (k in avail) if (!(k in seen)) printf "%s%s\t%s\t%s\n", prefix, toupper(k), "(plugins dir)", "not listed"
		exit
	}
	for (k in want) if (!(k in found)) {
		if (fallback == "") { say("warning: " var[k] ": not found in any file, ignored"); continue }
		if (!emit(k, out[fallback], fallback " (appended)", 0)) say(var[k] ": nothing to disable")
	}
}
