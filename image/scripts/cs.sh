#!/bin/sh
# What you run in the container:
#
#   podman exec <container> cs <command>
#
#   reload [--now]       link the packs again after editing data/packlist or the tags file:
#                        maps, plugins, FastDL, the map cycle. New maps and plugins work from
#                        the next map change; --now restarts the current map for that
#   tags                 every tag in the tags file and what has it, and names that match
#                        nothing
#   save [-r] [-t tags] <URL> [dir]
#                        download a map or plugin into packs/ (packs/maps, packs/plugins,
#                        or dir), its URL in the zip's comment. Alone: the packlists'
#                        downloads, which can be saved by name
#                        -t snow,xmas  add it to these tags in the tags file. Without -t,
#                                      podman exec -it shows a picker; -t '' for none
#                        -r            then reload, so a map the packlist picks (by name,
#                                      pattern or tag) works now: cs console changelevel <map>
#   console <command>    send a command to the server's console; its output is in the
#                        container's logs (podman logs <container>)

FIFO=/tmp/server.in
PACKS=/opt/hlds/packs.sh
GAME=/opt/hlds/cstrike

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2; }
say() { echo "[cs] $*" >&2; }

console() {
	if [ ! -p "$FIFO" ]; then
		echo "cs: the server isn't running ($FIFO is missing)" >&2
		return 1
	fi
	printf '%s\n' "$*" >"$FIFO"
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

	# Tags: from -t, or picked on a terminal
	if [ -n "$ask" ]; then
		if [ -t 0 ] && [ -t 2 ]; then
			# shellcheck disable=SC2046 # one tag per word
			tags=$(/opt/hlds/tagpick.sh "$name" $("$PACKS" tagnames)) || tags=
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
	"$PACKS" || exit
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
		say "nothing from packs/$rel is in use: data/packlist doesn't pick it (by name, a"
		say "  pattern or a tag), or other packs have its files. Add it, then cs reload"
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
	"$PACKS" || exit
	if [ -n "$now" ]; then
		echo "[cs] restarting the map" >&2
		console restart
	fi
	;;
tags) exec "$PACKS" tags ;;
save) save "$@" ;;
console)
	[ $# -gt 0 ] || { usage && exit 1; }
	console "$@"
	;;
help | -h | --help) usage ;;
*)
	echo "cs: no command $cmd" >&2
	usage
	exit 1
	;;
esac
