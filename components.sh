#!/bin/sh
# Picks which components the server loads. Sourced by the entrypoint on every start,
# before env-config.sh, because it sets defaults for some of env-config's variables.
#
#   ENABLE_REGAMEDLL=1    ReGameDLL instead of the stock game dll
#   ENABLE_METAMOD=1      Metamod-R
#   ENABLE_AMXMODX=1      AMX Mod X + ReAPI (needs metamod)
#   ENABLE_HLTV=0         HLTV proxy next to the server (see hltv.sh)
#   ENABLE_HLTV_VOICE=$ENABLE_HLTV   let HLTV hear everyone, so demos have voice
#                         (needs ReGameDLL and AMX Mod X)
#
# Binaries are refreshed from the image on every start, so rebuilding the image
# upgrades them. Configs and plugins in the volume are left alone.

HLDS=/opt/hlds
GAME=$HLDS/cstrike
DEFAULTS=$HLDS/cstrike_defaults
DIST=$HLDS/dist

on() {
	case $(printf %s "${1:-}" | tr '[:upper:]' '[:lower:]') in
	1 | on | true | yes | enable | enabled) return 0 ;;
	esac
	return 1
}
say() { echo "[components] $*" >&2; }

# Copies $1 over $2 when they differ. Writes in place to keep ownership and SELinux labels.
sync_file() {
	[ -f "$1" ] || return 0
	cmp -s "$1" "$2" && return 0
	mkdir -p "$(dirname "$2")"
	cat "$1" >"$2"
	say "updated ${2#"$GAME"/}"
}

# Copies a directory from the defaults when the volume doesn't have it yet
ensure_dir() {
	[ -d "$GAME/$1" ] && return 0
	mkdir -p "$(dirname "$GAME/$1")"
	cp -a "$DEFAULTS/$1" "$GAME/$1"
	say "installed $1"
}

: "${ENABLE_REGAMEDLL:=1}" "${ENABLE_METAMOD:=1}" "${ENABLE_AMXMODX:=1}" "${ENABLE_HLTV:=0}"
: "${ENABLE_HLTV_VOICE:=$ENABLE_HLTV}"
export ENABLE_REGAMEDLL ENABLE_METAMOD ENABLE_AMXMODX ENABLE_HLTV ENABLE_HLTV_VOICE

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
amxx=0
if on "$ENABLE_AMXMODX"; then
	if on "$ENABLE_METAMOD"; then
		amxx=1
		ensure_dir addons/amxmodx
		for f in "$DEFAULTS"/addons/amxmodx/dlls/*.so "$DEFAULTS"/addons/amxmodx/modules/*.so; do
			sync_file "$f" "$GAME/${f#"$DEFAULTS"/}"
		done
	else
		say "warning: ENABLE_AMXMODX needs ENABLE_METAMOD, not loading AMX Mod X"
	fi
fi
if [ -f "$GAME/addons/metamod/plugins.ini" ]; then
	# Handed to env-config.sh, unless set explicitly
	if [ $amxx = 1 ]; then
		: "${METAMOD_PLUGIN_AMXMODX:=addons/amxmodx/dlls/amxmodx_mm_i386.so}"
	else
		: "${METAMOD_PLUGIN_AMXMODX:=0}"
	fi
	export METAMOD_PLUGIN_AMXMODX
fi
[ $amxx = 1 ] && say "AMX Mod X: on" || say "AMX Mod X: off"

# HLTV voice plugin
voice=0
if on "$ENABLE_HLTV_VOICE"; then
	if [ $amxx = 1 ] && on "$ENABLE_REGAMEDLL"; then
		voice=1
	else
		say "warning: ENABLE_HLTV_VOICE needs ReGameDLL and AMX Mod X. Use CVAR_SV_ALLTALK=3 instead (spectators hear everyone)"
	fi
fi
if [ $amxx = 1 ]; then
	sync_file "$DEFAULTS/addons/amxmodx/plugins/hltv_voice.amxx" "$GAME/addons/amxmodx/plugins/hltv_voice.amxx"
	if [ $voice = 1 ]; then
		: "${AMXX_PLUGIN_HLTV_VOICE:=1}"
		export AMXX_PLUGIN_HLTV_VOICE
	elif grep -q hltv_voice "$GAME/addons/amxmodx/configs/plugins.ini" 2>/dev/null; then
		: "${AMXX_PLUGIN_HLTV_VOICE:=0}"
		export AMXX_PLUGIN_HLTV_VOICE
	fi
fi
if on "$ENABLE_HLTV"; then
	[ $voice = 1 ] && say "HLTV: on, with voice" || say "HLTV: on"
fi
