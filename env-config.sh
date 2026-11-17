#!/bin/sh
# Applies environment variables to the server configs. Runs on every container start.
#
#   CVAR_<NAME>=value            any cvar (server.cfg, game.cfg, amxx.cfg, plugin cfgs, ...)
#   AMXX_PLUGIN_<NAME>=0|1|flags enable/disable addons/amxmodx/configs/plugins.ini entries
#   AMXX_MODULE_<NAME>=0|1       enable/disable addons/amxmodx/configs/modules.ini entries
#   AMXX_CORE_<KEY>=value        addons/amxmodx/configs/core.ini
#   METAMOD_PLUGIN_<NAME>=0|1|path  addons/metamod/plugins.ini
#   METAMOD_CFG_<KEY>=value      addons/metamod/config.ini
#
# Usage: env-config.sh          apply
#        env-config.sh --list   print every setting that can be set this way
set -eu

GAME=${GAME_DIR:-/opt/hlds/cstrike}
AWK_PROG=$(dirname "$0")/env-config.awk
SHOW=0
[ "${1:-}" = "--list" ] && SHOW=1

cd "$GAME"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# run <mode> <prefix> <comment> <ext> <fallback> <avail> <files...>
run() {
	mode=$1 prefix=$2 cc=$3 ext=$4 fallback=$5 avail=$6
	shift 6
	for f; do shift; [ -f "$f" ] && set -- "$@" "$f"; done
	[ $# -gt 0 ] || return 0
	rm -rf "$TMP"/*
	awk -v mode="$mode" -v prefix="$prefix" -v cc="$cc" -v ext="$ext" \
		-v fallback="$fallback" -v availlist="$avail" -v tmpdir="$TMP" -v show="$SHOW" \
		-f "$AWK_PROG" "$@"
	[ "$SHOW" = 1 ] && return 0
	i=1
	for f in "$@"; do
		# Write in place (not mv) to keep ownership, mode and SELinux labels
		cmp -s "$TMP/$i" "$f" || cat "$TMP/$i" > "$f"
		i=$((i + 1))
	done
}

# Every .cfg that holds server cvars. Client/listen-server configs and the AMXX
# source tree are skipped. Settings found nowhere are appended to amxx.cfg,
# which AMXX executes after server.cfg, so they win.
AMXX_CFG=addons/amxmodx/configs/amxx.cfg
CFGS=$(find . -name '*.cfg' \
	! -path './addons/amxmodx/scripting/*' \
	! -name config.cfg ! -name listenserver.cfg ! -name userconfig.cfg \
	| sed 's|^\./||' | sort)
FALLBACK=server.cfg
[ -f "$AMXX_CFG" ] && FALLBACK=$AMXX_CFG
# shellcheck disable=SC2086 # cfg paths never contain spaces
run cvar CVAR_ // "" "$FALLBACK" "" $CFGS

AMXX=addons/amxmodx
if [ -d "$AMXX" ]; then
	PLUGINS=$(ls "$AMXX/plugins" 2>/dev/null | sed -n 's/\.amxx$//p' | tr '\n' '|')
	run list AMXX_PLUGIN_ ";" .amxx "$AMXX/configs/plugins.ini" "$PLUGINS" "$AMXX/configs/plugins.ini"
	run list AMXX_MODULE_ ";" "" "$AMXX/configs/modules.ini" "" "$AMXX/configs/modules.ini"
	run kv AMXX_CORE_ ";" "" "$AMXX/configs/core.ini" "" "$AMXX/configs/core.ini"
fi

MM=addons/metamod
if [ -d "$MM" ]; then
	run mm METAMOD_PLUGIN_ // "" "$MM/plugins.ini" "" "$MM/plugins.ini"
	run kv METAMOD_CFG_ // "" "$MM/config.ini" "" "$MM/config.ini"
fi
