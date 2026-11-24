#!/bin/sh
# What you run in the container:
#
#   podman exec <container> cs <command>
#
#   reload [--now]       link the packs again after editing data/packlist or the tags file:
#                        maps, plugins, FastDL, the map cycle, and apply the environment to
#                        the configs again. New maps and plugins work from the next map
#                        change; --now restarts the current map for that
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
PACKS=/opt/hlds/packs.sh
GAME=/opt/hlds/cstrike

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2; }
say() { echo "[cs] $*" >&2; }

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
			[ $# -gt 1 ] || { usage && exit 1; }
			shift
			tags="$tags $1" ask=
			;;
		--tags=*) tags="$tags ${1#--tags=}" ask= ;;
		-t*) tags="$tags ${1#-t}" ask= ;;
		-*) usage && exit 1 ;;
		*)
			if [ -z "$url" ]; then
				url=$1
			elif [ -z "$dir" ]; then
				dir=$1
			else
				usage && exit 1
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
			tags=$(/opt/hlds/tagpick.sh -p "$auto" "$name" $({
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
		-*) usage && exit 1 ;;
		*) [ -z "$what" ] && what=$1 || { usage && exit 1; } ;;
		esac
		shift
	done
	[ -n "$what" ] || { usage && exit 1; }
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

cmd=${1:-help}
[ $# -gt 0 ] && shift
case $cmd in
reload)
	now=
	case ${1:-} in
	--now) now=1 ;;
	'') ;;
	*) usage && exit 1 ;;
	esac
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
	[ $# -gt 0 ] || { usage && exit 1; }
	console "$@"
	;;
maps)
	if [ -f "$GAME/packs_mapcycle.txt" ]; then
		echo "map cycle (packs_mapcycle.txt, $(grep -c . "$GAME/packs_mapcycle.txt") maps):"
		# In columns, in cycle order down each
		awk '{ m[NR] = $0; if (length($0) > w) w = length($0) }
			END {
				c = int(86 / (w + 2)); if (c < 1) c = 1
				r = int((NR + c - 1) / c)
				for (i = 1; i <= r; i++) {
					l = " "
					for (j = i; j <= NR; j += r) l = l sprintf(" %-" w "s", m[j])
					sub(/ +$/, "", l); print l
				}
			}' "$GAME/packs_mapcycle.txt"
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
	case ${1:-100} in *[!0-9]*) usage && exit 1 ;; esac
	if [ -n "$follow" ]; then exec tail -n "${1:-100}" -f "$LOG"; fi
	tail -n "${1:-100}" "$LOG" | tr -d '\r'
	;;
help | -h | --help) usage ;;
*)
	echo "cs: no command $cmd" >&2
	usage
	exit 1
	;;
esac
