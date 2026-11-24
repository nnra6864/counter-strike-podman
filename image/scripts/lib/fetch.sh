#!/bin/sh
# Sourced by packs.sh: downloads. GameBanana pages, fetching into downloads/, and laying an
# archive out like cstrike. Uses packs.sh's globals (TMP, LIB, DOWNLOADS, say, ...)

# Downloads ---------------------------------------------------------------------------

# Sets dl_url, dl_md5 and title from a GameBanana page
gamebanana() {
	page=$(curl -fsSL -S -o /dev/null -w '%{url_effective}' -m 30 "$1" 2>"$TMP/err") || {
		say "$1: can't reach it: $(cat "$TMP/err")"
		return 1
	}
	id=$(printf %s "$page" | sed -n 's|.*gamebanana\.com/mods/\([0-9][0-9]*\).*|\1|p')
	if [ -z "$id" ]; then
		say "$1: not a GameBanana mod page (gamebanana.com/mods/<id>), it went to $page"
		return 1
	fi
	curl -fsSL -S -m 30 -o "$TMP/gb.json" \
		"https://gamebanana.com/apiv11/Mod/$id?_csvProperties=_sName,_aFiles,_aGame" 2>"$TMP/err" || {
		say "$1: GameBanana's API didn't answer: $(cat "$TMP/err")"
		return 1
	}
	jq -r '._sName // "", (._aGame._idRow // "" | tostring)' "$TMP/gb.json" >"$TMP/gb.txt" || return 1
	{ read -r title; read -r game; } <"$TMP/gb.txt"
	[ "$game" = 4254 ] || say "$1: warning: not a Counter-Strike 1.6 page (game $game)"
	# Its files, the most downloaded first: url, md5, name, size, date, downloads, the
	# uploader's note. Without the ones GameBanana archived or found an .exe in (a Windows
	# installer of the same map, say), unless that's all there is
	jq -r '(._aFiles // []) as $all
		| ($all | map(select((._aAnalysisWarnings.contains_exe // null) == null and (._bIsArchived | not)))) as $ok
		| (if ($ok | length) > 0 then $ok else $all end)
		| sort_by(-(._nDownloadCount // 0))[]
		| [._sDownloadUrl // "", ._sMd5Checksum // "", ._sFile // "",
			(((._nFilesize // 0) / 104857.6 | round) / 10 | tostring) + " MB",
			(._tsDateAdded // 0 | todate[:10]),
			(._nDownloadCount // 0 | tostring),
			(._sDescription // "" | gsub("[\\t\\r\\n]+"; " "))]
		| @tsv' "$TMP/gb.json" >"$TMP/gb.tsv" || return 1
	n=$(grep -c . "$TMP/gb.tsv")
	all=$(jq '._aFiles // [] | length' "$TMP/gb.json")
	if [ "$n" = 0 ]; then
		say "$1: the page has no files"
		return 1
	fi
	[ "$n" -lt "$all" ] && say "$1: left out $((all - n)) of its $all files (an installer, or archived)"
	[ "$n" = "$all" ] && [ "$(jq '[._aFiles[] | select(._aAnalysisWarnings.contains_exe)] | length' "$TMP/gb.json")" -gt 0 ] &&
		say "$1: warning: GameBanana found an .exe in every file"
	k=0
	if [ "$n" -gt 1 ]; then
		awk -F '\t' '{ printf "%-24s %8s  %s  %6s dl  %s\n", $3, $4, $5, $6, $7 }' "$TMP/gb.tsv" >"$TMP/gb.rows"
		if [ -n "${SAVING:-}" ] && [ -t 0 ] && [ -t 2 ]; then
			k=$("${0%/*}/pick.sh" "${title:-gamebanana-$id}: which file?" 0 <"$TMP/gb.rows") || {
				say "$1: no file picked"
				return 1
			}
		else
			say "$1: $n files, taking the most downloaded. To take another, use its link:"
			awk -F '\t' '{ printf "  %s  %s, %s, %s downloads\n", $1, $3, $5, $6 }' "$TMP/gb.tsv" >&2
		fi
	fi
	sed -n "$((k + 1))p" "$TMP/gb.tsv" >"$TMP/gb.one"
	dl_url=$(cut -f 1 "$TMP/gb.one") dl_md5=$(cut -f 2 "$TMP/gb.one") file=$(cut -f 3 "$TMP/gb.one")
	[ "$n" -gt 1 ] && say "$1: taking $file"
	[ -n "$title" ] || title=gamebanana-$id
	return 0
}

# Puts what's in the extracted archive $1 into pack dir $2, laid out like cstrike
lay_out() {
	# Roots: dirs that hold cstrike content dirs (cstrike/, or the archive itself).
	# Loose: dirs with a .bsp that isn't in a maps dir
	find "$1" -mindepth 1 -type d | while IFS= read -r d; do
		case " $CONTENT " in *" $(lower "${d##*/}") "*) printf '%s\n' "${d%/*}" ;; esac
	done | sort -u >"$TMP/roots"
	# Only the outermost ones (a parent sorts before its children)
	: >"$TMP/top"
	while IFS= read -r r; do
		kept=
		while IFS= read -r k; do
			case $r in "$k" | "$k"/*) kept=1 && break ;; esac
		done <"$TMP/top"
		[ -n "$kept" ] || printf '%s\n' "$r" >>"$TMP/top"
	done <"$TMP/roots"
	while IFS= read -r r; do cp -a "$r/." "$2/"; done <"$TMP/top"
	find "$1" -type f -iname '*.bsp' | while IFS= read -r f; do
		d=${f%/*}
		[ "$(lower "${d##*/}")" = maps ] && continue
		grep -qxF -e "$d" "$TMP/top" && continue
		find "$d" -maxdepth 1 -type f -exec cp -a {} "$2/" \;
	done
	# AMX Mod X plugins outside addons/: an amxmodx dir, a dir with scripting/ or plugins/
	# (and configs/, data/ next to them), or loose .sma, .inc and .amxx files. Wherever they
	# are: a root copied whole may have them too, where the game doesn't look
	amxx=$2/addons/amxmodx
	find "$1" -mindepth 1 -type d | while IFS= read -r d; do
		case /$(lower "${d#"$1"/}")/ in */addons/amxmodx/*) continue ;; esac
		b=$(lower "${d##*/}") p=$(lower "${d%/*}")
		p=${p##*/}
		if [ "$b" = amxmodx ] && [ "$p" != addons ]; then
			mkdir -p "$amxx" && cp -a "$d/." "$amxx/"
		elif { [ "$b" = scripting ] || [ "$b" = plugins ]; } && [ "$p" != amxmodx ] &&
			find "$d" -maxdepth 1 -type f \( -iname '*.sma' -o -iname '*.amxx' \) | grep -q .; then
			printf '%s\n' "${d%/*}"
		fi
	done | sort -u | while IFS= read -r d; do
		for c in "$d"/*/; do
			c=${c%/}
			case $(lower "${c##*/}") in
			scripting | plugins | configs | data | modules) mkdir -p "$amxx" && cp -a "$c" "$amxx/" ;;
			lang) mkdir -p "$amxx/data" && cp -a "$c" "$amxx/data/" ;;
			esac
		done
	done
	find "$1" -type f \( -iname '*.sma' -o -iname '*.inc' -o -iname '*.amxx' \) | while IFS= read -r f; do
		case /$(lower "${f#"$1"/}") in */amxmodx/* | */scripting/* | */plugins/*) continue ;; esac
		case $(lower "$f") in
		*.sma) d=$amxx/scripting ;;
		*.inc) d=$amxx/scripting/include ;;
		*) d=$amxx/plugins ;;
		esac
		mkdir -p "$d" && cp -a "$f" "$d/"
	done
	# Loose files where the game looks for them
	for f in "$2"/*; do
		[ -f "$f" ] || continue
		b=${f##*/}
		case $(lower "$b") in
		*.bsp | *.res | *.nav) mkdir -p "$2/maps" && mv "$f" "$2/maps/" ;;
		*.tga) mkdir -p "$2/gfx/env" && mv "$f" "$2/gfx/env/" ;;
		*.txt)
			m=${b%.txt}
			m=${m%_detail}
			if [ -f "$2/maps/$m.bsp" ] || [ -f "$2/$m.bsp" ]; then
				mkdir -p "$2/maps" && mv "$f" "$2/maps/"
			fi
			;;
		esac
	done
	# The game's paths are lowercase. Children first, so the parents' paths stay valid
	find "$2" -depth -mindepth 1 -type d | while IFS= read -r d; do
		b=${d##*/}
		l=$(lower "$b")
		[ "$b" = "$l" ] && continue
		if [ -e "${d%/*}/$l" ]; then
			cp -a "$d/." "${d%/*}/$l/" && rm -rf "$d"
		else
			mv "$d" "${d%/*}/$l"
		fi
	done
}

# Unpacks download $1 into pack dir $2. $3 names a lone .bsp, .sma or .amxx, $4 is its
# extension, if it had one
unpack() {
	x=$TMP/x
	rm -rf "$x" && mkdir -p "$x"
	if LC_ALL=C.UTF-8 bsdtar -xf "$1" -C "$x" --no-same-owner 2>"$TMP/err"; then
		# An archive in the archive
		if ! find "$x" -type f -iname '*.bsp' | grep -q . && ! find "$x" -type d | grep -qi '/\(models\|sound\|sprites\|gfx\)$'; then
			find "$x" -type f \( -iname '*.zip' -o -iname '*.rar' -o -iname '*.7z' \) | while IFS= read -r a; do
				mkdir -p "$a.d" && LC_ALL=C.UTF-8 bsdtar -xf "$a" -C "$a.d" --no-same-owner
			done
		fi
		# Only plain files and dirs: a link in an archive could point anywhere
		find "$x" ! -type f ! -type d -exec rm -f {} +
		chmod -R u+rwX,go+rX "$x"
		lay_out "$x" "$2"
	elif [ "$(od -An -t d4 -N 4 "$1" | tr -d ' ')" = 30 ]; then
		# GoldSrc BSP version 30
		mkdir -p "$2/maps" && cp "$1" "$2/maps/$3.bsp"
	elif [ "$(head -c 4 "$1")" = XXMA ]; then
		# A compiled AMX Mod X plugin
		mkdir -p "$2/addons/amxmodx/plugins" && cp "$1" "$2/addons/amxmodx/plugins/$3.amxx"
	elif [ "$4" = sma ] || grep -q '^[[:space:]]*#include[[:space:]]*<amxmodx>' "$1"; then
		# A plugin's source
		mkdir -p "$2/addons/amxmodx/scripting" && cp "$1" "$2/addons/amxmodx/scripting/$3.sma"
	else
		say "not an archive or a map: $(head -c 200 "$TMP/err")"
		return 1
	fi
	if ! find "$2" -mindepth 1 | grep -q .; then
		say "nothing in it looks like cstrike content (maps, models, sound, ...)"
		return 1
	fi
	# Readable by a web server serving fastdl
	chmod -R a+rX "$2"
}

clean_name() {
	lower "$1" | tr -c 'a-z0-9_.-' _ | sed 's/__*/_/g; s/^[._-]*//; s/[._-]*$//'
}

# Other servers in the library that use download $1
users() {
	[ -n "$SHARED" ] || return 0
	for m in "$LIB"/servers/*; do
		[ -f "$m" ] && [ "${m##*/}" != "$SERVER" ] || continue
		grep -qxF -e "$1" "$m" && printf '%s ' "${m##*/}"
	done
}

# Downloads $1 into downloads/ once (as $2 if given) and prints its name
fetch() {
	url=$1 name=$2
	if [ -n "$name" ]; then
		if [ -d "$DOWNLOADS/$name" ]; then
			[ "$(head -n 1 "$DOWNLOADS/$name/.source" 2>/dev/null)" = "$url" ] && echo "$name" && return 0
			others=$(users "$name")
			if [ -n "$others" ]; then
				say "$name: downloads/$name is $(head -n 1 "$DOWNLOADS/$name/.source") for ${others% }: name this one differently"
				return 1
			fi
		fi
	else
		for s in "$DOWNLOADS"/*/.source; do
			[ -f "$s" ] || continue
			[ "$(head -n 1 "$s")" = "$url" ] || continue
			s=${s%/.source}
			echo "${s##*/}"
			return 0
		done
	fi

	dl_url=$url dl_md5='' title=''
	case $url in
	*://gamebanana.com/dl/* | *://www.gamebanana.com/dl/*) ;;
	*://gamebanana.com/* | *://www.gamebanana.com/*)
		# cs save resolves the page (and asks which file) before taking the lock
		if [ "${gb_page:-}" = "$url" ]; then
			# shellcheck disable=SC2154 # set by packs.sh save
			dl_url=$gb_url dl_md5=$gb_md5 title=$gb_title
		else
			gamebanana "$url" || return 1
		fi
		;;
	esac
	say "downloading $url"
	tmp=$(mktemp -d "$DOWNLOADS/.tmp.XXXXXX")
	# 2 GB at most: the URLs are yours, but an uploader can replace a file
	got=$(curl -fsSL -S --retry 2 -m 900 --max-filesize 2147483648 -o "$tmp/download" -D "$tmp/headers" -w '%{url_effective}' "$dl_url" 2>"$TMP/err") || {
		say "$url: download failed: $(cat "$TMP/err")"
		rm -rf "$tmp"
		return 1
	}
	if [ -n "$dl_md5" ] && [ "$(md5sum "$tmp/download" | cut -d ' ' -f 1)" != "$dl_md5" ]; then
		say "$url: the download doesn't match GameBanana's checksum"
		rm -rf "$tmp"
		return 1
	fi
	# The file's name: from the server (attachment.php?id=...), or the URL
	file=$(tr -d '\r' <"$tmp/headers" | sed -n 's/^[Cc]ontent-[Dd]isposition:.*filename="\{0,1\}\([^";]*\)"\{0,1\}.*/\1/p' | tail -n 1)
	[ -n "$file" ] || file=${got%%\?*}
	file=${file##*/}
	[ -n "$file" ] || file=download
	ext=
	case $file in *.*) ext=$(lower "${file##*.}") ;; esac
	base=${file%.*}
	[ -n "$title" ] || title=$base
	mkdir "$tmp/pack"
	unpack "$tmp/download" "$tmp/pack" "$(lower "$base")" "$ext" || {
		say "$url: not installed"
		rm -rf "$tmp"
		return 1
	}
	if [ -z "$name" ]; then
		# One map, or one plugin: named after it, the name the game knows it by. Anything
		# else after the page's title (or the file's name), as the author's file names
		# often carry versions and the like
		own=$(find "$tmp/pack/maps" -maxdepth 1 -type f -iname '*.bsp' 2>/dev/null | sed 's|.*/||; s|\.[^.]*$||')
		[ -n "$own" ] || own=$(find "$tmp/pack/addons/amxmodx/scripting" "$tmp/pack/addons/amxmodx/plugins" \
			-maxdepth 1 -type f \( -iname '*.sma' -o -iname '*.amxx' \) 2>/dev/null | sed 's|.*/||; s|\.[^.]*$||' | sort -u)
		[ "$(printf '%s\n' "$own" | grep -c .)" = 1 ] || own=
		name=$(clean_name "${own:-$title}")
		[ -n "$name" ] || name=pack
		base=$name i=2
		while [ -e "$DOWNLOADS/$name" ]; do
			name=$base-$i i=$((i + 1))
		done
	fi
	printf '%s\n' "$url" >"$tmp/pack/.source"
	[ "$dl_url" != "$url" ] && printf 'file %s\n' "$dl_url" >>"$tmp/pack/.source"
	printf 'downloaded %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$tmp/pack/.source"
	[ -n "$dl_md5" ] && printf 'md5 %s\n' "$dl_md5" >>"$tmp/pack/.source"
	# The file as it came, untouched, for packs save
	mkdir "$tmp/pack/.original" && mv "$tmp/download" "$tmp/pack/.original/$(printf %s "$file" | tr '/' _)"
	rm -rf "${DOWNLOADS:?}/$name"
	mv "$tmp/pack" "$DOWNLOADS/$name"
	rm -rf "$tmp"
	n=$(find "$DOWNLOADS/$name/maps" -name '*.bsp' 2>/dev/null | wc -l)
	if [ -n "${SAVING:-}" ]; then say "downloaded it ($n maps)"; else say "$url: installed as downloads/$name ($n maps)"; fi
	echo "$name"
}
