#!/bin/bash
# cs save's one-of-many picker: pick.sh <title> <start> lists the rows on stdin, the
# cursor on row <start> (from 0), and prints the number of the one picked (from 0).
# Needs a terminal (podman exec -it); draws on /dev/tty, so its output can be captured.
#
#   up/down, ctrl-k/ctrl-j   move
#   enter                    pick
#   esc, ctrl-c              none (exits 1)

title=$1 cur=$2
mapfile -t rows
n=${#rows[@]}
((n > 0)) || exit 1
[[ $cur =~ ^[0-9]+$ ]] && ((cur < n)) || cur=0
top=0 drawn=0

exec 3<>/dev/tty || exit 1
old=$(stty -g <&3) || exit 1
trap 'stty "$old" <&3; printf "\e[?25h" >&3' EXIT
trap 'exit 130' INT TERM
# -icrnl: enter comes as \r, so ctrl-j (\n) can move down
stty -icanon -echo -icrnl min 1 time 0 <&3
printf '\e[?25l' >&3

size=$(stty size <&3)
lines=${size%% *} cols=${size##* }
[[ $lines =~ ^[0-9]+$ ]] || lines=24
[[ $cols =~ ^[0-9]+$ ]] || cols=80
view=$((lines - 3))
((view < 3)) && view=3
((view > n)) && view=$n

draw() {
	local i row
	((drawn)) && printf '\e[%dA' "$drawn" >&3
	((cur < top)) && top=$cur
	((cur >= top + view)) && top=$((cur - view + 1))
	{
		printf '\r\e[K\e[1m%s\e[0m' "$title"
		((view < n)) && printf ' (%d-%d of %d)' $((top + 1)) $((top + view)) "$n"
		printf '\n'
		for ((i = top; i < top + view; i++)); do
			# One line each: long ones are cut to the terminal's width
			row=${rows[$i]:0:$((cols - 3))}
			if ((i == cur)); then
				printf '\r\e[K> \e[7m%s\e[0m\n' "$row"
			else
				printf '\r\e[K  %s\n' "$row"
			fi
		done
		printf '\r\e[K\e[2mctrl-j/k: move, enter: pick, esc: none\e[0m\n'
	} >&3
	drawn=$((view + 2))
}

# A key as hex bytes. dd, not read -n: bash's read turns the terminal's CR-to-NL back on,
# and then enter and ctrl-j are the same key
key() { dd bs="${1:-1}" count=1 2>/dev/null <&3 | od -An -tx1 | tr -d ' \n'; }

while :; do
	draw
	k=$(key)
	[ -n "$k" ] || exit 1
	case $k in
	1b)
		# An arrow's bytes come right after the esc; esc alone has none
		stty min 0 time 1 <&3
		rest=$(key 2)
		stty min 1 time 0 <&3
		case $rest in
		5b41 | 4f41) ((cur > 0)) && cur=$((cur - 1)) ;;
		5b42 | 4f42) ((cur < n - 1)) && cur=$((cur + 1)) ;;
		'') exit 1 ;;
		esac
		;;
	0d) break ;;
	0a) ((cur < n - 1)) && cur=$((cur + 1)) ;;
	0b) ((cur > 0)) && cur=$((cur - 1)) ;;
	esac
done
echo "$cur"
