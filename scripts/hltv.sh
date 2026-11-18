#!/bin/sh
# Runs the HLTV proxy next to the server and restarts it when it exits.
# Started in the background by the entrypoint when ENABLE_HLTV is on.
#
#   HLTV_SERVER=127.0.0.1:27015   server to connect to
#   HLTV_PORT=27020               HLTV's own port (not published by default)
#   HLTV_RECORD=demos/hltv        demo name, recorded as <name>-<date>-<map>.dem
#                                 relative to cstrike/, one file per map. Empty = off
#   ENABLE_VOICE_MKA=1            write each finished demo's voice to a .mka (voice.sh)
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
if [ -n "$HLTV_RECORD" ]; then
	mkdir -p "cstrike/$(dirname "$HLTV_RECORD")"
	add record "$HLTV_RECORD"
	# A .mka with a track per player next to each finished demo
	case $(printf %s "${ENABLE_VOICE_MKA:-1}" | tr '[:upper:]' '[:lower:]') in
	1 | on | true | yes | enable | enabled)
		/opt/hlds/voice.sh "cstrike/$(dirname "$HLTV_RECORD")" "$(basename "$HLTV_RECORD")" &
		;;
	esac
fi
add connect "$HLTV_SERVER"

# HLTV's console reads this FIFO. Held open read-write here, so it never sees EOF.
# Send commands with: podman exec <container> sh -c 'echo status > /tmp/hltv.in'
FIFO=/tmp/hltv.in
rm -f "$FIFO" && mkfifo "$FIFO"
exec 3<>"$FIFO"

# Give the server a head start, autoretry covers the rest
sleep 5
while :; do
	echo "[hltv] starting on port $HLTV_PORT, commands:"
	printf '%s' "$CMDS" | sed 's/^/[hltv]   /'
	# Queued in the FIFO, read once the console is up
	printf '%s' "$CMDS" >&3
	./hltv -port "$HLTV_PORT" <&3 2>&1 | sed -u 's/^/[hltv] /'
	echo "[hltv] exited, restarting in 10s"
	sleep 10
done
