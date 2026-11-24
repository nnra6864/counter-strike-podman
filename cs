#!/bin/sh
# ./cs <command>: the container's cs (cs help), run in this checkout's container, with a
# terminal when there is one (for the pickers and cs remove's question). ./cs alone: the
# server's console with tab completion and history. And on the host:
#
#   ./cs up        build the image (cached, so quick when nothing changed), then start the
#                  container, or recreate it: podman-compose only recreates when
#                  compose.yaml changes, not for a new image or edited env files
#   ./cs build     build the image
#   ./cs attach    the server's raw console (detach: ctrl-p ctrl-q)
cd "$(dirname "$0")" || exit 1

# The build stages that take long (CS through SteamCMD, the demo tool) get a tag of their
# own: untagged, they're dangling images, which podman image prune deletes, and the next
# build then downloads CS again. Both come straight from the build cache. A new build moves
# the tag, so the stage it replaced is left dangling for prune
build() {
	podman compose build || return
	for s in steam demo-tools; do
		podman build -q --target "$s" -t "localhost/counter-strike-cache:$s" image >/dev/null || return
	done
}

case ${1:-} in
up) build && exec podman compose up -d --force-recreate ;;
build)
	build
	exit
	;;
esac
c=$(podman ps -a --filter "label=com.docker.compose.project.working_dir=$PWD" --format '{{.Names}}' | head -n 1)
[ -n "$c" ] || { echo "./cs: no container for $PWD: ./cs up" >&2 && exit 1; }
[ "${1:-}" = attach ] && exec podman attach "$c"
if [ -t 0 ] && [ -t 1 ]; then
	exec podman exec -it "$c" cs "$@"
fi
exec podman exec -i "$c" cs "$@"
