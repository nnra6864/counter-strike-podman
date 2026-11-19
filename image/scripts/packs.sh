#!/bin/sh
# Packs: maps, AMX Mod X plugins, and anything else laid out like cstrike (models, sounds,
# sprites, wads), each in its own dir or archive, linked into cstrike. Run by the entrypoint
# on every start, and by hand after editing the list, while the server runs (new maps and
# plugins work from the next map change):
#
#   podman exec <container> cs reload
#   podman exec <container> cs save <download> [dir]      keep a download in packs/
#   podman exec <container> cs tags                       every tag and what has it
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
#   -cs_*          leave these maps out, whichever pack has them
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
# cstrike/packs_links.txt, and taken down the next time before the new ones go up.

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

mkdir -p "$DATA" "$PACKS" "$DOWNLOADS" "$CACHE"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# One run at a time per library: several servers, or a start and `cs reload` at once
if command -v flock >/dev/null; then
	exec 9>"$LIB/.lock"
	flock -w 1800 9 || say "warning: another run holds $LIB/.lock, going ahead anyway"
fi
rm -rf "$DOWNLOADS"/.tmp.* "$CACHE"/.tmp.*

if [ ! -f "$LIST" ]; then
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
	#   -cs_*          leave these maps out
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
	*://gamebanana.com/* | *://www.gamebanana.com/*) gamebanana "$url" || return 1 ;;
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
	[ -n "$dl_md5" ] && printf 'md5 %s\n' "$dl_md5" >>"$tmp/pack/.source"
	# The file as it came, untouched, for packs save
	mkdir "$tmp/pack/.original" && mv "$tmp/download" "$tmp/pack/.original/$(printf %s "$file" | tr '/' _)"
	rm -rf "${DOWNLOADS:?}/$name"
	mv "$tmp/pack" "$DOWNLOADS/$name"
	rm -rf "$tmp"
	say "$url: installed as downloads/$name ($(find "$DOWNLOADS/$name/maps" -name '*.bsp' 2>/dev/null | wc -l) maps)"
	echo "$name"
}

# packs save <download> [dir] -----------------------------------------------------------
# Copies a download into packs/ (packs/maps or packs/plugins by what's in it, unless a dir
# is given) as a zip with its URL in the comment, so it stays once the packlist names it
# there instead of by URL. A zip as it came; a .rar or .7z as a zip of the same files.
# The download itself isn't changed: GameBanana's checksum is of it as it came

if [ "${1:-}" = save ]; then
	name=${2:-}
	d=$DOWNLOADS/$name
	case $name in '' | */* | .*) d= ;; esac
	if [ -z "$d" ] || [ ! -f "$d/.source" ]; then
		say "usage: packs save <download> [dir in packs/]. Downloads: $(ls "$DOWNLOADS" | tr '\n' ' ')"
		exit 1
	fi
	url=$(head -n 1 "$d/.source")
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
	trap 'rm -rf "$TMP" "$tmp"' EXIT
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
		say "packs/$rel is already there"
		exit 1
	fi
	if [ -n "$(unzip -qz "$tmp" 2>/dev/null)" ]; then
		say "it has a comment already, left as it is: $(unzip -qz "$tmp" | head -n 1)"
	else
		printf '%s\n' "$url" | zip -zq "$tmp"
	fi
	chmod a+r "$tmp"
	mv "$tmp" "$dest"
	say "saved packs/$rel ($url)"
	say "in data/packlist, replace $url with $name"
	exit 0
fi

# The list ------------------------------------------------------------------------------

# entries: <pack dir> <tab> <maps filter, empty = all>. keep: downloads this server uses
: >"$TMP/entries" && : >"$TMP/excludes" && : >"$TMP/xpacks" && : >"$TMP/keep" && : >"$TMP/fastdl" && : >"$TMP/plugins"
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
		mkdir -p "${l%/*}"
		{
			printf '%s\n' "$stamp"
			LC_ALL=C.UTF-8 bsdtar -tf "$1" 2>/dev/null | sed -n 's|.*/||; s|\.[bB][sS][pP]$||p' | sort -u
		} >"$l"
	fi
	tail -n +2 "$l"
}

INDEX=$TMP/index
index() {
	[ -f "$INDEX" ] || index_walk "$PACKS" >"$INDEX"
}

TAGS=$LIB/tags
if [ ! -f "$TAGS" ]; then
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

# packs tags: every tag and what has it
if [ "${1:-}" = tags ]; then
	tags check
	tags list
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
	-*) printf '%s\n' "${t#-}" >>"$TMP/excludes" ;;
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

# Take down the last run's links
if [ -f "$LINKS" ]; then
	while IFS= read -r r; do
		[ -L "$GAME/$r" ] && rm -f "$GAME/$r"
	done <"$LINKS"
fi
: >"$TMP/links" && : >"$TMP/maps"

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

# Is map $1 in filter $2: patterns, any of them. An empty filter has every map
in_filter() {
	[ -n "$2" ] || return 0
	set -f
	for _p in $2; do
		# shellcheck disable=SC2254 # a pattern
		case $1 in $_p) set +f && return 0 ;; esac
	done
	set +f
	return 1
}

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

# Where a link at cstrike/$1 points, for file $2
link_target() {
	case $2 in
	"$DATA"/*)
		# Relative, so the link works on the host too (./cstrike next to ./data)
		[ -z "$SHARED" ] && printf '%s../data/%s' "$(up "$1")" "${2#"$DATA"/}" && return 0
		;;
	esac
	printf '%s' "$2"
}

# AMX Mod X files only go in when cstrike has it: the entrypoint installs it whole into a
# volume without an addons/amxmodx, which a link there would stop
amxx_ok=
[ -f "$PLUGINS_INI" ] && amxx_ok=1
amxx_skipped=

while IFS="$(printf '\t')" read -r pack filter; do
	case $pack in
	"$DEFAULT") label=default ;;
	"$CACHE"/packs/*) label=packs/${pack#"$CACHE"/packs/} ;;
	*) label=${pack#"$LIB"/} ;;
	esac
	[ -f "$pack/.source" ] && label="$label ($(head -n 1 "$pack/.source"))"
	linked=0 maps=0 kept=0 out=0 dup=0 plugins=0 copied=0
	if grep -qxF -e "$pack" "$TMP/xpacks"; then
		say "$label: left out"
		continue
	fi
	cd "$pack" || continue
	# A pack with maps, none of them wanted: none of its files either
	all=0 wanted=0
	for b in maps/*.bsp; do
		[ -f "$b" ] || continue
		b=${b##*/}
		b=${b%.bsp}
		all=$((all + 1))
		if ! excluded "$b" && in_filter "$b" "$filter"; then wanted=$((wanted + 1)); fi
	done
	if [ $all -gt 0 ] && [ $wanted = 0 ]; then
		say "$label: left out, none of its $all maps are wanted"
		continue
	fi
	# <path in cstrike> <tab> <file>. Plugins compiled from source first: they win over a
	# .amxx the pack has
	{
		for f in addons/amxmodx/scripting/*.sma; do
			[ -f "$f" ] && [ -n "$amxx_ok" ] || continue
			n=${f##*/}
			n=${n%.*}
			inc=
			[ -d addons/amxmodx/scripting/include ] && inc=$pack/addons/amxmodx/scripting/include
			if a=$(compile "$pack/$f" "$inc"); then
				printf 'addons/amxmodx/plugins/%s.amxx\t%s\n' "$n" "$a"
			fi
		done
		find . -type f ! -path '*/.*' | sed 's|^\./||' | sort | awk -v p="$pack" '{ print $0 "\t" p "/" $0 }'
	} | awk -F '\t' '!seen[$1]++' >"$TMP/files"
	: >"$TMP/packmaps"
	while IFS="$(printf '\t')" read -r r src; do
		case $r in
		addons/amxmodx/scripting/*) continue ;;
		addons/amxmodx/*)
			if [ -z "$amxx_ok" ]; then
				amxx_skipped=1
				continue
			fi
			;;
		esac
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
			if excluded "$map" || ! in_filter "$map" "$filter"; then
				[ "$r" = "maps/$map.bsp" ] && out=$((out + 1))
				continue
			fi
		fi
		dest=$GAME/$r
		# Configs are copied, once: each server changes its own, and CVAR_ writes into
		# them, which through a link would change the library's
		case $r in
		addons/amxmodx/configs/* | *.cfg | *.ini)
			if [ ! -e "$dest" ] && [ ! -L "$dest" ] && mkdir -p "${dest%/*}" && cp "$src" "$dest"; then
				copied=$((copied + 1))
			fi
			continue
			;;
		esac
		plugin=
		case $r in addons/amxmodx/plugins/*.amxx) plugin=${r##*/} ;; esac
		if [ -L "$dest" ]; then
			dup=$((dup + 1))
			continue
		elif [ -e "$dest" ]; then
			kept=$((kept + 1))
			[ -n "$plugin" ] && printf '%s\n' "$plugin" >>"$TMP/plugins"
			continue
		fi
		if ! mkdir -p "${dest%/*}" || ! ln -s "$(link_target "$r" "$src")" "$dest"; then continue; fi
		printf '%s\n' "$r" >>"$TMP/links"
		# What players may download: not the default pack, they have it, and nothing of
		# the server's own (addons, configs)
		case $pack:$r in
		"$DEFAULT":* | *:addons/*) ;;
		*) printf '%s\t%s\n' "$src" "$r" >>"$TMP/fastdl" ;;
		esac
		linked=$((linked + 1))
		if [ -n "$plugin" ]; then
			plugins=$((plugins + 1))
			printf '%s\n' "$plugin" >>"$TMP/plugins"
		fi
		if [ "$r" = "maps/$map.bsp" ]; then
			maps=$((maps + 1))
			printf '%s\n' "$map" >>"$TMP/packmaps"
		fi
	done <"$TMP/files"
	cycle_order "$pack" | grep -xF -f "$TMP/packmaps" >>"$TMP/maps"
	msg="$label: $maps maps, $linked files"
	[ $plugins = 0 ] || msg="$msg, $plugins plugins"
	[ $copied = 0 ] || msg="$msg, $copied configs copied"
	[ $out = 0 ] || msg="$msg, $out maps left out"
	[ $dup = 0 ] || msg="$msg, $dup already from a pack before it"
	[ $kept = 0 ] || msg="$msg, $kept already in cstrike (kept those)"
	say "$msg"
done <"$TMP/entries"

cat "$TMP/links" >"$LINKS"
[ -z "$amxx_skipped" ] || say "warning: cstrike has no AMX Mod X (ENABLE_AMXMODX), the packs' plugins aren't used"

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
	n=0
	while IFS="$(printf '\t')" read -r src r; do
		case $r in */*) mkdir -p "$new/${r%/*}" ;; esac
		ln -s "$(up "$r")../../${src#"$LIB"/}" "$new/$r" && n=$((n + 1))
	done <"$TMP/fastdl"
	chmod -R a+rX "$new"
	rm -rf "$LIB/fastdl/.old.$SERVER"
	[ -e "$LIB/fastdl/$SERVER" ] && mv "$LIB/fastdl/$SERVER" "$LIB/fastdl/.old.$SERVER"
	mv "$new" "$LIB/fastdl/$SERVER"
	rm -rf "$LIB/fastdl/.old.$SERVER"
	say "fastdl: $n files in ${LIB#/opt/hlds/}/fastdl/$SERVER, at ${FASTDL_URL%/}/"
	[ ${#FASTDL_URL} -le 127 ] || say "warning: FASTDL_URL is over 127 characters, the engine cuts it"
fi
