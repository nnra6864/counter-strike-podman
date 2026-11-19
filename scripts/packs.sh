#!/bin/sh
# Packs: maps, and anything else laid out like cstrike (models, sounds, sprites, wads), each
# in its own dir, linked into cstrike. Run by the entrypoint on every start, and by hand
# after editing the list, while the server runs (new maps work from the next map change):
#
#   podman exec <container> packs
#
# data/packlist says which packs, in order; the first one wins a file two packs have. One
# per line, # for comments:
#   default        the maps CS ships with (kept in the image)
#   mypack         packs/mypack in the library, yours
#   mypack/de_*    only these maps from it (and its other files)
#   *              every dir in packs/
#   -cs_*          leave these maps out, whichever pack has them
#   URL            downloaded into downloads/ once: a GameBanana page
#                  (gamebanana.com/mods/<id>), or a direct link to a .zip, .rar, .7z or .bsp
#   name=URL       the same, into downloads/name
# A download no server lists any more is deleted. Your own packs never are.
#
# The library is where packs live: data/ (packs/, downloads/), or a dir mounted at
# /opt/hlds/library, shared by several servers. In a shared library each server keeps the
# downloads it uses in servers/<name>, so a download goes once no server lists it.
#
#   MAPCYCLE=1     the map cycle is every map from the packs, in packlist order
#                  (cstrike/packs_mapcycle.txt). 0: mapcycle.txt
#   FASTDL_URL=    http://host/<name>/: players download the packs' files from there
#                  (sv_downloadurl). Writes fastdl/<name>/ in the library: links to exactly
#                  the files this server uses, for a web server to serve. <name> also
#                  names this server in a shared library
#   SERVER_NAME=   names this server in a shared library, without FASTDL_URL
#
# A pack dir is laid out like cstrike: maps/de_x.bsp, gfx/env/, sound/, x.wad. Files that
# are already in cstrike (not links) are never replaced, so cstrike/maps still works for
# maps you'd rather not put in a pack. The links made are listed in
# cstrike/packs_links.txt, and taken down the next time before the new ones go up.

GAME=/opt/hlds/cstrike
DATA=/opt/hlds/data
DEFAULT=/opt/hlds/packs/default
LIST=$DATA/packlist
LINKS=$GAME/packs_links.txt
CYCLE=$GAME/packs_mapcycle.txt
# Where a pack's files may go in cstrike, besides *.wad at its top
CONTENT="maps models sound sprites gfx overviews resource addons"

say() { echo "[packs] $*" >&2; }
on() {
	case $(printf %s "${1:-}" | tr '[:upper:]' '[:lower:]') in
	1 | on | true | yes | enable | enabled) return 0 ;;
	esac
	return 1
}
lower() { printf %s "$1" | tr '[:upper:]' '[:lower:]'; }
# ../ for each dir in relative path $1
up() { printf %s "$1" | sed 's|[^/]*$||; s|[^/]*/|../|g'; }

if [ -d /opt/hlds/library ]; then
	LIB=/opt/hlds/library SHARED=1
else
	LIB=$DATA SHARED=
fi
PACKS=$LIB/packs
DOWNLOADS=$LIB/downloads

# This server's name in the library: from FASTDL_URL's path, or SERVER_NAME
SERVER=
if [ -n "${FASTDL_URL:-}" ]; then
	u=${FASTDL_URL%/}
	case $u in
	*://*/*) SERVER=${u##*/} ;;
	*) say "warning: FASTDL_URL needs a path for this server, like http://host/<name>/: no fastdl" ;;
	esac
fi
[ -n "$SERVER" ] || SERVER=${SERVER_NAME:-}
case $SERVER in */* | .*) say "warning: $SERVER: not a usable server name" && SERVER= ;; esac

mkdir -p "$DATA" "$PACKS" "$DOWNLOADS"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# One run at a time per library: several servers, or a start and `packs` at once
if command -v flock >/dev/null; then
	exec 9>"$LIB/.lock"
	flock -w 1800 9 || say "warning: another run holds $LIB/.lock, going ahead anyway"
fi
rm -rf "$DOWNLOADS"/.tmp.*

if [ ! -f "$LIST" ]; then
	cat >"$LIST" <<-'EOF'
	# The packs this server uses, in order: the first one wins a file two packs have.
	# After editing: podman exec <container> packs   (new maps work from the next map change)
	#
	#   default        the maps CS ships with
	#   mypack         packs/mypack
	#   mypack/de_*    only these maps from it
	#   *              every dir in packs/
	#   -cs_*          leave these maps out
	#   https://gamebanana.com/mods/<id>, or a direct link to a .zip/.rar/.7z/.bsp
	#   name=https://...   the same, as downloads/name
	default
	*
	EOF
	say "wrote ${LIST#/opt/hlds/}"
fi

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
	# The newest file, when the page has more than one. A gamebanana.com/dl/<file id>
	# link picks another
	jq -r '._sName // "",
		((._aFiles // []) | sort_by(._tsDateAdded) | last | (._sDownloadUrl // "", ._sMd5Checksum // "", ._sFile // "")),
		(._aGame._idRow // "" | tostring)' "$TMP/gb.json" >"$TMP/gb.txt" || return 1
	{ read -r title; read -r dl_url; read -r dl_md5; read -r file; read -r game; } <"$TMP/gb.txt"
	if [ -z "$dl_url" ]; then
		say "$1: the page has no files"
		return 1
	fi
	[ "$game" = 4254 ] || say "$1: warning: not a Counter-Strike 1.6 page (game $game)"
	n=$(jq '._aFiles | length' "$TMP/gb.json")
	[ "$n" -gt 1 ] && say "$1: $n files, taking the newest ($file)"
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

# Unpacks download $1 into pack dir $2. $3 names a lone .bsp
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
	*://gamebanana.com/* | *://www.gamebanana.com/*) gamebanana "$url" || return 1 ;;
	esac
	say "downloading $url"
	tmp=$(mktemp -d "$DOWNLOADS/.tmp.XXXXXX")
	got=$(curl -fsSL -S --retry 2 -m 900 -o "$tmp/download" -w '%{url_effective}' "$dl_url" 2>"$TMP/err") || {
		say "$url: download failed: $(cat "$TMP/err")"
		rm -rf "$tmp"
		return 1
	}
	if [ -n "$dl_md5" ] && [ "$(md5sum "$tmp/download" | cut -d ' ' -f 1)" != "$dl_md5" ]; then
		say "$url: the download doesn't match GameBanana's checksum"
		rm -rf "$tmp"
		return 1
	fi
	file=${got%%\?*}
	file=${file##*/}
	file=${file%.*}
	[ -n "$title" ] || title=$file
	mkdir "$tmp/pack"
	unpack "$tmp/download" "$tmp/pack" "$(lower "$file")" || {
		say "$url: not installed"
		rm -rf "$tmp"
		return 1
	}
	if [ -z "$name" ]; then
		name=$(clean_name "$title")
		[ -n "$name" ] || name=pack
		base=$name i=2
		while [ -e "$DOWNLOADS/$name" ]; do
			name=$base-$i i=$((i + 1))
		done
	fi
	printf '%s\n' "$url" >"$tmp/pack/.source"
	[ "$dl_url" != "$url" ] && printf 'file %s\n' "$dl_url" >>"$tmp/pack/.source"
	printf 'downloaded %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$tmp/pack/.source"
	rm -rf "${DOWNLOADS:?}/$name"
	mv "$tmp/pack" "$DOWNLOADS/$name"
	rm -rf "$tmp"
	say "$url: installed as downloads/$name ($(find "$DOWNLOADS/$name/maps" -name '*.bsp' 2>/dev/null | wc -l) maps)"
	echo "$name"
}

# The list ------------------------------------------------------------------------------

# entries: <pack dir> <tab> <maps filter, empty = all>. keep: downloads this server uses
: >"$TMP/entries" && : >"$TMP/excludes" && : >"$TMP/keep" && : >"$TMP/fastdl"
entry() { printf '%s\t%s\n' "$1" "$2" >>"$TMP/entries"; }

# One token per line, comments dropped, with tokens like de_* left as they are
set -f
sed 's/#.*//' "$LIST" | while IFS= read -r line; do
	# shellcheck disable=SC2086 # split into tokens
	[ -n "$line" ] && printf '%s\n' $line
done >"$TMP/tokens"
set +f

while IFS= read -r t; do
	[ -n "$t" ] || continue
	case $t in
	-*) printf '%s\n' "${t#-}" >>"$TMP/excludes" ;;
	'*')
		for d in "$PACKS"/*/; do
			[ -d "$d" ] && entry "${d%/}" ""
		done
		;;
	*://*)
		name=
		case $t in
		[A-Za-z0-9_.-]*=*://*)
			name=$(clean_name "${t%%=*}")
			t=${t#*=}
			;;
		esac
		if got=$(fetch "$t" "$name"); then
			printf '%s\n' "$got" >>"$TMP/keep"
			entry "$DOWNLOADS/$got" ""
		elif [ -n "$name" ] && [ -f "$DOWNLOADS/$name/.source" ] && [ -z "$(users "$name")" ]; then
			# This server's URL changed and the new one failed: keep the old one for now
			say "$name: using the copy already there"
			printf '%s\n' "$name" >>"$TMP/keep"
			entry "$DOWNLOADS/$name" ""
		fi
		;;
	*)
		p=${t%%/*} filter=
		[ "$p" != "$t" ] && filter=${t#*/}
		if [ "$p" = default ]; then
			entry "$DEFAULT" "$filter"
		elif [ -d "$PACKS/$p" ]; then
			entry "$PACKS/$p" "$filter"
		else
			say "warning: $p: no such pack (packs/$p)"
		fi
		;;
	esac
done <"$TMP/tokens"

# Downloads nobody lists any more. In a shared library, by every server's list
manifests=$TMP/keep
if [ -n "$SHARED" ]; then
	if [ -n "$SERVER" ]; then
		mkdir -p "$LIB/servers"
		cat "$TMP/keep" >"$LIB/servers/$SERVER"
		manifests=$(printf '%s\n' "$LIB"/servers/*)
	else
		manifests=
		say "shared library without FASTDL_URL or SERVER_NAME: downloads aren't cleaned up"
	fi
fi
if [ -n "$manifests" ]; then
	# shellcheck disable=SC2086 # file names without spaces
	sort -u $manifests >"$TMP/used"
	for s in "$DOWNLOADS"/*/.source; do
		[ -f "$s" ] || continue
		d=${s%/.source}
		grep -qxF -e "${d##*/}" "$TMP/used" && continue
		say "downloads/${d##*/} ($(head -n 1 "$s")) isn't listed any more: deleting it"
		rm -rf "$d"
	done
fi

# Links ---------------------------------------------------------------------------------

# Take down the last run's links
if [ -f "$LINKS" ]; then
	while IFS= read -r r; do
		[ -L "$GAME/$r" ] && rm -f "$GAME/$r"
	done <"$LINKS"
fi
: >"$TMP/links" && : >"$TMP/maps"

# Volumes made before the default pack have its maps as files in cstrike: remove them where
# they're the same as the image's, so the default pack (or leaving it out) decides
moved=0
: >"$TMP/default"
cd "$DEFAULT" 2>/dev/null && find maps overviews -type f >"$TMP/default"
while IFS= read -r r; do
	if [ -f "$GAME/$r" ] && [ ! -L "$GAME/$r" ] && cmp -s "$DEFAULT/$r" "$GAME/$r"; then
		rm -f "$GAME/$r" && moved=$((moved + 1))
	fi
done <"$TMP/default"
[ $moved = 0 ] || say "$moved default map files in cstrike replaced by the default pack"

excluded() {
	while IFS= read -r g; do
		# shellcheck disable=SC2254 # a pattern
		case $1 in $g) return 0 ;; esac
	done <"$TMP/excludes"
	return 1
}

# Maps of pack $1 in cycle order: its mapcycle.txt first, then the rest by name
cycle_order() {
	{
		[ -f "$1/mapcycle.txt" ] && sed 's/[[:space:]].*//; /^$/d; /^\/\//d' "$1/mapcycle.txt"
		find "$1/maps" -maxdepth 1 -type f -name '*.bsp' 2>/dev/null | sed 's|.*/||; s|\.bsp$||' | sort
	} | awk '!seen[$0]++'
}

while IFS="$(printf '\t')" read -r pack filter; do
	case $pack in
	"$DEFAULT") label=default ;;
	*) label=${pack#"$LIB"/} ;;
	esac
	linked=0 maps=0 kept=0 out=0 dup=0
	cd "$pack" || continue
	find . -type f ! -path '*/.*' | sed 's|^\./||' | sort >"$TMP/files"
	: >"$TMP/packmaps"
	while IFS= read -r r; do
		case $r in
		*/*) case " $CONTENT " in *" ${r%%/*} "*) ;; *) continue ;; esac ;;
		*.wad | *.WAD) ;;
		*) continue ;;
		esac
		# A map's own files go with it
		map=
		case $r in
		maps/*.* | overviews/*.*)
			b=${r##*/}
			b=${b%.*}
			b=${b%_detail}
			[ -f "maps/$b.bsp" ] && map=$b
			;;
		esac
		if [ -n "$map" ]; then
			# shellcheck disable=SC2254 # a pattern
			if excluded "$map" || { [ -n "$filter" ] && case $map in $filter) false ;; *) true ;; esac; }; then
				[ "$r" = "maps/$map.bsp" ] && out=$((out + 1))
				continue
			fi
		fi
		dest=$GAME/$r
		if [ -L "$dest" ]; then
			dup=$((dup + 1))
			continue
		elif [ -e "$dest" ]; then
			kept=$((kept + 1))
			continue
		fi
		if [ "$pack" = "$DEFAULT" ]; then
			target=$DEFAULT/$r
		elif [ -n "$SHARED" ]; then
			target=$pack/$r
		else
			# Relative, so the link works on the host too (./cstrike next to ./data)
			target=$(up "$r")../data/${pack#"$DATA"/}/$r
		fi
		if ! mkdir -p "${dest%/*}" || ! ln -s "$target" "$dest"; then continue; fi
		printf '%s\n' "$r" >>"$TMP/links"
		# What players may download: not the default pack, they have it
		[ "$pack" != "$DEFAULT" ] && printf '%s\t%s\n' "${pack#"$LIB"/}" "$r" >>"$TMP/fastdl"
		linked=$((linked + 1))
		if [ "$r" = "maps/$map.bsp" ]; then
			maps=$((maps + 1))
			printf '%s\n' "$map" >>"$TMP/packmaps"
		fi
	done <"$TMP/files"
	cycle_order "$pack" | grep -xF -f "$TMP/packmaps" >>"$TMP/maps"
	msg="$label: $maps maps, $linked files"
	[ $out = 0 ] || msg="$msg, $out maps left out"
	[ $dup = 0 ] || msg="$msg, $dup already from a pack before it"
	[ $kept = 0 ] || msg="$msg, $kept already in cstrike (kept those)"
	say "$msg"
done <"$TMP/entries"

cat "$TMP/links" >"$LINKS"

if on "${MAPCYCLE:-1}"; then
	# Every map once, in packlist order
	awk '!seen[$0]++' "$TMP/maps" >"$CYCLE"
	say "map cycle: $(wc -l <"$CYCLE") maps (packs_mapcycle.txt)"
else
	rm -f "$CYCLE"
fi

# FastDL: fastdl/<server>/, laid out like cstrike, links to the files this server uses.
# Relative, so they work wherever the library is mounted (the web server's side too).
# Built next to the old one and swapped in
if [ -n "${FASTDL_URL:-}" ] && [ -n "$SERVER" ]; then
	new=$LIB/fastdl/.new.$SERVER
	rm -rf "$new" && mkdir -p "$new"
	n=0
	while IFS="$(printf '\t')" read -r src r; do
		case $r in */*) mkdir -p "$new/${r%/*}" ;; esac
		ln -s "$(up "$r")../../$src/$r" "$new/$r" && n=$((n + 1))
	done <"$TMP/fastdl"
	chmod -R a+rX "$new"
	rm -rf "$LIB/fastdl/.old.$SERVER"
	[ -e "$LIB/fastdl/$SERVER" ] && mv "$LIB/fastdl/$SERVER" "$LIB/fastdl/.old.$SERVER"
	mv "$new" "$LIB/fastdl/$SERVER"
	rm -rf "$LIB/fastdl/.old.$SERVER"
	say "fastdl: $n files in ${LIB#/opt/hlds/}/fastdl/$SERVER, at ${FASTDL_URL%/}/"
	[ ${#FASTDL_URL} -le 127 ] || say "warning: FASTDL_URL is over 127 characters, the engine cuts it"
fi
