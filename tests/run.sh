#!/bin/sh
# Tests for the container scripts: ./tests/run.sh [case...]
#
# Runs tests/cases.sh in a throwaway container from the built image, with no network and
# this checkout's image/scripts in place of the image's, so a change can be tested before
# rebuilding. Nothing of a server's is mounted. IMAGE= picks another image.
# Also runs shellcheck and shfmt on the scripts when they're installed.
cd "$(dirname "$0")/.." || exit 1

if [ -z "${IMAGE:-}" ]; then
	IMAGE=$(podman images --format '{{.Repository}}:{{.Tag}}' |
		grep -m 1 -e '^localhost/counter-strike:latest$' -e '^localhost/counter-strike.*_counter-strike:latest$')
fi
[ -n "$IMAGE" ] || { echo "no image: podman compose build first, or set IMAGE" >&2 && exit 1; }

rc=0
if command -v shellcheck >/dev/null; then
	shellcheck -S warning image/scripts/*.sh tests/*.sh || rc=1
fi

podman run --rm --network none --entrypoint sh \
	-v ./image/scripts:/src:ro,Z -v ./tests:/tests:ro,Z \
	"$IMAGE" /tests/cases.sh "$@" || rc=1
exit $rc
