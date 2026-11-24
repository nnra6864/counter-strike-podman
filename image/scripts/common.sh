#!/bin/sh
# Sourced by the other scripts: what they all use

# Is $1 a yes: 1, on, true, yes, enable(d), any case
on() {
	case $(printf %s "${1:-}" | tr '[:upper:]' '[:lower:]') in
	1 | on | true | yes | enable | enabled) return 0 ;;
	esac
	return 1
}
lower() { printf %s "$1" | tr '[:upper:]' '[:lower:]'; }
