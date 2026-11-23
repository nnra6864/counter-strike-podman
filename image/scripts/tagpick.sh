#!/bin/bash
# cs save's tag picker: tagpick.sh [-p 'tag...'] <name> [tag...] lists the tags, those
# after -p picked to start with, and prints the ones picked plus any typed in, one per line.
# Needs a terminal (podman exec -it); draws on /dev/tty, so its output can be captured.
#
#   up/down, ctrl-k/ctrl-j   move
#   space or tab             pick or unpick the tag under the cursor
#   letters                  type new tags in the slot at the bottom (spaces or commas between)
#   backspace                in the slot
#   enter                    done
#   esc, ctrl-c              no tags (exits 1)

picked=''
if [[ ${1:-} == -p ]]; then
	picked=" $2 "
	shift 2
fi
name=$1
shift
tags=("$@")
n=${#tags[@]}
declare -A on=()
for ((i = 0; i < n; i++)); do
	[[ $picked == *" ${tags[$i]} "* ]] && on[$i]=1
done
cur=0 top=0 input='' drawn=0

exec 3<>/dev/tty || exit 1
old=$(stty -g <&3) || exit 1
trap 'stty "$old" <&3; printf "\e[?25h" >&3' EXIT
trap 'exit 130' INT TERM
# -icrnl: enter comes as \r, so ctrl-j (\n) can move down
stty -icanon -echo -icrnl min 1 time 0 <&3
printf '\e[?25l' >&3

rows=$(stty size <&3 | cut -d ' ' -f 1)
[[ $rows =~ ^[0-9]+$ ]] || rows=24
view=$((rows - 4))
((view < 3)) && view=3
((view > n)) && view=$n

draw() {
	local i mark row
	((drawn)) && printf '\e[%dA' "$drawn" >&3
	if ((cur >= 0 && cur < n)); then
		((cur < top)) && top=$cur
		((cur >= top + view)) && top=$((cur - view + 1))
	fi
	{
		printf '\r\e[K\e[1mTags for %s\e[0m' "$name"
		((view < n)) && printf ' (%d-%d of %d)' $((top + 1)) $((top + view)) "$n"
		printf '\n'
		for ((i = top; i < top + view; i++)); do
			mark=' '
			((${on[$i]:-0})) && mark=x
			row="[$mark] ${tags[$i]}"
			if ((i == cur)); then
				printf '\r\e[K> \e[7m%s\e[0m\n' "$row"
			else
				printf '\r\e[K  %s\n' "$row"
			fi
		done
		if ((cur == n)); then
			printf '\r\e[K> new: %s\e[7m \e[0m\n' "$input"
		else
			printf '\r\e[K  new: %s\n' "$input"
		fi
		printf '\r\e[K\e[2mctrl-j/k: move, space/tab: pick, type: new tags, enter: done, esc: none\e[0m\n'
	} >&3
	drawn=$((view + 3))
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
		5b42 | 4f42) ((cur < n)) && cur=$((cur + 1)) ;;
		'') exit 1 ;;
		esac
		;;
	0d) break ;;
	0a) ((cur < n)) && cur=$((cur + 1)) ;;
	0b) ((cur > 0)) && cur=$((cur - 1)) ;;
	20 | 09)
		if ((cur < n)); then
			on[$cur]=$((!${on[$cur]:-0}))
		elif [[ $k == 20 ]]; then
			input+=' '
		fi
		;;
	7f | 08) ((cur == n)) && input=${input%?} ;;
	3[0-9] | [46][1-9a-f] | [57][0-9a] | 5f | 2c | 2d)
		cur=$n
		input+=$(printf %b "\\x$k")
		;;
	esac
done
cur=-1
draw

{
	for ((i = 0; i < n; i++)); do
		((${on[$i]:-0})) && printf '%s\n' "${tags[$i]}"
	done
	printf '%s\n' "$input" | tr ', ' '\n' | tr '[:upper:]' '[:lower:]'
} | awk 'NF && !seen[$0]++'
