#!/bin/sh
set -e

# A new volume. Not just "empty": a mount inside it (cstrike/demos) makes it non-empty.
# -n keeps anything already there
if [ ! -e /opt/hlds/cstrike/liblist.gam ]; then
	echo "Initializing cstrike directory"
	cp -a -n /opt/hlds/cstrike_defaults/. /opt/hlds/cstrike/
fi

# Sourced: it sets defaults for env-config.sh
. /opt/hlds/components.sh

/opt/hlds/env-config.sh || echo "[env] failed to apply env vars, starting with configs as they are"

hltv=
case $(printf %s "$ENABLE_HLTV" | tr '[:upper:]' '[:lower:]') in
1 | on | true | yes | enable | enabled)
	/opt/hlds/hltv.sh &
	hltv=$!
	;;
esac

# +maxplayers and +map from MAXPLAYERS and MAP (presets set them), or else from the
# command. Put back in that order: once +map has started the server, maxplayers is refused
want=
for arg; do
	shift
	case $want in
	map) cmd_map=$arg want= && continue ;;
	maxplayers) cmd_maxplayers=$arg want= && continue ;;
	esac
	case $arg in
	+map) want=map && continue ;;
	+maxplayers) want=maxplayers && continue ;;
	esac
	set -- "$@" "$arg"
done
maxplayers=${MAXPLAYERS:-${cmd_maxplayers:-}}
map=${MAP:-${cmd_map:-}}
if [ -n "$maxplayers" ]; then set -- "$@" +maxplayers "$maxplayers"; fi
if [ -n "$map" ]; then set -- "$@" +map "$map"; fi

[ -n "$hltv" ] || exec "$@"

# With HLTV, stay around: on stop, HLTV finishes its demo before the server goes, or the
# demo is left without its directory. The server keeps the console (stdin, a background
# command would get /dev/null)
set +e
exec 3<&0
"$@" <&3 3<&- &
server=$!
exec 3<&-
stopping=
stop() {
	[ -n "$stopping" ] && return
	stopping=1
	kill -TERM "$hltv" 2>/dev/null
	wait "$hltv"
	kill -TERM "$server" 2>/dev/null
}
trap stop TERM INT
# wait returns early when a signal comes in; keep waiting until the server is gone
wait "$server"
status=$?
while kill -0 "$server" 2>/dev/null; do
	wait "$server"
	status=$?
done
# The server stopped on its own: stop HLTV too
stop
exit "$status"
