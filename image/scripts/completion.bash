# Tab completion for cs in bash (podman exec -it <container> bash), sourced by
# /etc/bash.bashrc. cs console completes the server's commands, cvars and maps, from the
# list cs words writes (the interactive cs refreshes it), or the maps alone until then
_cs() {
	local cur=${COMP_WORDS[COMP_CWORD]} words
	if ((COMP_CWORD == 1)); then
		words='reload save remove tags maps console log help shell'
	else
		case ${COMP_WORDS[1]} in
		console)
			if [[ -f /tmp/cs-words ]]; then
				words=$(</tmp/cs-words)
			else
				words=$(ls /opt/hlds/cstrike/maps 2>/dev/null | sed -n 's/\.bsp$//p')
			fi
			;;
		remove) words=$(ls /opt/hlds/cstrike/maps 2>/dev/null | sed -n 's/\.bsp$//p') ;;
		reload) words='--now -v' ;;
		save) words='-r -t' ;;
		log) words='-f' ;;
		*) return ;;
		esac
	fi
	mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}
complete -F _cs cs
