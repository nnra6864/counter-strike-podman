#!/bin/sh
# ./cs <command>: the container's cs (cs help), run in this checkout's container, with a
# terminal when there is one (for the pickers and cs remove's question). And on the host:
#
#   ./cs up        start it, or recreate it with the current image and settings
#   ./cs build     build the image
#   ./cs attach    the server's console (detach: ctrl-p ctrl-q)
cd "$(dirname "$0")" || exit 1

case ${1:-} in
up) exec podman compose up -d --force-recreate ;;
build) exec podman compose build ;;
esac
c=$(podman ps -a --filter "label=com.docker.compose.project.working_dir=$PWD" --format '{{.Names}}' | head -n 1)
[ -n "$c" ] || { echo "./cs: no container for $PWD: ./cs up" >&2 && exit 1; }
[ "${1:-}" = attach ] && exec podman attach "$c"
if [ -t 0 ] && [ -t 1 ]; then
	exec podman exec -it "$c" cs "$@"
fi
exec podman exec -i "$c" cs "$@"
