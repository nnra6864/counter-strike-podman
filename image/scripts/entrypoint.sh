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

# Maps and other packs (data/packlist), linked into cstrike. Before env-config.sh: a pack
# can bring plugins
/opt/hlds/packs.sh || echo "[packs] failed, starting with the maps cstrike has"
# The map cycle from the packs (MAPCYCLE). Set even while it's empty, so `packs` can fill
# it later
case $(printf %s "${MAPCYCLE:-1}" | tr '[:upper:]' '[:lower:]') in
1 | on | true | yes | enable | enabled)
	: "${CVAR_MAPCYCLEFILE:=packs_mapcycle.txt}"
	export CVAR_MAPCYCLEFILE
	;;
esac
# Players download the packs' files from FASTDL_URL (fastdl/<name>/ in the library)
if [ -n "${FASTDL_URL:-}" ]; then
	: "${CVAR_SV_DOWNLOADURL:=${FASTDL_URL%/}/}"
	export CVAR_SV_DOWNLOADURL
fi

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
# A starting map the packs left out: the first one in the cycle, or any there is
if [ -n "$map" ] && [ ! -e "/opt/hlds/cstrike/maps/$map.bsp" ]; then
	first=$(head -n 1 /opt/hlds/cstrike/packs_mapcycle.txt 2>/dev/null) || true
	[ -n "$first" ] || first=$(ls /opt/hlds/cstrike/maps 2>/dev/null | sed -n 's/\.bsp$//p' | head -n 1)
	if [ -n "$first" ]; then
		echo "[packs] warning: no map $map (MAP), starting on $first"
		map=$first
	fi
fi
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
