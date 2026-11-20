#!/bin/bash
# cs save's tag picker: tagpick.sh <name> [tag...] lists the tags, and prints the ones
# picked plus any typed in, one per line. Needs a terminal (podman exec -it); draws on
# /dev/tty, so its output can be captured.
#
#   up/down          move
#   space or tab     pick or unpick the tag under the cursor
#   letters          type new tags in the slot at the bottom (spaces or commas between)
#   backspace        in the slot
#   enter            done
#   esc, ctrl-c      no tags (exits 1)

name=$1
shift
tags=("$@")
n=${#tags[@]}
declare -A on=()
cur=0 top=0 input='' drawn=0

exec 3<>/dev/tty || exit 1
old=$(stty -g <&3) || exit 1
trap 'stty "$old" <&3; printf "\e[?25h" >&3' EXIT
trap 'exit 130' INT TERM
stty -icanon -echo min 1 time 0 <&3
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
		printf '\r\e[K\e[2mspace/tab: pick, type: new tags, enter: done, esc: none\e[0m\n'
	} >&3
	drawn=$((view + 3))
}

while :; do
	draw
	IFS= read -rn1 -d '' -u 3 k || exit 1
	case $k in
	$'\e')
		rest=''
		IFS= read -rn2 -t 0.05 -u 3 rest
		case $rest in
		'[A' | 'OA') ((cur > 0)) && cur=$((cur - 1)) ;;
		'[B' | 'OB') ((cur < n)) && cur=$((cur + 1)) ;;
		'') exit 1 ;;
		esac
		;;
	$'\n' | $'\r') break ;;
	' ' | $'\t')
		if ((cur < n)); then
			on[$cur]=$((!${on[$cur]:-0}))
		elif [[ $k == ' ' ]]; then
			input+=' '
		fi
		;;
	$'\x7f' | $'\b') ((cur == n)) && input=${input%?} ;;
	[A-Za-z0-9_,-])
		cur=$n
		input+=$k
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
