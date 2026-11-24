#!/bin/sh
# Puts the components the server loads in place. Sourced by the entrypoint on every start.
# What follows from these settings for env-config.sh is worked out in settings.sh.
#
#   ENABLE_REGAMEDLL=1    ReGameDLL instead of the stock game dll
#   ENABLE_METAMOD=1      Metamod-R
#   ENABLE_AMXMODX=1      AMX Mod X + ReAPI (needs metamod)
#   ENABLE_HLTV=0         HLTV proxy next to the server (see hltv.sh)
#   ENABLE_HLTV_VOICE=$ENABLE_HLTV   let HLTV hear everyone, so demos have voice
#                         (needs ReGameDLL and AMX Mod X)
#   ENABLE_VOICE_MKA=$ENABLE_HLTV    a .mka with a track per player next to each
#                         finished demo (see demos.sh, VOICE_MKA_ARGS)
#
# Binaries are refreshed from the image on every start, so rebuilding the image
# upgrades them. Configs and plugins in the volume are left alone.

HLDS=/opt/hlds
GAME=$HLDS/cstrike
DEFAULTS=$HLDS/cstrike_defaults
DIST=$HLDS/dist

# The ENABLE_ defaults, on(), and what loads: SETTINGS_AMXX, SETTINGS_VOICE
. "$HLDS/settings.sh"
say() { echo "[components] $*" >&2; }

# Copies $1 over $2 when they differ. Writes in place to keep ownership and SELinux labels.
sync_file() {
	[ -f "$1" ] || return 0
	cmp -s "$1" "$2" && return 0
	mkdir -p "$(dirname "$2")"
	write_in_place "$1" "$2"
	say "updated ${2#"$GAME"/}"
}

# Copies a directory from the defaults when the volume doesn't have it yet
ensure_dir() {
	[ -d "$GAME/$1" ] && return 0
	mkdir -p "$(dirname "$GAME/$1")"
	cp -a "$DEFAULTS/$1" "$GAME/$1"
	say "installed $1"
}

# Game dll
if on "$ENABLE_REGAMEDLL"; then dll=regamedll; else dll=stock; fi
sync_file "$DIST/$dll/cs.so" "$GAME/dlls/cs.so"
sync_file "$DIST/$dll/delta.lst" "$GAME/delta.lst"
# Metamod's gamedll auto-detection looks for cs_i386.so
[ -e "$GAME/dlls/cs_i386.so" ] || ln -s cs.so "$GAME/dlls/cs_i386.so"
say "game dll: $dll"

# Metamod
if on "$ENABLE_METAMOD"; then
	ensure_dir addons/metamod
	sync_file "$DEFAULTS/addons/metamod/metamod_i386.so" "$GAME/addons/metamod/metamod_i386.so"
	gamedll=addons/metamod/metamod_i386.so
else
	gamedll=dlls/cs.so
fi
if ! grep -q "^gamedll_linux \"$gamedll\"" "$GAME/liblist.gam"; then
	sed "s|^gamedll_linux .*|gamedll_linux \"$gamedll\"|" "$GAME/liblist.gam" >"$GAME/liblist.gam.tmp"
	cat "$GAME/liblist.gam.tmp" >"$GAME/liblist.gam"
	rm -f "$GAME/liblist.gam.tmp"
fi
say "liblist.gam loads $gamedll"

# AMX Mod X (+ ReAPI, which ships as an AMXX module)
if [ "$SETTINGS_AMXX" = 1 ]; then
	ensure_dir addons/amxmodx
	for f in "$DEFAULTS"/addons/amxmodx/dlls/*.so "$DEFAULTS"/addons/amxmodx/modules/*.so; do
		sync_file "$f" "$GAME/${f#"$DEFAULTS"/}"
	done
	# Gamedata (offsets and signatures) belongs to the build, like the modules
	find "$DEFAULTS/addons/amxmodx/data/gamedata" -type f 2>/dev/null | while IFS= read -r f; do
		sync_file "$f" "$GAME/${f#"$DEFAULTS"/}"
	done
	# The hltv_tools plugin: HLTV hears everyone (voice in demos), and the player count
	# that hltv.sh records by
	sync_file "$DEFAULTS/addons/amxmodx/plugins/hltv_tools.amxx" "$GAME/addons/amxmodx/plugins/hltv_tools.amxx"
	say "AMX Mod X: on"
else
	on "$ENABLE_AMXMODX" && say "warning: ENABLE_AMXMODX needs ENABLE_METAMOD, not loading AMX Mod X"
	say "AMX Mod X: off"
	on "$ENABLE_HLTV" && say "warning: without AMX Mod X, HLTV can't tell when players are on: it records all the time"
fi
if on "$ENABLE_HLTV_VOICE" && [ "$SETTINGS_VOICE" = 0 ]; then
	say "warning: ENABLE_HLTV_VOICE needs ReGameDLL and AMX Mod X. Use CVAR_SV_ALLTALK=3 instead (spectators hear everyone)"
fi
if on "$ENABLE_HLTV"; then
	[ "$SETTINGS_VOICE" = 1 ] && say "HLTV: on, with voice" || say "HLTV: on"
	say "recording: ${RECORD_IDLE_STOP:-120}s idle stop (0 = always), empty demos deleted: ${DELETE_EMPTY_DEMOS:-1}"
	on "$ENABLE_VOICE_MKA" && say "voice .mka per demo: on${VOICE_MKA_ARGS:+ ($VOICE_MKA_ARGS)}"
fi
:
