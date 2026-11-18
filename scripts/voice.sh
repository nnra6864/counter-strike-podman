#!/bin/sh
# Writes the voice chat of every finished demo to a .mka next to it, with a track per
# player (goldsrc-hltv-voice). Started in the background by hltv.sh when HLTV records
# and ENABLE_VOICE_MKA is on.
#
#   voice.sh <dir> <name>    demos are <dir>/<name>-<date>-<map>.dem
#   VOICE_MKA_ARGS=""        extra options: "--order team" (tracks T first, then CT),
#                            "--tracks team|mix", "--lenient"
#   VOICE_MKA_POLL=15        seconds between looks at the demo dir
#
# HLTV closes a demo when it starts the next one (map change, or reconnecting after a
# restart), so a demo is finished once a newer one shows up. When this starts, HLTV isn't
# recording yet, so the newest demo (left by a stop or a crash) is finished too.
# Demos that already have a .mka are left alone. A demo with no voice writes nothing, and
# neither does one that only partly parses, unless VOICE_MKA_ARGS has --lenient. The log
# says what failed either way, and the demo is still there to rerun by hand.

DIR=$1
NAME=$2
POLL=${VOICE_MKA_POLL:-15}
# hltv.sh points this at HLDS's 32-bit libraries
unset LD_LIBRARY_PATH

say() { echo "[voice] $*"; }

# Demos oldest first, by modification time: the one being recorded is always the last
demos() { ls -1tr "$DIR/$NAME"-*.dem 2>/dev/null; }

extract() {
	[ -f "$1" ] && [ ! -e "${1%.dem}.mka" ] || return 0
	say "$(basename "$1")"
	# shellcheck disable=SC2086 # VOICE_MKA_ARGS is a list of options
	out=$(nice goldsrc-hltv-voice $VOICE_MKA_ARGS "$1" 2>&1)
	code=$?
	[ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/[voice]   /'
	case $code in
	0) ;;
	3) say "$(basename "$1"): parts of the demo could not be read (exit 3), see above" ;;
	*) say "$(basename "$1"): failed (exit $code)" ;;
	esac
}

current=$(demos | tail -n 1)
extract "$current"
while sleep "$POLL"; do
	latest=$(demos | tail -n 1)
	[ -n "$latest" ] && [ "$latest" != "$current" ] || continue
	# Everything from $current up to the one now being recorded is finished. More than
	# one if maps changed faster than we poll
	demos | awk -v from="$current" -v to="$latest" '
		$0 == to { exit }
		$0 == from || from == "" { on = 1 }
		on' | while IFS= read -r f; do extract "$f"; done
	current=$latest
done
