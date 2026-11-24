#!/bin/sh
# Sourced, never run: the settings that follow from other settings, exported for
# env-config.sh. It only computes: it changes no files and prints nothing.
#
# Sourced by the entrypoint (through components.sh, and again before env-config.sh, once
# the files it looks at are in place) and by `cs reload`. Without these, env-config.sh
# would undo what they set: it restores whatever a variable that's gone had changed.
#
#   METAMOD_PLUGIN_AMXMODX   AMX Mod X in metamod's plugins.ini, by ENABLE_AMXMODX
#   AMXX_PLUGIN_HLTV_TOOLS   the hltv_tools plugin, by ENABLE_HLTV and ENABLE_HLTV_VOICE
#   CVAR_HLTV_TOOLS_VOICE    whether it lets HLTV hear everyone
#   CVAR_MAPCYCLEFILE        packs_mapcycle.txt, by MAPCYCLE
#   CVAR_SV_DOWNLOADURL      FASTDL_URL
# A variable set by hand wins over all of these.

. /opt/hlds/common.sh

: "${ENABLE_REGAMEDLL:=1}" "${ENABLE_METAMOD:=1}" "${ENABLE_AMXMODX:=1}" "${ENABLE_HLTV:=0}"
: "${ENABLE_HLTV_VOICE:=$ENABLE_HLTV}" "${ENABLE_VOICE_MKA:=$ENABLE_HLTV}"
export ENABLE_REGAMEDLL ENABLE_METAMOD ENABLE_AMXMODX ENABLE_HLTV ENABLE_HLTV_VOICE ENABLE_VOICE_MKA

# What actually loads: AMX Mod X needs metamod, HLTV's voice needs ReGameDLL and AMX Mod X
SETTINGS_AMXX=0 SETTINGS_VOICE=0
on "$ENABLE_AMXMODX" && on "$ENABLE_METAMOD" && SETTINGS_AMXX=1
on "$ENABLE_HLTV_VOICE" && [ $SETTINGS_AMXX = 1 ] && on "$ENABLE_REGAMEDLL" && SETTINGS_VOICE=1

if [ -f /opt/hlds/cstrike/addons/metamod/plugins.ini ]; then
	if [ $SETTINGS_AMXX = 1 ]; then
		: "${METAMOD_PLUGIN_AMXMODX:=addons/amxmodx/dlls/amxmodx_mm_i386.so}"
	else
		: "${METAMOD_PLUGIN_AMXMODX:=0}"
	fi
	export METAMOD_PLUGIN_AMXMODX
fi

if [ $SETTINGS_AMXX = 1 ]; then
	settings_ini=/opt/hlds/cstrike/addons/amxmodx/configs/plugins.ini
	if on "$ENABLE_HLTV" || [ $SETTINGS_VOICE = 1 ]; then
		: "${AMXX_PLUGIN_HLTV_TOOLS:=1}" "${CVAR_HLTV_TOOLS_VOICE:=$SETTINGS_VOICE}"
		export AMXX_PLUGIN_HLTV_TOOLS CVAR_HLTV_TOOLS_VOICE
	elif grep -q hltv_tools "$settings_ini" 2>/dev/null; then
		: "${AMXX_PLUGIN_HLTV_TOOLS:=0}"
		export AMXX_PLUGIN_HLTV_TOOLS
	fi
	# hltv_voice was replaced by hltv_tools (2026-11-19). Remove once no volume has it
	if grep -q hltv_voice "$settings_ini" 2>/dev/null; then
		: "${AMXX_PLUGIN_HLTV_VOICE:=0}"
		export AMXX_PLUGIN_HLTV_VOICE
	fi
fi

# The map cycle from the packs. Set even while it's empty, so `cs reload` can fill it later
if on "${MAPCYCLE:-1}"; then
	: "${CVAR_MAPCYCLEFILE:=packs_mapcycle.txt}"
	export CVAR_MAPCYCLEFILE
fi
# Players download the packs' files from FASTDL_URL (fastdl/<name>/ in the library)
if [ -n "${FASTDL_URL:-}" ]; then
	: "${CVAR_SV_DOWNLOADURL:=${FASTDL_URL%/}/}"
	export CVAR_SV_DOWNLOADURL
fi
:
