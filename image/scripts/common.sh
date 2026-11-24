#!/bin/sh
# Sourced by the other scripts: what they all use

# Is $1 a yes: 1, on, true, yes, enable(d), any case
on() {
	case $(printf %s "${1:-}" | tr '[:upper:]' '[:lower:]') in
	1 | on | true | yes | enable | enabled) return 0 ;;
	esac
	return 1
}
# Puts file $1's contents in file $2, if they differ. Written over, not replaced: $2 keeps
# its owner, mode and SELinux label
write_in_place() { cmp -s "$1" "$2" || cat "$1" >"$2"; }
lower() { printf %s "$1" | tr '[:upper:]' '[:lower:]'; }
