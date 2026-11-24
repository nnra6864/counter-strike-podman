#!/bin/sh
# Handles each demo HLTV has finished: deletes it if nobody joined, else writes a .mka of
# its voice chat next to it, with a track per player (goldsrc-demo-tools). Started in the
# background by hltv.sh when HLTV records.
#
#   demos.sh <dir> <name>    demos are <dir>/<name>-<date>-<map>.dem
#   DELETE_EMPTY_DEMOS=1     delete demos nobody joined (HLTV and bots don't count)
#   ENABLE_VOICE_MKA=1       write the .mka
#   VOICE_MKA_ARGS=""        its options: "--order team" (tracks T first, then CT),
#                            "--tracks team|mix", "--lenient"
#   DEMOS_POLL=15            seconds between looks at the demo dir
#
# A demo is finished once HLTV has written its directory (the header's directory offset
# isn't 0 any more): when recording stops, on map change, and on a clean stop. hltv.sh
# repairs those a crash left unfinished before it starts HLTV. Each demo is handled once;
# the names are kept in cstrike/hltv_demos_done.txt, outside the demo dir (demos no longer
# there leave it on the next start). A demo whose
# player count can't be trusted (parts couldn't be read) is kept, and the log says why.

DIR=$1
NAME=$2
POLL=${DEMOS_POLL:-15}
DONE=cstrike/hltv_demos_done.txt
# hltv.sh points this at HLDS's 32-bit libraries
unset LD_LIBRARY_PATH

say() { echo "[demos] $*"; }
. /opt/hlds/common.sh

finished() {
	[ "$(od -An -t d4 -j 540 -N 4 "$1" 2>/dev/null | tr -d ' ')" != 0 ]
}

handle() {
	b=$(basename "$1")
	if on "${DELETE_EMPTY_DEMOS:-1}"; then
		info=$(goldsrc-demo-tools info "$1" 2>/dev/null)
		code=$?
		players=$(printf '%s\n' "$info" | sed -n 's/^players //p')
		unidentified=$(printf '%s\n' "$info" | sed -n 's/^unidentified //p')
		if [ $code = 0 ] && [ "$players" = 0 ] && [ "$unidentified" = 0 ]; then
			duration=$(printf '%s\n' "$info" | sed -n 's/^duration //p')
			rm -f "$1" && say "$b: nobody joined (${duration}s), deleted"
			return
		fi
		[ $code = 0 ] || say "$b: parts couldn't be read (info exit $code), kept"
	fi
	if on "${ENABLE_VOICE_MKA:-1}" && [ ! -e "${1%.dem}.mka" ]; then
		say "$b"
		# shellcheck disable=SC2086 # VOICE_MKA_ARGS is a list of options
		out=$(nice goldsrc-demo-tools voice $VOICE_MKA_ARGS "$1" 2>&1)
		code=$?
		[ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/[demos]   /'
		case $code in
		0) ;;
		3) say "$b: parts of the demo could not be read (exit 3), see above" ;;
		*) say "$b: failed (exit $code)" ;;
		esac
	fi
}

touch "$DONE"
# Names of demos that are gone (deleted, moved) can go from the list
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ls "$DIR" >"$TMP/have" 2>/dev/null
if [ -s "$DONE" ] && awk -v h="$TMP/have" 'FILENAME == h { have[$0] = 1; next } !($0 in have) { gone = 1; exit } END { exit !gone }' "$TMP/have" "$DONE"; then
	awk -v h="$TMP/have" 'FILENAME == h { have[$0] = 1; next } $0 in have' "$TMP/have" "$DONE" >"$TMP/done"
	cat "$TMP/done" >"$DONE"
fi
while :; do
	# The ones not handled yet, in one go rather than a grep per demo. Names sort by date
	ls "$DIR" 2>/dev/null | awk -v p="$NAME-" -v d="$DONE" 'FILENAME == d { done[$0] = 1; next }
		index($0, p) == 1 && /\.dem$/ && !($0 in done)' "$DONE" - >"$TMP/new"
	while IFS= read -r b; do
		f=$DIR/$b
		[ -f "$f" ] && finished "$f" || continue
		handle "$f"
		printf '%s\n' "$b" >>"$DONE"
	done <"$TMP/new"
	sleep "$POLL"
done
