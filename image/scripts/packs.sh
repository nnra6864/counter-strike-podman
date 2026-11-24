#!/bin/sh
# Packs: maps, AMX Mod X plugins, and anything else laid out like cstrike (models, sounds,
# sprites, wads), each in its own dir or archive, linked into cstrike. Run by the entrypoint
# on every start, and by hand after editing the list, while the server runs (new maps and
# plugins work from the next map change):
#
#   podman exec <container> cs reload
#   podman exec <container> cs save <download> [dir]      keep a download in packs/
#   podman exec <container> cs tags                       every tag and what has it
#   packs.sh tagnames | tag <name> <tag>...               for cs save -t and its picker
#   packs.sh autotags <name> <path>                       the tags cs save starts with
#   podman exec <container> cs remove <pack or map>       delete a pack, and it from the tags
#
# data/packlist says which packs, in order; the first one wins a file two packs have. One
# per line, # for comments:
#   default        the maps CS ships with (kept in the image)
#   mypack         packs/mypack in the library, yours: a dir laid out like cstrike, or an
#                  archive (mypack.zip, .rar, .7z), a .bsp, .sma or .amxx
#   maps/mypack    packs/maps/mypack: dirs that aren't packs just group them
#   maps           every pack in packs/maps
#   maps/de_*      the packs in it with these names
#   mypack/de_*    only these maps from it (and its other files)
#   fy_snow        a pack or a map by name, wherever it is in packs/ (fy_*: patterns)
#   @snow          everything with this tag in the library's tags file (see Tags below)
#   @snow+arena    everything with both
#   -@xmas         leave out everything with this tag
#   *              every pack in packs/
#   -cs_*          leave these maps out, whichever pack has them, and packs by that name
#   URL            downloaded into downloads/ once: a GameBanana page
#                  (gamebanana.com/mods/<id>), or a direct link to a .zip, .rar, .7z, .bsp,
#                  .sma or .amxx
#   name=URL       the same, into downloads/name
# A download no server lists any more is deleted. Your own packs never are.
#
# Archives in packs/ are unpacked into .cache/ in the library, and again when they change.
# Where a pack came from: a URL in a zip's comment (zip -z), or in a .url file next to it.
#
# Plugins: a pack's addons/amxmodx/scripting/*.sma are compiled (with its include/), its
# plugins linked, and added to amxmodx's plugins.ini, in packlist order, between "; packs:"
# lines. AMXX_PLUGIN_<NAME>=0 still turns one off. Configs (addons/amxmodx/configs, any
# .cfg or .ini) are copied once instead of linked, so each server can change its own.
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
# cstrike/packs_links.txt. A run changes only the links that differ from the last one's.

GAME=/opt/hlds/cstrike
DATA=/opt/hlds/data
DEFAULT=/opt/hlds/packs/default
LIST=$DATA/packlist
LINKS=$GAME/packs_links.txt
CYCLE=$GAME/packs_mapcycle.txt
# Where a pack's files may go in cstrike, besides *.wad at its top
CONTENT="maps models sound sprites gfx overviews resource addons"
# What a file in packs/ can be
PACKFILES="zip rar 7z bsp sma amxx"
# Bump when lay_out changes, so archives in packs/ are unpacked again
LAYOUT=2
AMXXPC=/opt/hlds/cstrike_defaults/addons/amxmodx/scripting
PLUGINS_INI=$GAME/addons/amxmodx/configs/plugins.ini

say() { echo "[packs] $*" >&2; }
. /opt/hlds/common.sh

if [ -d /opt/hlds/library ]; then
	LIB=/opt/hlds/library SHARED=1
else
	LIB=$DATA SHARED=
fi
PACKS=$LIB/packs
DOWNLOADS=$LIB/downloads
CACHE=$LIB/.cache

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

# Commands that only read the library: no lock, and nothing written into it (a library
# that isn't mounted isn't started afresh in data/)
READONLY=
case ${1:-} in
tags | tagnames | autotags) READONLY=1 ;;
remove) [ "${2:-}" = --dry ] && READONLY=1 ;;
esac
if [ -n "$READONLY" ]; then
	if [ ! -d "$PACKS" ]; then
		say "no library: ${PACKS#/opt/hlds/} is missing (is it mounted?)"
		exit 1
	fi
else
	mkdir -p "$DATA" "$PACKS" "$DOWNLOADS" "$CACHE"
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# One run at a time per library: several servers, or a start and `cs reload` at once.
# cs save takes it after its file is picked, so nobody waits on the picker
lock() {
	command -v flock >/dev/null || return 0
	exec 9>"$LIB/.lock"
	if ! flock -w 1800 9; then
		say "another run has held ${LIB#/opt/hlds/}/.lock for 30 minutes: giving up. If nothing"
		say "  is running (podman exec <container> ps), delete the file"
		exit 1
	fi
	# What a run that died left behind: nobody else is running now
	rm -rf "$DOWNLOADS"/.tmp.* "$CACHE"/.tmp.*
}
[ -n "$READONLY" ] || [ "${1:-}" = save ] || lock

if [ -z "$READONLY" ] && [ ! -f "$LIST" ]; then
	cat >"$LIST" <<-'EOF'
	# The packs this server uses, in order: the first one wins a file two packs have.
	# After editing: podman exec <container> cs reload   (new maps work from the next map change)
	#
	#   default        the maps CS ships with
	#   mypack         packs/mypack: a dir, or mypack.zip/.rar/.7z/.bsp/.sma/.amxx
	#   maps/mypack    packs/maps/mypack (maps/ only groups them)
	#   fy_snow        a pack or a map by name, wherever it is in packs/
	#   @snow          everything with this tag (the tags file, next to packs/)
	#   @snow+arena    with both tags. -@xmas: leave them out
	#   maps           every pack in packs/maps
	#   mypack/de_*    only these maps from it
	#   *              every pack in packs/
	#   -cs_*          leave these maps (or packs) out
	#   https://gamebanana.com/mods/<id>, or a direct link to a .zip/.rar/.7z/.bsp/.sma/.amxx
	#   name=https://...   the same, as downloads/name
	#
	# Keep a download in packs/, its URL in the zip's comment:
	#   podman exec <container> cs save <download> [dir]
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
			dl_url=$gb_url dl_md5=$gb_md5 title=$gb_title
		else
			gamebanana "$url" || return 1
		fi
		;;
	esac
	say "downloading $url"
	tmp=$(mktemp -d "$DOWNLOADS/.tmp.XXXXXX")
	got=$(curl -fsSL -S --retry 2 -m 900 -o "$tmp/download" -D "$tmp/headers" -w '%{url_effective}' "$dl_url" 2>"$TMP/err") || {
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

# The list ------------------------------------------------------------------------------

# entries: <pack dir> <tab> <maps filter, empty = all>. keep: downloads this server uses
: >"$TMP/entries" && : >"$TMP/excludes" && : >"$TMP/xnames" && : >"$TMP/xhit" && : >"$TMP/xpacks" && : >"$TMP/keep" && : >"$TMP/fastdl" && : >"$TMP/plugins"
entry() { printf '%s\t%s\n' "$1" "$2" >>"$TMP/entries"; }

# A file in packs/ that can be a pack
is_pack_file() {
	[ -f "$1" ] || return 1
	case " $PACKFILES " in *" $(lower "${1##*.}") "*) return 0 ;; esac
	return 1
}
# A dir laid out like cstrike. Other dirs in packs/ only group packs
is_pack_dir() {
	[ -d "$1" ] || return 1
	# Own names: the callers' loops use c and f
	for _c in $CONTENT; do [ -d "$1/$_c" ] && return 0; done
	for _f in "$1"/*.wad "$1"/*.WAD; do [ -f "$_f" ] && return 0; done
	return 1
}
# The pack file packs/$1 names: itself, or with an extension
pack_file() {
	is_pack_file "$1" && printf '%s' "$1" && return 0
	for _f in "$1".*; do
		is_pack_file "$_f" && printf '%s' "$_f" && return 0
	done
	return 1
}

# Where a pack came from: a URL in a zip's comment, or in a .url file next to it
origin() {
	{
		case $(lower "$1") in *.zip) unzip -qz "$1" 2>/dev/null ;; esac
		for u in "${1%.*}.url" "$1.url"; do
			[ -f "$u" ] && cat "$u"
		done
	} | grep -o -m 1 '[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]"]*' | head -n 1
}

# Unpacks pack file $1 into $2 in the cache, unless it's there from the same file
unpacked() {
	stamp="$LAYOUT $(stat -c '%s %Y' "$1")"
	[ "$(cat "$2/.stamp" 2>/dev/null)" = "$stamp" ] && return 0
	n=${1##*/}
	tmp=$(mktemp -d "$CACHE/.tmp.XXXXXX")
	mkdir "$tmp/pack"
	if ! unpack "$1" "$tmp/pack" "$(lower "${n%.*}")" "$(lower "${n##*.}")"; then
		say "packs/${1#"$PACKS"/}: not used"
		rm -rf "$tmp"
		return 1
	fi
	o=$(origin "$1")
	[ -n "$o" ] && printf '%s\n' "$o" >"$tmp/pack/.source"
	printf '%s\n' "$stamp" >"$tmp/pack/.stamp"
	mkdir -p "${2%/*}"
	rm -rf "$2"
	mv "$tmp/pack" "$2"
	rm -rf "$tmp"
	say "unpacked packs/${1#"$PACKS"/}${o:+ ($o)}"
}

# Adds pack $1 (a dir, or a file in packs/) with maps filter $2
add_pack() {
	if [ -d "$1" ]; then
		entry "$1" "$2"
	else
		c=$CACHE/packs/${1#"$PACKS"/}
		unpacked "$1" "$c" && entry "$c" "$2"
	fi
}

# Every pack in group dir $1 named like $2 (without its extension), with maps filter $3.
# Groups in it count with all their packs. A subshell, for the recursion
expand() (
	for c in "$1"/*; do
		[ -e "$c" ] || continue
		n=${c##*/}
		if is_pack_file "$c"; then
			n=${n%.*}
		elif ! [ -d "$c" ]; then
			continue
		fi
		# shellcheck disable=SC2254 # a pattern
		case $n in $2) ;; *) continue ;; esac
		if is_pack_file "$c" || is_pack_dir "$c"; then
			add_pack "$c" "$3"
		else
			expand "$c" '*' "$3"
		fi
	done
)

# A packlist line naming packs in packs/: walks it down through groups to a pack, and the
# rest is its maps filter
resolve() (
	dir=$PACKS rest=$1
	while [ -n "$rest" ]; do
		c=${rest%%/*}
		if [ "$c" = "$rest" ]; then rest=; else rest=${rest#*/}; fi
		case $c in
		*'*'* | *'?'* | *'['*)
			expand "$dir" "$c" "$rest"
			return
			;;
		esac
		p=$dir/$c
		if f=$(pack_file "$p"); then
			add_pack "$f" "$rest"
			return
		elif is_pack_dir "$p"; then
			add_pack "$p" "$rest"
			return
		elif [ -d "$p" ]; then
			dir=$p
		else
			say "warning: $1: no such pack (packs/${p#"$PACKS"/})"
			return
		fi
	done
	# A group by itself: every pack in it
	expand "$dir" '*' ""
)

# Tags ----------------------------------------------------------------------------------
# The library's tags file says which packs and maps have which tags, under headers:
#   [tag.snow] fy_snow de_dust2_xmas    what has tag snow (names on the header's line or
#                                       below it, until the next header)
#   [map.fy_snow] winter arena          the tags fy_snow has. [plugin.x] and [pack.x] are
#                                       the same, for reading
#   [tag.competitive] @competitive_maps knife_round   @tag: everything with that tag
# A name is a pack (its file or dir name, wherever it is in packs/), a map in one, or a
# pack's path in packs/ (maps/fy_snow), and can be a pattern (aim_*). The same header
# can come more than once. In the packlist: @snow, @snow+competitive (both), -@xmas

# The index: every pack in packs/ and its maps, one line per map (a pack without maps
# has one, with no map): <path in packs/, no extension> <tab> <name> <tab> <map> <tab>
# <file or dir>
index_walk() (
	for c in "$1"/*; do
		[ -e "$c" ] || continue
		if is_pack_file "$c" || is_pack_dir "$c"; then
			n=${c##*/}
			is_pack_file "$c" && n=${n%.*}
			rel=${c#"$PACKS"/}
			is_pack_file "$c" && rel=${rel%.*}
			pack_maps "$c" | awk -v rel="$rel" -v n="$n" -v c="$c" '
				{ print rel "\t" n "\t" $0 "\t" c; any = 1 }
				END { if (!any) print rel "\t" n "\t\t" c }'
		elif [ -d "$c" ]; then
			index_walk "$c"
		fi
	done
)

# The maps in pack $1: from its dir, the unpacked copy, or the archive's listing (kept in
# the cache with the file's size and time)
pack_maps() {
	if [ -d "$1" ]; then
		find "$1/maps" -maxdepth 1 -type f -name '*.bsp' 2>/dev/null | sed 's|.*/||; s|\.bsp$||' | sort
		return 0
	fi
	n=${1##*/}
	case $(lower "$n") in
	*.bsp) printf '%s\n' "${n%.*}" | tr '[:upper:]' '[:lower:]' && return 0 ;;
	*.sma | *.amxx) return 0 ;;
	esac
	stamp="$LAYOUT $(stat -c '%s %Y' "$1")"
	c=$CACHE/packs/${1#"$PACKS"/}
	if [ "$(cat "$c/.stamp" 2>/dev/null)" = "$stamp" ]; then
		pack_maps "$c"
		return 0
	fi
	l=$CACHE/index/${1#"$PACKS"/}.maps
	if [ "$(head -n 1 "$l" 2>/dev/null)" != "$stamp" ]; then
		# Written next to it and moved: read-only commands write it too, without the lock
		mkdir -p "${l%/*}"
		{
			printf '%s\n' "$stamp"
			LC_ALL=C.UTF-8 bsdtar -tf "$1" 2>/dev/null | sed -n 's|.*/||; s|\.[bB][sS][pP]$||p' | sort -u
		} >"$l.$$" && mv "$l.$$" "$l"
	fi
	tail -n +2 "$l"
}

INDEX=$TMP/index
index() {
	[ -f "$INDEX" ] || index_walk "$PACKS" >"$INDEX"
}

TAGS=$LIB/tags
if [ -n "$READONLY" ] && [ ! -f "$TAGS" ]; then
	: >"$TMP/notags"
	TAGS=$TMP/notags
elif [ ! -f "$TAGS" ]; then
	cat >"$TAGS" <<-'EOF'
	# Tags for the packs in packs/, for packlists to pick them by: @snow, @snow+competitive
	# (both), -@xmas (leave those out). Names on a header's line or below it:
	#
	#   [tag.snow] fy_snow de_dust2_xmas    what has a tag
	#   [map.fy_snow] winter arena          or the tags a map has ([plugin.x], [pack.x] too)
	#   [tag.arena] fy_* aim_*              patterns
	#   [tag.competitive] @competitive_maps knife_round   @tag: all of another tag
	#
	# A name is a pack (its file or dir name, wherever it is in packs/), a map in one, or a
	# pack's path (maps/fy_snow). After editing: podman exec <container> cs tags
	EOF
fi

# The tags cs save starts with for a new pack, by its name and its maps' names. Only what
# this file says is used: the list below is only what it's written with the first time
AUTOTAGS=$LIB/autotags
if [ -n "$READONLY" ] && [ ! -f "$AUTOTAGS" ]; then
	: >"$TMP/noautotags"
	AUTOTAGS=$TMP/noautotags
elif [ ! -f "$AUTOTAGS" ]; then
	cat >"$AUTOTAGS" <<-'EOF'
	# The tags cs save picks for a pack to start with, which the picker shows ticked (and
	# -t replaces). A pack gets a tag when its name or a map in it matches a pattern under
	# the tag's header, on its line or below it. Case doesn't matter:
	#
	#   [tag.snow] *snow* *winter*      fy_snow, de_dust2_winter16
	#
	# Only what's here is used: change it, empty it, add your own.

	[tag.competitive] de_*
	[tag.hostage] cs_*
	[tag.vip] as_*
	[tag.aim] aim_*
	[tag.awp] awp_*
	[tag.fy] fy_*
	[tag.knife] ka_* knife_* 35hp_*
	[tag.zombie] zm_* zp_*
	[tag.zombie-escape] ze_*
	[tag.deathrun] deathrun_* dr_*
	[tag.jail] jail_* jb_*
	[tag.hns] hns_*
	[tag.kz] kz_* bkz_* xc_*
	[tag.bhop] bhop_*
	[tag.surf] surf_*
	[tag.gungame] gg_*
	[tag.fun] fun_* mg_*

	[tag.snow] *snow* *winter*
	[tag.xmas] *xmas* *christmas* *santa*
	[tag.halloween] *halloween*
	EOF
fi

# tags <mode> [arg]: query <a+b>: <file> <tab> <map> of everything with all those tags.
# match <name>: the same for a name. check: warns about names that match nothing.
# list: every tag and what has it
tags() {
	index
	awk -v mode="$1" -v q="${2:-}" -v indexf="$INDEX" '
	function warn(m) { print "[packs] " m > "/dev/stderr" }
	# Mistakes in the file: once, by check
	function bad(m) { if (mode == "check") warn(m) }
	function glob2re(g,    r, i, j, c, n) {
		r = "^"
		n = length(g)
		for (i = 1; i <= n; i++) {
			c = substr(g, i, 1)
			if (c == "*") r = r ".*"
			else if (c == "?") r = r "."
			else if (c == "[" && (j = index(substr(g, i + 1), "]")) > 0) { r = r substr(g, i, j + 1); i += j }
			else if (index(".+^$(){}|\\[]", c)) r = r "\\" c
			else r = r c
		}
		return r "$"
	}
	function matches(m, j,    re) {
		re = glob2re(tolower(m))
		return tolower(iname[j]) ~ re || tolower(imap[j]) ~ re || tolower(irel[j]) ~ re
	}
	function add(t, m) {
		t = tolower(t)
		sub(/^@/, "", t)
		known[t] = 1
		if (!(t in seen)) { seen[t] = 1; torder[++nt] = t }
		mem[t, ++nmem[t]] = m
		where[t, nmem[t]] = hdr
	}
	function set_of(t,    i, j, m, u) {
		if (t in done) return
		done[t] = 1
		for (i = 1; i <= nmem[t]; i++) {
			m = mem[t, i]
			if (m ~ /^@/) {
				u = tolower(substr(m, 2))
				set_of(u)
				for (j = 1; j <= n; j++) if ((u, j) in S) S[t, j] = 1
			} else
				for (j = 1; j <= n; j++) if (matches(m, j)) S[t, j] = 1
		}
	}
	FILENAME == indexf { n++; split($0, f, "\t"); irel[n] = f[1]; iname[n] = f[2]; imap[n] = f[3]; ipath[n] = f[4]; next }
	{ sub(/#.*/, "") }
	{
		for (i = 1; i <= NF; i++) {
			w = $i
			if (w ~ /^\[.*\]$/) {
				h = tolower(substr(w, 2, length(w) - 2))
				k = h
				sub(/\..*$/, "", k)
				key = substr(h, length(k) + 2)
				hdr = w
				if (key == "") hm = "bad"
				else if (k == "tag") hm = "tag"
				else if (k == "map" || k == "plugin" || k == "pack") hm = "item"
				else hm = "bad"
				if (hm == "bad") bad("tags: " w ": not a header like [tag.snow] or [map.fy_snow], skipping what is under it")
				continue
			}
			if (hm == "tag") add(key, w)
			else if (hm == "item") add(w, key)
			else if (hm == "" && !toplevel++) bad("tags: " w ": before any header, skipped")
		}
	}
	END {
		if (mode == "query") {
			np = split(tolower(q), parts, "+")
			for (p = 1; p <= np; p++) {
				if (!(parts[p] in known)) { warn("@" q ": no tag " parts[p] " in the tags file"); exit }
				set_of(parts[p])
			}
			for (j = 1; j <= n; j++) {
				all = 1
				for (p = 1; p <= np; p++) if (!((parts[p], j) in S)) { all = 0; break }
				if (all) print ipath[j] "\t" imap[j]
			}
		} else if (mode == "match") {
			for (j = 1; j <= n; j++) if (matches(q, j)) print ipath[j] "\t" imap[j]
		} else if (mode == "check") {
			for (t in nmem) for (i = 1; i <= nmem[t]; i++) {
				m = mem[t, i]
				if (m ~ /^@/) {
					if (!(tolower(substr(m, 2)) in known)) warn("tags: " where[t, i] ": " m ": no such tag")
					continue
				}
				hit = 0
				for (j = 1; j <= n; j++) if (matches(m, j)) { hit = 1; break }
				if (!hit) warn("tags: " where[t, i] ": " m ": no pack or map by that name in packs/")
			}
		} else if (mode == "list") {
			for (x = 1; x <= nt; x++) {
				t = torder[x]
				set_of(t)
				line = ""
				for (j = 1; j <= n; j++) if ((t, j) in S) line = line " " (imap[j] != "" ? imap[j] : iname[j]) " (" irel[j] ")"
				print t ":" (line == "" ? " nothing" : line)
			}
		}
	}' "$INDEX" "$TAGS"
}

# Adds <file> <tab> <map> lines as entries, a pack's maps together
add_units() {
	awk -F '\t' '
		$1 != last { if (NR > 1) print last "\t" (whole ? "" : maps); last = $1; maps = ""; whole = 0 }
		{ if ($2 == "") whole = 1; else maps = maps (maps == "" ? "" : " ") $2 }
		END { if (NR) print last "\t" (whole ? "" : maps) }' >"$TMP/units"
	while IFS="$(printf '\t')" read -r f m; do
		add_pack "$f" "$m"
	done <"$TMP/units"
}

# Leaves out <file> <tab> <map> lines: their maps, from any pack, and packs without maps
exclude_units() {
	while IFS="$(printf '\t')" read -r f m; do
		if [ -n "$m" ]; then
			printf '%s\n' "$m" >>"$TMP/excludes"
		elif [ -d "$f" ]; then
			printf '%s\n' "$f" >>"$TMP/xpacks"
		else
			printf '%s\n' "$CACHE/packs/${f#"$PACKS"/}" >>"$TMP/xpacks"
		fi
	done
}

# cs save <URL or download> [dir] ----------------------------------------------------
# Keeps a map or plugin in packs/ (packs/maps or packs/plugins by what's in it, unless a dir
# is given) as a zip with its URL in the comment. A URL is downloaded for it, unless a
# packlist has downloaded it already; a download a packlist has can then be named there
# by name instead of by URL. A zip as it came; a .rar or .7z as a zip of the same files.
# Downloads themselves aren't changed: GameBanana's checksum is of them as they came

if [ "${1:-}" = save ]; then
	arg=${2:-}
	if [ -z "$arg" ]; then
		say "usage: cs save <URL or download> [dir in packs/]"
		have=
		for s in "$DOWNLOADS"/*/.source; do
			[ -f "$s" ] || continue
			[ -n "$have" ] || say "downloads from packlists, which can be saved by name:"
			have=1
			d=${s%/.source}
			say "  ${d##*/}  $(head -n 1 "$s")"
		done
		[ -n "$have" ] || say "no downloads from packlists; give a URL"
		exit 1
	fi
	url='' name='' fetched=''
	case $arg in
	*://*)
		url=$arg
		for s in "$DOWNLOADS"/*/.source; do
			[ -f "$s" ] && [ "$(head -n 1 "$s")" = "$url" ] || continue
			d=${s%/.source}
			name=${d##*/}
			break
		done
		;;
	*)
		name=$arg
		case $name in */* | .*) name= ;; esac
		if [ -z "$name" ] || [ ! -f "$DOWNLOADS/$name/.source" ]; then
			say "$arg: no such download. cs save with nothing after it lists them, or give a URL"
			exit 1
		fi
		url=$(head -n 1 "$DOWNLOADS/$name/.source")
		;;
	esac
	# Saved before: a pack with this URL in it
	index
	awk -F '\t' '!seen[$4]++ { print $4 }' "$INDEX" | while IFS= read -r f; do
		[ -f "$f" ] && [ "$(origin "$f")" = "$url" ] && printf '%s\n' "$f"
	done | head -n 1 >"$TMP/have"
	if [ -s "$TMP/have" ]; then
		f=$(cat "$TMP/have")
		say "already saved: packs/${f#"$PACKS"/} is $url"
		n=${f##*/}
		is_pack_file "$f" && n=${n%.*}
		printf '%s\t%s\n' "$n" "${f#"$PACKS"/}"
		exit 0
	fi
	if [ -z "$name" ]; then
		case $url in
		*://gamebanana.com/dl/* | *://www.gamebanana.com/dl/*) ;;
		*://gamebanana.com/* | *://www.gamebanana.com/*)
			SAVING=1 gamebanana "$url" || exit 1
			gb_page=$url gb_url=$dl_url gb_md5=$dl_md5 gb_title=$title
			;;
		esac
		lock
		name=$(SAVING=1 fetch "$url" "") || exit 1
		fetched=1
	else
		lock
	fi
	d=$DOWNLOADS/$name
	group=${3:-}
	if [ -z "$group" ]; then
		if [ -d "$d/maps" ]; then group=maps; elif [ -d "$d/addons/amxmodx" ]; then group=plugins; fi
	fi
	group=${group%/}
	case /$group/ in */../* | */./* | //*) say "$group: not a dir in packs/" && exit 1 ;; esac
	dir=$PACKS${group:+/$group}
	mkdir -p "$dir"
	orig=$(ls "$d/.original" 2>/dev/null | head -n 1)
	tmp=$dir/.tmp.$$.zip
	# A download made only for this goes once it's saved, or if saving fails
	trap 'rm -rf "$TMP" "$tmp"; [ -n "$fetched" ] && rm -rf "$d"' EXIT
	if [ -n "$orig" ]; then
		src=$d/.original/$orig
		md5=$(sed -n 's/^md5 //p' "$d/.source")
		if [ -n "$md5" ] && [ "$(md5sum <"$src" | cut -d ' ' -f 1)" != "$md5" ]; then
			say "$name: downloads/$name/.original/$orig doesn't match GameBanana's checksum any more"
			exit 1
		fi
		# A zip as it is. Anything else into a zip, its files as they are: only a zip can
		# have the URL in it
		case $(head -c 4 "$src" | od -An -t x1 | tr -d ' \n') in
		504b0304) cp "$src" "$tmp" ;;
		52617221 | 377abcaf)
			LC_ALL=C.UTF-8 bsdtar --format zip -cf "$tmp" "@$src" || exit 1
			say "$name: $orig is a ${orig##*.}: saving its files as a zip"
			;;
		*)
			# A lone .bsp, .sma or .amxx, where the game would have it
			case $(lower "$orig") in
			*.bsp) r=maps ;;
			*.sma) r=addons/amxmodx/scripting ;;
			*.amxx) r=addons/amxmodx/plugins ;;
			*) r=. ;;
			esac
			mkdir -p "$TMP/lone/$r" && cp "$src" "$TMP/lone/$r/"
			(cd "$TMP/lone" && LC_ALL=C.UTF-8 bsdtar --format zip -cf "$tmp" -- *) || exit 1
			;;
		esac
	else
		# Downloaded before packs kept the file: a zip of what was unpacked
		(cd "$d" && LC_ALL=C.UTF-8 bsdtar --format zip -cf "$tmp" -- *) || exit 1
		say "$name: the file as it was downloaded isn't kept, saving a zip of its contents"
	fi
	dest=$dir/$name.zip
	rel=${dest#"$PACKS"/}
	if [ -e "$dest" ]; then
		o=$(origin "$dest")
		say "not saved: packs/$rel is already there${o:+, from $o}. Give another dir: cs save $arg <dir>"
		exit 1
	fi
	if [ -n "$(unzip -qz "$tmp" 2>/dev/null)" ]; then
		say "it has a comment already, left as it is: $(unzip -qz "$tmp" | head -n 1)"
	else
		printf '%s\n' "$url" | zip -zq "$tmp"
	fi
	chmod a+r "$tmp"
	mv "$tmp" "$dest"
	say "saved $url"
	say "  as packs/$rel, with the URL in the zip's comment"
	# The maps go by their own names, which a pack of several is named apart from
	m=$(find "$d/maps" -maxdepth 1 -type f -iname '*.bsp' 2>/dev/null | sed 's|.*/||; s|\.[^.]*$||' | sort | tr '\n' ' ')
	[ -z "$m" ] || [ "$m" = "$name " ] || say "  maps in it (for changelevel): ${m% }"
	if [ -n "$fetched" ]; then
		say "  use it by name in a packlist or the tags file: $name"
	else
		say "  in data/packlist, replace the URL with $name: the download goes on the next cs reload"
	fi
	# For cs save -t and -r: the pack's name and its path in packs/
	printf '%s\t%s\n' "$name" "$rel"
	exit 0
fi

# packs tags: every tag and what has it
if [ "${1:-}" = tags ]; then
	tags check
	tags list
	exit 0
fi

# packs tagnames: every tag in the tags file, one per line, for cs save's picker. Read the
# way tags() reads them
if [ "${1:-}" = tagnames ]; then
	awk '
	{ sub(/#.*/, "") }
	{
		for (i = 1; i <= NF; i++) {
			w = $i
			if (w ~ /^\[.*\]$/) {
				h = tolower(substr(w, 2, length(w) - 2))
				k = h
				sub(/\..*$/, "", k)
				key = substr(h, length(k) + 2)
				hm = ""
				if (key != "" && k == "tag") { hm = "tag"; print key }
				else if (key != "" && (k == "map" || k == "plugin" || k == "pack")) hm = "item"
				continue
			}
			if (hm == "item") { w = tolower(w); sub(/^@/, "", w); print w }
		}
	}' "$TAGS" | sort -u
	exit 0
fi

# packs autotags <name> <path in packs/>: the tags the autotags file gives this pack, one
# per line, for cs save to start with
if [ "${1:-}" = autotags ]; then
	set -f
	names=$(lower "${2:-}")
	f=$PACKS/${3:-}
	[ -n "${3:-}" ] && [ -e "$f" ] && names="$names $(pack_maps "$f" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
	awk '
	function bad(m) { print "[packs] " m > "/dev/stderr" }
	{ sub(/#.*/, "") }
	{
		for (i = 1; i <= NF; i++) {
			w = tolower($i)
			if (w ~ /^\[.*\]$/) {
				t = substr(w, 2, length(w) - 2)
				if (t ~ /^tag\.[a-z0-9_-]+$/) t = substr(t, 5)
				else { bad("autotags: " $i ": not a header like [tag.snow], skipping what is under it"); t = "-" }
				continue
			}
			if (t == "") { if (!top++) bad("autotags: " $i ": before any header, skipped") }
			else if (t != "-") print t "\t" w
		}
	}' "$AUTOTAGS" | while IFS="$(printf '\t')" read -r t p; do
		for n in $names; do
			# shellcheck disable=SC2254 # p is a pattern
			case $n in $p) printf '%s\n' "$t" && break ;; esac
		done
	done | awk '!seen[$0]++'
	exit 0
fi

# packs tag <name> <tag>...: adds name to each [tag.x] in the tags file, as a line of its
# own where it sorts among the names below the header (or on the header's line, if that's
# where its names are). A tag that isn't there yet gets a [tag.x] before the first tag
# that sorts after it, or at the end
if [ "${1:-}" = tag ]; then
	name=${2:-}
	[ -n "$name" ] && [ $# -gt 2 ] || { say "usage: packs.sh tag <name> <tag>..." && exit 1; }
	shift 2
	for t in "$@"; do
		t=$(lower "$t")
		t=${t#@}
		case $t in
		'') continue ;;
		*[!a-z0-9_-]*) say "$t: not a tag name (letters, digits, _ and -): skipped" && continue ;;
		esac
		rc=0
		awk -v n="$name" -v t="$t" '
		function hdr(s,    w) {
			sub(/#.*/, "", s)
			if (!match(s, /^[ \t]*\[[^ \t]*\]/)) return ""
			w = substr(s, RSTART, RLENGTH)
			gsub(/[ \t]/, "", w)
			return tolower(substr(w, 2, length(w) - 2))
		}
		function words(s, a) { sub(/#.*/, "", s); return split(s, a) }
		{ L[NR] = $0; H[NR] = hdr($0) }
		END {
			ln = tolower(n)
			for (i = 1; i <= NR; i++) if (H[i] == "tag." t) { s = i; break }
			if (!s) {
				for (i = 1; i <= NR; i++) if (H[i] ~ /^tag\./ && substr(H[i], 5) > t) { at = i; break }
				for (i = 1; i <= NR; i++) {
					if (i == at) { print "[tag." t "]"; print n; print "" }
					print L[i]
				}
				if (!at) {
					if (NR && L[NR] !~ /^[ \t]*$/) print ""
					print "[tag." t "]"
					print n
				}
				exit 0
			}
			e = NR + 1
			for (i = s + 1; i <= NR; i++) if (H[i] != "") { e = i; break }
			for (i = s; i < e; i++) {
				k = words(L[i], w)
				for (j = (i == s ? 2 : 1); j <= k; j++) if (tolower(w[j]) == ln) exit 3
			}
			last = 0
			at = 0
			for (i = s + 1; i < e; i++) if (words(L[i], w)) { last = i; if (!at && tolower(w[1]) > ln) at = i }
			before = 0
			after = 0
			hl = ""
			if (last) { if (at) before = at; else after = last }
			else if ((k = words(L[s], w)) > 1) {
				hl = w[1]
				put = 0
				for (j = 2; j <= k; j++) {
					if (!put && tolower(w[j]) > ln) { hl = hl " " n; put = 1 }
					hl = hl " " w[j]
				}
				if (!put) hl = hl " " n
				if ((c = index(L[s], "#"))) hl = hl "  " substr(L[s], c)
			} else after = s
			for (i = 1; i <= NR; i++) {
				if (i == before) print n
				print (i == s && hl != "" ? hl : L[i])
				if (i == after) print n
			}
		}' "$TAGS" >"$TMP/tags.new" || rc=$?
		case $rc in
		0)
			# Written over, not replaced: the file keeps its owner and mode
			cat "$TMP/tags.new" >"$TAGS"
			say "tagged $name: $t"
			;;
		3) say "$name has tag $t already" ;;
		*) say "tags: couldn't add $name to $t" && exit 1 ;;
		esac
	done
	exit 0
fi

# packs remove [--dry] <pack or map>: deletes a pack from packs/ (and its .url file), and
# takes it out of the tags file: its name, its path and its maps' names under [tag.x], and
# [map.x]/[pack.x]/[plugin.x] sections for them. Patterns (de_*) and @tags stay. --dry
# says what would go. cs remove asks first
if [ "${1:-}" = remove ]; then
	dry=
	[ "${2:-}" = --dry ] && dry=1 && shift
	arg=${2:-}
	[ -n "$arg" ] || { say "usage: cs remove [-r] [-y] <pack or map>" && exit 1; }
	a=$(lower "${arg%/}")
	a=${a#packs/}
	case $a in *.zip | *.rar | *.7z | *.bsp | *.sma | *.amxx) a=${a%.*} ;; esac
	index
	awk -F '\t' -v a="$a" 'tolower($1) == a || tolower($2) == a || tolower($3) == a { print $4 }' "$INDEX" |
		sort -u >"$TMP/hits"
	case $(wc -l <"$TMP/hits") in
	0) say "$arg: no pack or map by that name in packs/" && exit 1 ;;
	1) ;;
	*)
		say "$arg: in more than one pack, give the one to remove by its path:"
		while IFS= read -r f; do say "  cs remove ${f#"$PACKS"/}"; done <"$TMP/hits"
		exit 1
		;;
	esac
	f=$(cat "$TMP/hits")
	rel=${f#"$PACKS"/}
	n=${f##*/} r=$rel
	if is_pack_file "$f"; then n=${n%.*} r=${r%.*}; fi
	# Its maps, unless another pack has one by the same name: that one keeps its tags
	maps=$(awk -F '\t' -v f="$f" '
		$3 != "" { if ($4 == f) mine[$3] = 1; else other[$3] = 1 }
		END { for (m in mine) if (!(m in other)) print m }' "$INDEX" | sort | tr '\n' ' ')
	files=$f
	for u in "${f%.*}.url" "$f.url"; do
		[ -f "$u" ] && [ "$u" != "$f" ] && files="$files
$u"
	done
	# The tags file without them, and what went (<section> <tab> <name>)
	awk -v names="$(lower "$n $r $maps")" -v rep="$TMP/tagrep" '
	function hdr(s,    w) {
		sub(/#.*/, "", s)
		if (!match(s, /^[ \t]*\[[^ \t]*\]/)) return ""
		w = substr(s, RSTART, RLENGTH)
		gsub(/[ \t]/, "", w)
		return tolower(substr(w, 2, length(w) - 2))
	}
	function out(s) {
		if (s ~ /^[ \t]*$/) { if (blank++) return } else blank = 0
		print s
	}
	BEGIN { k = split(names, a, " "); for (i = 1; i <= k; i++) N[a[i]] = 1 }
	{
		h = hdr($0)
		if (h != "") {
			sec = h
			kind = h
			sub(/\..*$/, "", kind)
			drop = (kind == "map" || kind == "pack" || kind == "plugin") && (substr(h, length(kind) + 2) in N)
			if (drop) print "[" h "]\t(all of it)" >rep
		}
		if (drop) next
		if (sec !~ /^tag\./) { out($0); next }
		c = index($0, "#")
		body = c ? substr($0, 1, c - 1) : $0
		com = c ? substr($0, c) : ""
		k = split(body, w)
		line = ""
		gone = 0
		for (j = 1; j <= k; j++) {
			if (!(h != "" && j == 1) && (tolower(w[j]) in N)) {
				print "[" sec "]\t" w[j] >rep
				gone = 1
				continue
			}
			line = line (line == "" ? "" : " ") w[j]
		}
		if (!gone) { out($0); next }
		# A line that had only them goes
		if (line == "" && com == "") next
		out(line (com == "" ? "" : (line == "" ? "" : "  ") com))
	}' "$TAGS" >"$TMP/tags.new" || { say "tags: couldn't read $TAGS" && exit 1; }
	if [ -n "$dry" ]; then
		o=$(origin "$f")
		say "packs/$rel${o:+ ($o)}"
		[ -z "$maps" ] || say "  maps: ${maps% }"
		[ -d "$f" ] && say "  a dir: everything in it goes"
		printf '%s\n' "$files" | tail -n +2 | while IFS= read -r u; do say "  and ${u#"$PACKS"/}"; done
		if [ -s "$TMP/tagrep" ]; then
			say "  and from the tags file:"
			while IFS="$(printf '\t')" read -r sec w; do say "    $sec $w"; done <"$TMP/tagrep"
		fi
		# Names this server's packlist uses for it
		set -f
		for w in $(sed 's/#.*//' "$LIST"); do
			case " $(lower "$n $r $maps") " in *" $(lower "$w") "*) say "  data/packlist names it ($w): take that out too" ;; esac
		done
		set +f
		[ -z "$SHARED" ] || say "  the library is shared: servers that use it lose it at their next reload"
		exit 0
	fi
	printf '%s\n' "$files" | while IFS= read -r u; do rm -rf -- "$u"; done
	say "removed packs/$rel"
	if [ -s "$TMP/tagrep" ]; then
		cat "$TMP/tags.new" >"$TAGS"
		t=$(cut -f 1 "$TMP/tagrep" | sort -u | tr '\n' ' ')
		say "  and from the tags file: ${t% }"
	fi
	exit 0
fi

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
	-@*) tags query "${t#-@}" | exclude_units ;;
	-*)
		# Maps by this name or pattern from any pack (the default one too), and packs by it:
		# all their maps, or the whole pack when it has none
		printf '%s\n' "${t#-}" >>"$TMP/excludes"
		printf '%s\n' "${t#-}" >>"$TMP/xnames"
		tags match "${t#-}" | exclude_units
		;;
	@*) tags query "${t#@}" | add_units ;;
	'*') expand "$PACKS" '*' "" ;;
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
	default) entry "$DEFAULT" "" ;;
	default/*) entry "$DEFAULT" "${t#default/}" ;;
	*/*) resolve "$t" ;;
	*)
		# A group dir by itself is all of it. Otherwise a pack or a map by name, wherever
		# it is in packs/
		if [ -d "$PACKS/$t" ] || pack_file "$PACKS/$t" >/dev/null; then
			resolve "$t"
		else
			tags match "$t" >"$TMP/match"
			if [ -s "$TMP/match" ]; then
				add_units <"$TMP/match"
			else
				if tags list 2>/dev/null | grep -qi "^$t:"; then
					say "warning: $t: no pack or map by that name in packs/; the tag is @$t"
				else
					say "warning: $t: no pack or map by that name in packs/"
				fi
			fi
		fi
		;;
	esac
done <"$TMP/tokens"
# Typos in the tags file, when a packlist uses it
grep -q '^-\{0,1\}@' "$TMP/tokens" && tags check

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

# Unpacked archives whose file is gone from packs/ (moved, renamed or deleted)
if [ -d "$CACHE/packs" ]; then
	find "$CACHE/packs" -type f -name .stamp | while IFS= read -r s; do
		d=${s%/.stamp}
		[ -f "$PACKS/${d#"$CACHE"/packs/}" ] && continue
		rm -rf "$d"
	done
	find "$CACHE/packs" -mindepth 1 -type d -empty -delete
fi
if [ -d "$CACHE/index" ]; then
	find "$CACHE/index" -type f -name '*.maps' | while IFS= read -r l; do
		r=${l#"$CACHE"/index/}
		[ -f "$PACKS/${r%.maps}" ] || rm -f "$l"
	done
	find "$CACHE/index" -mindepth 1 -type d -empty -delete
fi

# Links ---------------------------------------------------------------------------------

# What's linked is worked out first and compared with what's there, and only the
# difference is changed: a reload that changes nothing touches nothing, and maps the
# server has don't go missing while it runs
TAB=$(printf '\t')

# Volumes made before the default pack have its maps as files in cstrike: remove them where
# they're the same as the image's, so the default pack (or leaving it out) decides
# The same file, or a text file (.txt, .res) that only has other line endings (older
# volumes have CRLF)
same() {
	cmp -s "$1" "$2" && return 0
	case $1 in *.txt | *.res) ;; *) return 1 ;; esac
	[ "$(tr -d '\r' <"$1" | md5sum)" = "$(tr -d '\r' <"$2" | md5sum)" ]
}
moved=0
: >"$TMP/default"
cd "$DEFAULT" 2>/dev/null && find maps overviews -type f >"$TMP/default"
while IFS= read -r r; do
	if [ -f "$GAME/$r" ] && [ ! -L "$GAME/$r" ] && same "$DEFAULT/$r" "$GAME/$r"; then
		rm -f "$GAME/$r" && moved=$((moved + 1))
	fi
done <"$TMP/default"
[ $moved = 0 ] || say "$moved default map files in cstrike replaced by the default pack"

# Maps of pack $1 in cycle order: its mapcycle.txt first, then the rest by name
cycle_order() {
	{
		[ -f "$1/mapcycle.txt" ] && sed 's/[[:space:]].*//; /^$/d; /^\/\//d' "$1/mapcycle.txt"
		find "$1/maps" -maxdepth 1 -type f -name '*.bsp' 2>/dev/null | sed 's|.*/||; s|\.bsp$||' | sort
	} | awk '!seen[$0]++'
}

# Makes the links in file $2 (<path> <tab> <target>) under dir $1, a few forks per dir
# rather than per link: ln -t names a link after its target. Replaces links there
link_all() {
	[ -s "$2" ] || return 0
	rm -rf "$TMP/lnd" && mkdir "$TMP/lnd"
	awk -F '\t' -v one="$TMP/lnd/one" '
		{
			b = $1; sub(/.*\//, "", b)
			t = $2; sub(/.*\//, "", t)
			if (b != t) { print > one; next }
			d = $1
			if (!sub(/\/[^\/]*$/, "", d)) d = "."
			print d "\t" $2
		}' "$2" | sort -t "$TAB" -k 1,1 -s | awk -F '\t' -v out="$TMP/lnd" '
		$1 != d { if (n) close(f); d = $1; f = out "/" ++n; print n "\t" d > (out "/dirs") }
		{ print $2 > f }'
	[ -f "$TMP/lnd/dirs" ] && while IFS="$TAB" read -r k d; do
		mkdir -p "$1/$d" && tr '\n' '\0' <"$TMP/lnd/$k" | xargs -0 ln -sfn -t "$1/$d" --
	done <"$TMP/lnd/dirs"
	[ -f "$TMP/lnd/one" ] && while IFS="$TAB" read -r r t; do
		case $r in */*) mkdir -p "$1/${r%/*}" ;; esac
		ln -sfn -- "$t" "$1/$r"
	done <"$TMP/lnd/one"
	return 0
}

# Compiles plugin source $1 with the image's amxxpc and the pack's include dir $2, into the
# cache (once for the same source, includes and amxxpc), and prints the .amxx
compile() {
	n=${1##*/}
	n=${n%.*}
	key=$({
		md5sum <"$AMXXPC/amxxpc32.so"
		cat "$1"
		[ -d "$2" ] && find "$2" -type f -print0 | sort -z | xargs -0 -r cat
	} | md5sum | cut -c 1-32)
	o=$CACHE/amxx/$key/$n.amxx
	[ -f "$o" ] && printf '%s\n' "$o" && return 0
	tmp=$(mktemp -d "$CACHE/.tmp.XXXXXX")
	if (cd "$AMXXPC" && ./amxxpc "$1" -o"$tmp/$n.amxx" ${2:+-i"$2/"}) >"$tmp/log" 2>&1 && [ -f "$tmp/$n.amxx" ]; then
		mkdir -p "${o%/*}"
		mv "$tmp/$n.amxx" "$o"
		chmod a+r "$o"
		rm -rf "$tmp"
		say "compiled $n.sma"
		printf '%s\n' "$o"
		return 0
	fi
	say "$n.sma doesn't compile:"
	grep -i 'error' "$tmp/log" | head -n 10 | sed 's/^/[packs]   /' >&2
	rm -rf "$tmp"
	return 1
}

# AMX Mod X files only go in when cstrike has it: the entrypoint installs it whole into a
# volume without an addons/amxmodx, which a link there would stop
amxx_ok=
[ -f "$PLUGINS_INI" ] && amxx_ok=1

# Each pack in packlist order: packinfo <n> <dir> <maps filter> <label> <left out>,
# allfiles <n> <path in cstrike> <file> (plugins compiled from source first: they win over
# a .amxx the pack has), cycles <n> <map> (its maps in cycle order)
: >"$TMP/packinfo" && : >"$TMP/allfiles" && : >"$TMP/cycles"
i=0
while IFS="$TAB" read -r pack filter; do
	i=$((i + 1))
	case $pack in
	"$DEFAULT") label=default ;;
	"$CACHE"/packs/*) label=packs/${pack#"$CACHE"/packs/} ;;
	*) label=${pack#"$LIB"/} ;;
	esac
	[ -f "$pack/.source" ] && label="$label ($(head -n 1 "$pack/.source"))"
	x=0
	grep -qxF -e "$pack" "$TMP/xpacks" && x=1
	printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$pack" "$filter" "$label" "$x" >>"$TMP/packinfo"
	[ $x = 0 ] && cd "$pack" || continue
	for f in addons/amxmodx/scripting/*.sma; do
		[ -f "$f" ] && [ -n "$amxx_ok" ] || continue
		n=${f##*/}
		n=${n%.*}
		inc=
		[ -d addons/amxmodx/scripting/include ] && inc=$pack/addons/amxmodx/scripting/include
		if a=$(compile "$pack/$f" "$inc"); then
			printf '%s\taddons/amxmodx/plugins/%s.amxx\t%s\n' "$i" "$n" "$a"
		fi
	done >>"$TMP/allfiles"
	find . -type f ! -path '*/.*' | sed 's|^\./||' | sort |
		awk -v i="$i" -v p="$pack" '{ print i "\t" $0 "\t" p "/" $0 }' >>"$TMP/allfiles"
	cycle_order "$pack" | awk -v i="$i" '{ print i "\t" $0 }' >>"$TMP/cycles"
done <"$TMP/entries"

# What cstrike has where packs put files: <l|f> <path> <link target>
cd "$GAME" || exit 1
dirs=
for c in $CONTENT; do [ -d "$c" ] && dirs="$dirs $c"; done
{
	# shellcheck disable=SC2086 # dir names
	[ -z "$dirs" ] || find $dirs \( -type l -printf 'l\t%p\t%l\n' \) -o \( ! -type d -printf 'f\t%p\t\n' \)
	find . -maxdepth 1 \( -type l -printf 'l\t%P\t%l\n' \) -o \( ! -type d -printf 'f\t%P\t\n' \)
} >"$TMP/scan"
: >"$TMP/oldlinks"
[ -f "$LINKS" ] && cat "$LINKS" >"$TMP/oldlinks"

# The plan. Writes links (every link wanted, the new packs_links.txt), ln (<path> <target>,
# links to make or change), rm (links that go), copy (<file> <path>, configs to copy),
# plugins, maps (the cycle), fastdl (<file> <path>) and xhit (-name patterns that hit)
: >"$TMP/links" && : >"$TMP/ln" && : >"$TMP/rm" && : >"$TMP/copy" && : >"$TMP/maps"
awk -F '\t' -v T="$TMP" -v data="$DATA" -v shared="$SHARED" -v amxx_ok="$amxx_ok" \
	-v content=" $CONTENT " -v default="$DEFAULT" '
function say(m) { print "[packs] " m > "/dev/stderr" }
# A shell pattern as a regex, built once
function re(g,    r, i, j, c, n) {
	if (g in RE) return RE[g]
	r = "^"
	n = length(g)
	for (i = 1; i <= n; i++) {
		c = substr(g, i, 1)
		if (c == "*") r = r ".*"
		else if (c == "?") r = r "."
		else if (c == "[" && (j = index(substr(g, i + 1), "]")) > 0) { r = r substr(g, i, j + 1); i += j }
		else if (index(".+^$(){}|\\[]", c)) r = r "\\" c
		else r = r c
	}
	return RE[g] = r "$"
}
function excluded(m,    i) {
	for (i = 1; i <= nx; i++) if (m ~ re(X[i])) { hit[X[i]] = 1; return 1 }
	return 0
}
# An empty filter has every map
function in_filter(m, f,    k, a, i) {
	if (f == "") return 1
	k = split(f, a, " ")
	for (i = 1; i <= k; i++) if (m ~ re(a[i])) return 1
	return 0
}
function base(r) { sub(/.*\//, "", r); return r }
# ../ for each dir in r
function up(r,    n, s) {
	n = gsub(/\//, "/", r)
	s = ""
	while (n-- > 0) s = s "../"
	return s
}
# Something of the server'"'"'s own there: a file, or a link that isn'"'"'t ours
function theirs(r) { return (r in real) || ((r in lt) && !(r in ours)) }

function dopack(i,    k, all, wanted, linked, maps, kept, out, dup, plugins, copied, r, src, top, map, b, plugin, tgt, msg) {
	if (XP[i]) { say(L[i] ": left out"); return }
	# A pack with maps, none of them wanted: none of its files either
	all = wanted = 0
	for (k = 1; k <= npm[i]; k++) {
		all++
		if (!excluded(PM[i, k]) && in_filter(PM[i, k], F[i])) wanted++
	}
	if (all > 0 && wanted == 0) { say(L[i] ": left out, none of its " all " maps are wanted"); return }
	linked = maps = kept = out = dup = plugins = copied = 0
	for (k = 1; k <= nf[i]; k++) {
		r = R[i, k]
		src = S[i, k]
		if (r ~ /^addons\/amxmodx\/scripting\//) continue
		if (r ~ /^addons\/amxmodx\// && !amxx_ok) { amxx_skipped = 1; continue }
		if (index(r, "/")) {
			top = r
			sub(/\/.*/, "", top)
			if (!index(content, " " top " ")) continue
		} else if (r !~ /\.(wad|WAD)$/) continue
		# A map'"'"'s own files go with it
		map = ""
		if (r ~ /^(maps|overviews)\/.*\./) {
			b = base(r)
			sub(/\.[^.]*$/, "", b)
			sub(/_detail$/, "", b)
			if ((i, b) in hasmap) map = b
		}
		if (map != "" && (excluded(map) || !in_filter(map, F[i]))) {
			if (r == "maps/" map ".bsp") out++
			continue
		}
		# Configs are copied, once: each server changes its own, and CVAR_ writes into
		# them, which through a link would change the library'"'"'s
		if (r ~ /^addons\/amxmodx\/configs\// || r ~ /\.(cfg|ini)$/) {
			if (!theirs(r) && !(r in copying)) {
				copying[r] = 1
				print src "\t" r > (T "/copy")
				copied++
			}
			continue
		}
		plugin = r ~ /^addons\/amxmodx\/plugins\/.*\.amxx$/ ? base(r) : ""
		if (r in W) { dup++; continue }
		if (theirs(r)) {
			kept++
			if (plugin != "") print plugin > (T "/plugins")
			continue
		}
		# Relative, so the link works on the host too (./cstrike next to ./data)
		tgt = src
		if (!shared && index(src, data "/") == 1) tgt = up(r) "../data/" substr(src, length(data) + 2)
		W[r] = tgt
		print r > (T "/links")
		# What players may download: not the default pack, they have it, and nothing of
		# the server'"'"'s own (addons, configs)
		if (P[i] != default && r !~ /^addons\//) print src "\t" r > (T "/fastdl")
		linked++
		if (plugin != "") { plugins++; print plugin > (T "/plugins") }
		if (r == "maps/" map ".bsp") { maps++; LM[i, map] = 1 }
	}
	for (k = 1; k <= nc[i]; k++) if ((i, C[i, k]) in LM) print C[i, k] > (T "/maps")
	msg = L[i] ": " maps " maps, " linked " files"
	if (plugins) msg = msg ", " plugins " plugins"
	if (copied) msg = msg ", " copied " configs copied"
	if (out) msg = msg ", " out " maps left out"
	if (dup) msg = msg ", " dup " already from a pack before it"
	if (kept) msg = msg ", " kept " already in cstrike (kept those)"
	say(msg)
}

FILENAME == T "/oldlinks" { ours[$0] = 1; next }
FILENAME == T "/scan" { if ($1 == "l") lt[$2] = $3; else real[$2] = 1; next }
FILENAME == T "/excludes" { if ($0 != "") X[++nx] = $0; next }
FILENAME == T "/packinfo" { np = $1; P[$1] = $2; F[$1] = $3; L[$1] = $4; XP[$1] = $5; next }
FILENAME == T "/cycles" { C[$1, ++nc[$1]] = $2; next }
# allfiles: the first of a path in a pack wins (a compiled plugin over its .amxx)
{
	i = $1
	if ((i, $2) in seen) next
	seen[i, $2] = 1
	R[i, ++nf[i]] = $2
	S[i, nf[i]] = $3
	if ($2 ~ /^maps\/[^\/]*\.bsp$/) {
		m = substr($2, 6, length($2) - 9)
		hasmap[i, m] = 1
		PM[i, ++npm[i]] = m
	}
}
END {
	for (i = 1; i <= np; i++) dopack(i)
	for (r in ours) if ((r in lt) && !(r in W)) { print r > (T "/rm"); gone++ }
	for (r in W) {
		if ((r in lt) && lt[r] == W[r]) same++
		else { print r "\t" W[r] > (T "/ln"); made++ }
	}
	for (g in hit) print g > (T "/xhit")
	if (amxx_skipped) say("warning: cstrike has no AMX Mod X (ENABLE_AMXMODX), the packs'"'"' plugins aren'"'"'t used")
	if (made || gone) say("links: " made + 0 " made, " gone + 0 " taken down, " same + 0 " as they were")
}' "$TMP/oldlinks" "$TMP/scan" "$TMP/excludes" "$TMP/packinfo" "$TMP/cycles" "$TMP/allfiles"

# Only the difference: links that go, configs copied, links made or changed (ln -f swaps a
# link that pointed elsewhere)
tr '\n' '\0' <"$TMP/rm" | xargs -0 -r rm -f --
while IFS="$TAB" read -r src r; do
	case $r in */*) mkdir -p "${r%/*}" ;; esac
	cp "$src" "$r"
done <"$TMP/copy"
link_all "$GAME" "$TMP/ln"
cat "$TMP/links" >"$LINKS"
# -name lines that left nothing out: a typo, most likely
while IFS= read -r g; do
	grep -qxF -e "$g" "$TMP/xhit" && continue
	tags match "$g" | grep -q . && continue
	say "warning: -$g: no pack or map by that name"
done <"$TMP/xnames"

# The packs' plugins in amxmodx's plugins.ini, between the "; packs:" lines, in packlist
# order. Lines there for plugins still listed stay as they are, with what env-config.sh
# did to them (AMXX_PLUGIN_<NAME>). A plugin plugins.ini lists elsewhere stays there
if [ -n "$amxx_ok" ]; then
	awk -v wantfile="$TMP/plugins" '
	function name(l,    t) {
		t = l
		sub(/^[ \t]+/, "", t)
		if (index(t, "; env-original: ") == 1) t = substr(t, 17)
		if (t ~ /^;[^; \t]/) t = substr(t, 2)
		else if (t ~ /^;/) return ""
		sub(/[ \t].*$/, "", t)
		return tolower(t)
	}
	BEGIN {
		B = "; packs: the plugins from data/packlist, rewritten by packs"
		E = "; packs: end"
		while ((getline l < wantfile) > 0)
			if (l != "" && !(tolower(l) in want)) { want[tolower(l)] = 1; order[++n] = l }
	}
	$0 == B { inb = 1; seenb = 1; next }
	$0 == E { inb = 0; next }
	!inb { print; k = name($0); if (k != "") listed[k] = 1; next }
	/^; env-managed: / { pend = pend $0 "\n"; next }
	{ blk[++nb] = pend $0; bk[nb] = name($0); pend = "" }
	END {
		if (n == 0) exit
		print B
		for (i = 1; i <= nb; i++)
			if ((bk[i] in want) && !(bk[i] in listed)) { print blk[i]; kept[bk[i]] = 1 }
		for (k in kept) have[k] = 1
		for (i = 1; i <= n; i++) {
			k = tolower(order[i])
			if (!(k in listed) && !(k in have)) { print order[i]; have[k] = 1 }
		}
		print E
	}' "$PLUGINS_INI" >"$TMP/plugins.ini"
	cmp -s "$TMP/plugins.ini" "$PLUGINS_INI" || cat "$TMP/plugins.ini" >"$PLUGINS_INI"
	n=$(sort -u "$TMP/plugins" | grep -c .) || true
	[ "$n" = 0 ] || say "plugins: $n in addons/amxmodx/configs/plugins.ini"
fi

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
	awk -F '\t' -v lib="$LIB" '{
		r = $2; n = gsub(/\//, "/", r); u = ""
		while (n-- > 0) u = u "../"
		print $2 "\t" u "../../" substr($1, length(lib) + 2)
	}' "$TMP/fastdl" >"$TMP/fastdl.ln"
	link_all "$new" "$TMP/fastdl.ln"
	n=$(find "$new" -type l | wc -l)
	chmod -R a+rX "$new"
	rm -rf "$LIB/fastdl/.old.$SERVER"
	[ -e "$LIB/fastdl/$SERVER" ] && mv "$LIB/fastdl/$SERVER" "$LIB/fastdl/.old.$SERVER"
	mv "$new" "$LIB/fastdl/$SERVER"
	rm -rf "$LIB/fastdl/.old.$SERVER"
	say "fastdl: $n files in ${LIB#/opt/hlds/}/fastdl/$SERVER, at ${FASTDL_URL%/}/"
	[ ${#FASTDL_URL} -le 127 ] || say "warning: FASTDL_URL is over 127 characters, the engine cuts it"
fi
