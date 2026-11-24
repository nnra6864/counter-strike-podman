#!/bin/sh
set -e

# Everything the container prints also goes to /tmp/console.log, for `cs console` (the
# reply to a command) and `cs log`: podman logs has only what journald still keeps. tee
# ignores TERM and INT, so it outlives HLTV finishing its demo on stop
LOG=/tmp/console.log
rm -f "$LOG.in" && mkfifo "$LOG.in"
(
	trap '' TERM INT
	exec tee -a "$LOG" <"$LOG.in"
) &
exec >"$LOG.in" 2>&1
rm -f "$LOG.in"
# Kept to its last 2 MB once it passes 8 MB. In place: tee appends, so it carries on at the end
(
	trap - TERM INT
	while sleep 600; do
		[ "$(stat -c %s "$LOG")" -gt 8000000 ] || continue
		tail -c 2000000 "$LOG" >"$LOG.old" && cat "$LOG.old" >"$LOG" && rm -f "$LOG.old"
	done
) &

# A new volume. Not just "empty": a mount inside it (cstrike/demos) makes it non-empty.
# -n keeps anything already there
if [ ! -e /opt/hlds/cstrike/liblist.gam ]; then
	echo "Initializing cstrike directory"
	cp -a -n /opt/hlds/cstrike_defaults/. /opt/hlds/cstrike/
fi

# Sourced: puts the components in place, and sets the ENABLE_ defaults and on()
. /opt/hlds/components.sh

# Maps and other packs (data/packlist), linked into cstrike. Before env-config.sh: a pack
# can bring plugins
/opt/hlds/packs.sh || echo "[packs] failed, starting with the maps cstrike has"
# Again, now that the files it looks at are there: what env-config.sh gets from the settings
. /opt/hlds/settings.sh
/opt/hlds/env-config.sh || echo "[env] failed to apply env vars, starting with configs as they are"

hltv=
if on "$ENABLE_HLTV"; then
	/opt/hlds/hltv.sh &
	hltv=$!
fi

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
# The map cycle from the packs (settings.sh) from the start too: env-config.sh puts it in
# amxx.cfg, which runs after the plugins start, and nextmap.amxx reads it as it starts
if [ -n "${CVAR_MAPCYCLEFILE:-}" ]; then set -- "$@" +mapcyclefile "$CVAR_MAPCYCLEFILE"; fi
if [ -n "$maxplayers" ]; then set -- "$@" +maxplayers "$maxplayers"; fi
if [ -n "$map" ]; then set -- "$@" +map "$map"; fi

# The server's console reads a FIFO, so `cs console <command>` can send it commands. Held
# open read-write here, so it never sees EOF. What's typed on the attached console
# (podman attach) is passed on to it
FIFO=/tmp/server.in
rm -f "$FIFO" && mkfifo "$FIFO"
exec 3<>"$FIFO"
set +e
# A background command's stdin would be /dev/null: hand it the console as another fd
exec 4<&0
cat <&4 >&3 4<&- &
exec 4<&-
# Its output through a pipe too: with stdin a FIFO and stdout the terminal, HLDS crashes on
# start (segfault after the first map loads)
OUT=/tmp/server.out
rm -f "$OUT" && mkfifo "$OUT"
cat "$OUT" &
"$@" <&3 >"$OUT" 2>&1 &
server=$!
# On stop, HLTV finishes its demo before the server goes, or the demo is left without its
# directory
stopping=
stop() {
	[ -n "$stopping" ] && return
	stopping=1
	if [ -n "$hltv" ]; then
		kill -TERM "$hltv" 2>/dev/null
		wait "$hltv"
	fi
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
