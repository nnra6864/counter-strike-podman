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

exec "$@"
