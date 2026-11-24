#!/bin/sh
# What you run in the container:
#
#   podman exec <container> cs <command>
#
#   (none)               on a terminal (podman exec -it, or ./server on the host): the server's
#                        console, with tab completion (commands, cvars, maps), history
#                        and line editing. cs <command> runs these; exit or ctrl-d leaves
#                        (quit too: it doesn't stop the server in here)
#   reload [--now] [-v]  link the packs again after editing data/packlist or the tags file:
#                        maps, plugins, FastDL, the map cycle, and apply the environment to
#                        the configs again. New maps and plugins work from the next map
#                        change; --now restarts the current map for that. -v: a line
#                        for each pack
#   tags                 every tag in the tags file and what has it, and names that match
#                        nothing
#   save [-r] [-t tags] <URL> [dir]
#                        download a map or plugin into packs/ (packs/maps, packs/plugins,
#                        or dir), its URL in the zip's comment. Alone: the packlists'
#                        downloads, which can be saved by name
#                        -t snow,xmas  add it to these tags in the tags file. Without -t,
#                                      podman exec -it shows a picker, the tags the
#                                      autotags file gives it ticked (without a
#                                      terminal, those are used); -t '' for none
#                        -r            then reload, so a map the packlist picks (by name,
#                                      pattern or tag) works now: cs console changelevel <map>
#   remove [-r] [-y] <pack or map>
#                        delete a pack from packs/, and its name and its maps' from the tags
#                        file. Says what goes and asks first (podman exec -it), or -y.
#                        -r: then reload, so this server drops it now
#   maps                 what this server has from the packs: the map cycle, and the
#                        plugins in plugins.ini
#   console <command>    send a command to the server's console, and print its reply
#   log [-f] [lines]     the last lines the container printed (100), -f to follow

FIFO=/tmp/server.in
LOG=/tmp/console.log
# Words for tab completion (cs words), and the shell's history, kept with the server's data
WORDS=/tmp/cs-words
HIST=/opt/hlds/data/.cs_history
PACKS=/opt/hlds/packs.sh
GAME=/opt/hlds/cstrike

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2; }
say() { echo "[cs] $*" >&2; }
# A command used wrong: what's wrong, not the whole help
bad() {
	echo "cs: $*" >&2
	echo "cs help: what each command takes" >&2
	exit 1
}

console() {
	if [ ! -p "$FIFO" ]; then
		echo "cs: the server isn't running ($FIFO is missing)" >&2
		return 1
	fi
	from=$(stat -c %s "$LOG" 2>/dev/null) || from=
	printf '%s\n' "$*" >"$FIFO"
	[ -n "$from" ] || return 0
	# The reply: what the log gets until it's quiet for half a second, 5 s at most
	last=$from quiet=0 i=0
	while [ $i -lt 50 ] && [ $quiet -lt 5 ]; do
		sleep 0.1
		now=$(stat -c %s "$LOG") || break
		if [ "$now" = "$last" ]; then quiet=$((quiet + 1)); else quiet=0 last=$now; fi
		i=$((i + 1))
	done
	# Trimmed meanwhile: then it's somewhere in the last part
	[ "$last" -ge "$from" ] || from=0
	tail -c +$((from + 1)) "$LOG" | head -c $((last - from)) | tr -d '\r'
}

# The packs, then the environment, as on a start: a new pack plugin gets its
# AMXX_PLUGIN_<NAME>, a config just copied from a pack its CVAR_s. settings.sh first, so
# env-config.sh doesn't undo what the entrypoint derived (the map cycle, FastDL's URL)
reload_all() {
	"$PACKS" || return
	(. /opt/hlds/settings.sh && /opt/hlds/env-config.sh)
}

save() {
	reload='' tags='' ask=1 url='' dir=''
	while [ $# -gt 0 ]; do
		case $1 in
		-r | --reload) reload=1 ;;
		-t | --tags)
			[ $# -gt 1 ] || bad "-t needs the tags: -t snow,xmas, or -t '' for none. Without -t, a terminal gets a picker"
			shift
			tags="$tags $1" ask=
			;;
		--tags=*) tags="$tags ${1#--tags=}" ask= ;;
		-t*) tags="$tags ${1#-t}" ask= ;;
		-*) bad "save: no option $1" ;;
		*)
			if [ -z "$url" ]; then
				url=$1
			elif [ -z "$dir" ]; then
				dir=$1
			else
				bad "save: a URL and a dir at most, $1 is one more"
			fi
			;;
		esac
		shift
	done
	# Alone: the downloads that can be saved
	[ -n "$url" ] || exec "$PACKS" save

	got=$("$PACKS" save "$url" ${dir:+"$dir"}) || exit
	name=$(printf '%s\n' "$got" | cut -f 1)
	rel=$(printf '%s\n' "$got" | cut -f 2)

	# Tags: from -t, or picked on a terminal starting from the autotags file's, or those
	if [ -n "$ask" ]; then
		auto=$("$PACKS" autotags "$name" "$rel" | tr '\n' ' ')
		if [ -t 0 ] && [ -t 2 ]; then
			# shellcheck disable=SC2046 # one tag per word
			tags=$(/opt/hlds/pick.sh --multi -p "$auto" "Tags for $name" $({
				"$PACKS" tagnames
				[ -z "$auto" ] || printf '%s\n' $auto
			} | sort -u)) || tags=
		elif [ -n "$auto" ]; then
			tags=$auto
			say "tagging it as the autotags file says: ${auto% }. cs save -t <tag,...> for others,"
			say "  -t '' for none, or podman exec -it for a picker"
		else
			say "not tagged: cs save -t <tag,...>, or podman exec -it for a picker"
		fi
	fi
	set -f
	# shellcheck disable=SC2046 # one tag per word
	set -- $(printf '%s\n' "$tags" | tr ',' ' ')
	set +f
	if [ $# -gt 0 ]; then
		"$PACKS" tag "$name" "$@" || exit
	fi

	[ -n "$reload" ] || return 0
	reload_all || exit
	# Did the packlist pick it: links into the pack (its dir, or its unpacked copy)
	used='' maps=''
	while IFS= read -r r; do
		case $(readlink "$GAME/$r") in
		*/packs/"$rel"/*)
			used=1
			case $r in maps/*.bsp) m=${r#maps/} && maps="$maps ${m%.bsp}" ;; esac
			;;
		esac
	done <"$GAME/packs_links.txt"
	if [ -n "$maps" ]; then
		for m in $maps; do
			say "$m works now: cs console changelevel $m"
		done
	elif [ -n "$used" ]; then
		say "$name is in; its plugins load with the next map (cs reload --now restarts it)"
	else
		say "nothing from packs/$rel is in use: the packlist doesn't pick it (by name, a"
		say "  pattern or a tag), or other packs have its files. Add it, then cs reload"
	fi
}

remove() {
	reload='' yes='' what=''
	while [ $# -gt 0 ]; do
		case $1 in
		-r | --reload) reload=1 ;;
		-y | --yes) yes=1 ;;
		-*) bad "remove: no option $1" ;;
		*) [ -z "$what" ] && what=$1 || bad "remove: one pack or map at a time" ;;
		esac
		shift
	done
	[ -n "$what" ] || bad "remove: which pack or map?"
	if [ -z "$yes" ]; then
		"$PACKS" remove --dry "$what" || exit
		if [ ! -t 0 ]; then
			say "nothing removed: podman exec -it to be asked, or cs remove -y $what"
			exit 1
		fi
		printf '[cs] remove it? [y/N] ' >&2
		read -r answer || answer=
		case $answer in
		y | Y | yes) ;;
		*) say "nothing removed" && exit 1 ;;
		esac
	fi
	"$PACKS" remove "$what" || exit
	if [ -n "$reload" ]; then
		reload_all || exit
	else
		say "this server has it until cs reload"
	fi
}

# cs words: the words tab completes: ours, the maps, and the server's commands and cvars
# (names only: cvarlist has their values, rcon_password's too)
words() {
	{
		printf '%s\n' cs reload save remove tags maps help exit
		ls "$GAME/maps" 2>/dev/null | sed -n 's/\.bsp$//p'
		console 'cmdlist; cvarlist' 2>/dev/null | tr -d '\r' | awk '
			/^-+$/ || /^Command List/ || /Total (Commands|CVars)/ || /^CvarList/ { next }
			/ : / { print $1; next }
			NF == 1 && /^[A-Za-z_][A-Za-z0-9_+.-]*$/ { print }'
	} | sort -u >"$WORDS.tmp" && mv "$WORDS.tmp" "$WORDS"
}

# The interactive console: rlwrap gives the line editing, history and completion, and runs
# cs shell-inner, which sends each line to the server and shows what the server prints
shell() {
	[ -p "$FIFO" ] || { echo "cs: the server isn't running ($FIFO is missing)" >&2 && exit 1; }
	command -v rlwrap >/dev/null || { echo "cs: no rlwrap in this image: rebuild it" >&2 && exit 1; }
	words
	say "the server's console: tab completes, up/down for history, cs <command> for ours"
	say "  (cs help), exit or ctrl-d to leave"
	# A fresh pty (podman exec -it) can say it's 0 wide, which rlwrap refuses
	case $(stty size 2>/dev/null) in '' | 0\ * | *\ 0) stty rows 24 cols 80 2>/dev/null ;; esac
	# Word breaks without - and +: they're in map names and commands. -b before -f.
	# -n: no warning when a picker takes single keys
	exec rlwrap -n -i -b "(){}[],'=&^%\$#@\"\\;:" -f "$WORDS" -H "$HIST" -s 2000 -S 'cs> ' "$0" shell-inner
}

shell_inner() {
	# What the server prints from now on, as it prints it
	tail -n 0 -F "$LOG" 2>/dev/null &
	t=$!
	trap 'kill $t 2>/dev/null' EXIT
	while IFS= read -r line; do
		set -f
		# shellcheck disable=SC2086 # split into words
		set -- $line
		set +f
		case ${1:-} in
		'') ;;
		exit | quit | logout) break ;;
		cs)
			shift
			case ${1:-} in
			console) shift && printf '%s\n' "$*" >"$FIFO" ;;
			'' | shell | log) say "not in here: cs help for the rest" ;;
			*) "$0" "$@" ;;
			esac
			;;
		*) printf '%s\n' "$line" >"$FIFO" ;;
		esac
	done
}

if [ $# = 0 ]; then
	if [ -t 0 ] && [ -t 1 ]; then shell; fi
	usage
	exit 0
fi
cmd=$1
shift
case $cmd in
reload)
	now=
	for a; do
		case $a in
		--now) now=1 ;;
		-v) export PACKS_VERBOSE=1 ;;
		*) bad "reload: no option $a" ;;
		esac
	done
	reload_all || exit
	if [ -n "$now" ]; then
		echo "[cs] restarting the map" >&2
		console restart
	fi
	;;
tags) exec "$PACKS" tags ;;
save) save "$@" ;;
remove) remove "$@" ;;
console)
	[ $# -gt 0 ] || bad "console: which command?"
	console "$@"
	;;
maps)
	if [ -f "$GAME/packs_mapcycle.txt" ]; then
		echo "map cycle (packs_mapcycle.txt, $(grep -c . "$GAME/packs_mapcycle.txt") maps):"
		grep . "$GAME/packs_mapcycle.txt" | sed 's/^/  /'
	else
		echo "map cycle: mapcycle.txt (MAPCYCLE=0)"
	fi
	echo "plugins from the packs (addons/amxmodx/configs/plugins.ini):"
	sed -n '/^; packs: the plugins/,/^; packs: end/{/^; packs:/d;/^; env-managed:/d;s/^/  /;p}' \
		"$GAME/addons/amxmodx/configs/plugins.ini" 2>/dev/null | grep . || echo "  none"
	;;
log)
	[ -f "$LOG" ] || { echo "cs: no $LOG (the container started before it was kept)" >&2 && exit 1; }
	follow=
	[ "${1:-}" = -f ] && follow=1 && shift
	case ${1:-100} in *[!0-9]*) bad "log: [-f] [lines]" ;; esac
	if [ -n "$follow" ]; then exec tail -n "${1:-100}" -f "$LOG"; fi
	tail -n "${1:-100}" "$LOG" | tr -d '\r'
	;;
shell) shell ;;
shell-inner) shell_inner ;;
words) words && cat "$WORDS" ;;
help | -h | --help) usage ;;
*)
	bad "no command $cmd"
	;;
esac
