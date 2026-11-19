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
#   save <download> [dir]  keep a download in packs/ (packs/maps, packs/plugins, or dir),
#                        its URL in the zip's comment
#   console <command>    send a command to the server's console; its output is in the
#                        container's logs (podman logs <container>)

FIFO=/tmp/server.in

usage() { sed -n '2,16s/^# \{0,1\}//p' "$0" >&2; }

console() {
	if [ ! -p "$FIFO" ]; then
		echo "cs: the server isn't running ($FIFO is missing)" >&2
		return 1
	fi
	printf '%s\n' "$*" >"$FIFO"
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
	/opt/hlds/packs.sh || exit
	if [ -n "$now" ]; then
		echo "[cs] restarting the map" >&2
		console restart
	fi
	;;
tags) exec /opt/hlds/packs.sh tags ;;
save) exec /opt/hlds/packs.sh save "$@" ;;
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
