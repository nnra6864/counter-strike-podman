#!/bin/sh
set -e

if [ -z "$(ls -A /opt/hlds/cstrike 2>/dev/null)" ]; then
	echo "Initializing cstrike directory"
	cp -a /opt/hlds/cstrike_defaults/. /opt/hlds/cstrike/
fi

# Sourced: it sets defaults for env-config.sh
. /opt/hlds/components.sh

/opt/hlds/env-config.sh || echo "[env] failed to apply env vars, starting with configs as they are"

case $(printf %s "$ENABLE_HLTV" | tr '[:upper:]' '[:lower:]') in
1 | on | true | yes | enable | enabled) /opt/hlds/hltv.sh & ;;
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
if [ -n "$maxplayers" ]; then set -- "$@" +maxplayers "$maxplayers"; fi
if [ -n "$map" ]; then set -- "$@" +map "$map"; fi

exec "$@"
