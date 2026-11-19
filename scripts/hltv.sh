#!/bin/sh
# Runs the HLTV proxy next to the server and restarts it when it exits.
# Started in the background by the entrypoint when ENABLE_HLTV is on.
#
#   HLTV_SERVER=127.0.0.1:27015   server to connect to
#   HLTV_PORT=27020               HLTV's own port (not published by default)
#   HLTV_RECORD=demos/hltv        demo name, recorded as <name>-<date>-<map>.dem
#                                 relative to cstrike/, one file per map. Empty = off
#   RECORD_IDLE_STOP=120          record only while players are on: start when someone
#                                 connects, stop after this many seconds with nobody on.
#                                 0 = record all the time. Needs the hltv_tools plugin
#   DELETE_EMPTY_DEMOS, ENABLE_VOICE_MKA   what happens to finished demos (demos.sh)
#   HLTV_<CMD>=value              any other HLTV command, run as +<cmd> value
#                                 (HLTV_DELAY, HLTV_MAXCLIENTS, HLTV_NAME, HLTV_HOSTNAME, ...)
#
# HLTV takes one player slot on the server.

cd /opt/hlds || exit 1
export LD_LIBRARY_PATH=/opt/hlds:${LD_LIBRARY_PATH:-}

: "${HLTV_SERVER:=127.0.0.1:27015}" "${HLTV_PORT:=27020}" "${HLTV_RECORD=demos/hltv}"
# No live spectators by default: with ENABLE_HLTV_VOICE, HLTV hears both teams
: "${HLTV_MAXCLIENTS:=0}" "${HLTV_DELAY:=0}" "${HLTV_AUTORETRY:=1}"
: "${HLTV_NAME:=HLTV}"
export HLTV_MAXCLIENTS HLTV_DELAY HLTV_AUTORETRY HLTV_NAME
# The server's password, so HLTV can join a private server
if [ -z "${HLTV_SERVERPASSWORD:-}" ] && [ -n "${CVAR_SV_PASSWORD:-}" ]; then
	export HLTV_SERVERPASSWORD="$CVAR_SV_PASSWORD"
fi

: "${RECORD_IDLE_STOP:=120}"
on() {
	case $(printf %s "${1:-}" | tr '[:upper:]' '[:lower:]') in
	1 | on | true | yes | enable | enabled) return 0 ;;
	esac
	return 1
}
# Our 64-bit tool, without HLDS's 32-bit libraries
tool() { env -u LD_LIBRARY_PATH goldsrc-demo-tools "$@"; }

quote() { case $1 in *[[:space:]]*) printf '"%s"' "$1" ;; *) printf %s "$1" ;; esac; }

# Commands go through the console, not the command line: +commands on the command line
# were sometimes skipped (HLTV came up unconnected, with its default settings)
CMDS=""
add() { CMDS="$CMDS$*
"; }
for name in $(env | sed -n 's/^HLTV_\([A-Za-z0-9_]*\)=.*/\1/p' | sort -u); do
	case $name in SERVER | PORT | RECORD) continue ;; esac
	eval "value=\${HLTV_$name}"
	# shellcheck disable=SC2154 # set by eval
	add "$(echo "$name" | tr '[:upper:]' '[:lower:]')" "$(quote "$value")"
done
DEMO_DIR=cstrike/$(dirname "$HLTV_RECORD")
DEMO_NAME=$(basename "$HLTV_RECORD")
if [ -n "$HLTV_RECORD" ]; then
	mkdir -p "$DEMO_DIR"
	[ "$RECORD_IDLE_STOP" = 0 ] && add record "$HLTV_RECORD"
	# Finished demos: deleted if nobody joined, else a .mka of their voice
	if on "${DELETE_EMPTY_DEMOS:-1}" || on "${ENABLE_VOICE_MKA:-1}"; then
		/opt/hlds/demos.sh "$DEMO_DIR" "$DEMO_NAME" &
	fi
fi
add connect "$HLTV_SERVER"

# HLTV's console reads this FIFO. Held open read-write here, so it never sees EOF.
# Send commands with: podman exec <container> sh -c 'echo status > /tmp/hltv.in'
FIFO=/tmp/hltv.in
rm -f "$FIFO" && mkfifo "$FIFO"
exec 3<>"$FIFO"

# Demos a crash or kill left unfinished (directory offset 0 in the header). Only while
# HLTV isn't running, since the demo being recorded looks the same
repair_unfinished() {
	[ -n "$HLTV_RECORD" ] || return 0
	for f in "$DEMO_DIR/$DEMO_NAME"-*.dem; do
		[ -f "$f" ] || continue
		[ "$(od -An -t d4 -j 540 -N 4 "$f" | tr -d ' ')" = 0 ] || continue
		echo "[hltv] $(basename "$f") was never finished (crash or kill), repairing it"
		tool repair "$f" 2>&1 | sed 's/^/[hltv]   /'
	done
}

# Records only while players are on, from the count the hltv_tools plugin writes. One per
# HLTV run: a new HLTV starts without recording
PLAYERS_FILE=cstrike/addons/amxmodx/data/hltv_tools_players.txt
watch_players() {
	trap - TERM
	recording=
	started=$(date +%s)
	last_seen=$started
	while sleep 5; do
		now=$(date +%s)
		n=$(cat "$PLAYERS_FILE" 2>/dev/null)
		case $n in
		'' | *[!0-9]*)
			# No count: without the plugin, record all the time rather than never
			if [ -z "$recording" ] && [ $((now - started)) -ge 60 ]; then
				echo "[hltv] no player count from the hltv_tools plugin: recording all the time"
				printf 'record %s\n' "$(quote "$HLTV_RECORD")" >&3
				recording=1
			fi
			continue
			;;
		esac
		if [ "$n" -gt 0 ]; then
			last_seen=$now
			if [ -z "$recording" ]; then
				echo "[hltv] $n player(s) on: recording"
				printf 'record %s\n' "$(quote "$HLTV_RECORD")" >&3
				recording=1
			fi
		elif [ -n "$recording" ] && [ $((now - last_seen)) -ge "$RECORD_IDLE_STOP" ]; then
			echo "[hltv] nobody on for ${RECORD_IDLE_STOP}s: stopping the recording"
			printf 'stoprecording\n' >&3
			recording=
		fi
	done
}

# The entrypoint sends TERM on stop: HLTV finishes its demo (writes the directory) and quits.
# Ctrl+C on the attached console is meant for the server: HLTV ignores it
stopping=
watcher=
stop() {
	stopping=1
	[ -n "$watcher" ] && kill "$watcher" 2>/dev/null
	echo "[hltv] stopping: finishing the demo"
	printf 'stoprecording\nquit\n' >&3
}
trap stop TERM
trap '' INT

# Give the server a head start, autoretry covers the rest
sleep 5 &
wait $!
while [ -z "$stopping" ]; do
	repair_unfinished
	echo "[hltv] starting on port $HLTV_PORT, commands:"
	printf '%s' "$CMDS" | sed 's/^/[hltv]   /'
	# Queued in the FIFO, read once the console is up
	printf '%s' "$CMDS" >&3
	# In the background: a trapped signal only interrupts `wait`, not a running command
	./hltv -port "$HLTV_PORT" <&3 2>&1 | sed -u 's/^/[hltv] /' &
	pid=$!
	if [ -n "$HLTV_RECORD" ] && [ "$RECORD_IDLE_STOP" != 0 ]; then
		# Only counts from this run
		rm -f "$PLAYERS_FILE"
		watch_players &
		watcher=$!
	fi
	wait $pid
	while kill -0 $pid 2>/dev/null; do wait $pid; done
	[ -n "$watcher" ] && kill "$watcher" 2>/dev/null
	watcher=
	[ -n "$stopping" ] && break
	echo "[hltv] exited, restarting in 10s"
	sleep 10 &
	wait $!
done
echo "[hltv] stopped"
