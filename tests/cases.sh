#!/bin/sh
# The test cases, run in a throwaway container by tests/run.sh: cases.sh [case...]
# Each case starts from an empty cstrike/ and library, builds its own tiny packs, runs a
# script and checks what it wrote.
set -u

H=/opt/hlds G=$H/cstrike D=$H/data FX=/tmp/fx T=/tmp/t
cp -r /src/. $H/ && chmod 755 $H/*.sh
mkdir -p $FX $T

failed=0 cases=0 bad=
fail() {
	echo "    FAIL: $*"
	bad=1
}
# Checks
has() { grep -qxF -e "$2" "$1" 2>/dev/null || fail "${1#"$H"/} has no line: $2"; }
hasnt() { ! grep -qxF -e "$2" "$1" 2>/dev/null || fail "${1#"$H"/} has the line: $2"; }
link() { [ -L "$G/$1" ] || fail "cstrike/$1 isn't a link"; }
nolink() { [ ! -e "$G/$1" ] && [ ! -L "$G/$1" ] || fail "cstrike/$1 is there"; }
file() { [ -f "$G/$1" ] && [ ! -L "$G/$1" ] || fail "cstrike/$1 isn't a plain file"; }
logs() { grep -qF -e "$1" $T/log || fail "no \"$1\" in the output"; }
nologs() { ! grep -qF -e "$1" $T/log || fail "\"$1\" in the output"; }
points() { case $(readlink "$G/$1") in *"$2"*) ;; *) fail "cstrike/$1 points to $(readlink "$G/$1"), not $2" ;; esac; }
# The packs' plugins in plugins.ini
block() { sed -n '/^; packs: the plugins/,/^; packs: end/p' $G/addons/amxmodx/configs/plugins.ini >$T/block; }

# Setup
fresh() {
	rm -rf $G $D $H/library $FX
	mkdir -p $G/addons/amxmodx/configs $D/packs $FX
	cp $H/cstrike_defaults/addons/amxmodx/configs/plugins.ini $G/addons/amxmodx/configs/
}
packlist() { printf '%s\n' "$@" >$D/packlist; }
tagsfile() { printf '%s\n' "$@" >$D/tags; }
packs() { PACKS_VERBOSE=1 $H/packs.sh "$@" >$T/out 2>$T/log; }
# A map: a BSP version 30 header and some bytes
bsp() {
	mkdir -p "${1%/*}"
	printf '\036\000\000\000%s' "$1" >"$1"
}
sma() {
	mkdir -p "${1%/*}"
	printf '#include <amxmodx>\npublic plugin_init() { register_plugin("%s", "1", "t"); }\n' "${1##*/}" >"$1"
}
# zip <archive> <dir>: the dir's contents
zipdir() { (cd "$2" && zip -qr "$1" .); }

# Cases ---------------------------------------------------------------------------------

case_maps() {
	fresh
	bsp $FX/a/maps/de_a.bsp && echo t >$FX/a/maps/de_a.txt
	mkdir -p $D/packs/maps && zipdir $D/packs/maps/de_a.zip $FX/a
	bsp $D/packs/maps/aim_c.bsp
	# A zip in a zip, its map loose
	bsp $FX/inner/fy_b.bsp && mkdir -p $FX/b && zipdir $FX/b/inner.zip $FX/inner && zipdir $D/packs/maps/nest.zip $FX/b
	bsp $FX/z/maps/cs_z.bsp && (cd $FX/z && bsdtar --format 7zip -cf $D/packs/maps/cs_z.7z maps)
	packlist default '*'
	packs || fail "packs.sh failed"
	link maps/de_a.bsp && link maps/de_a.txt && link maps/aim_c.bsp && link maps/fy_b.bsp && link maps/cs_z.bsp
	link maps/de_dust2.bsp
	has $G/packs_mapcycle.txt de_a && has $G/packs_mapcycle.txt fy_b && has $G/packs_mapcycle.txt de_dust2
	has $G/packs_links.txt maps/de_a.bsp
	$H/packs.sh 2>$T/log
	logs "[packs] 5 packs: 29 maps" && nologs "default: 25 maps"
}

case_plugins() {
	fresh
	# An AlliedModders layout
	sma $FX/p/foo/scripting/foo.sma && mkdir -p $FX/p/foo/configs $FX/p/foo/data/lang
	echo 'foo_x 1' >$FX/p/foo/configs/foo.cfg && echo '[en]' >$FX/p/foo/data/lang/foo.txt
	mkdir -p $D/packs/plugins && zipdir $D/packs/plugins/foo.zip $FX/p
	printf 'public plugin_init( {\n' >$D/packs/plugins/broken.sma
	packlist default '*'
	packs || fail "packs.sh failed"
	block
	has $T/block foo.amxx && hasnt $T/block broken.amxx
	link addons/amxmodx/plugins/foo.amxx && link addons/amxmodx/data/lang/foo.txt
	file addons/amxmodx/configs/foo.cfg
	logs "broken.sma doesn't compile"
	packs || fail "packs.sh failed"
	logs "broken.sma still doesn't compile (unchanged"
}

case_exclude_name() {
	fresh
	mkdir -p $D/packs/plugins && sma $D/packs/plugins/foo.sma && sma $D/packs/plugins/bar.sma
	bsp $D/packs/maps/de_a.bsp
	packlist default '*' -foo -de_dust2 -nosuch
	packs || fail "packs.sh failed"
	block
	hasnt $T/block foo.amxx && has $T/block bar.amxx
	nolink maps/de_dust2.bsp && link maps/de_a.bsp
	logs "-nosuch: no pack or map by that name"
	nologs "-foo: no pack" && nologs "-de_dust2: no pack"
}

case_packlist() {
	fresh
	mkdir -p $D/packs/maps
	bsp $D/packs/maps/fy_b.bsp && bsp $D/packs/maps/de_a.bsp && bsp $D/packs/maps/aim_c.bsp
	bsp $D/packs/mix/maps/de_x.bsp && bsp $D/packs/mix/maps/cs_y.bsp
	tagsfile '[tag.snow] fy_b de_a' '[tag.arena]' 'fy_*' 'aim_*' '[map.de_a] xmas'
	packlist '@snow+arena'
	packs || fail "packs.sh failed"
	link maps/fy_b.bsp && nolink maps/de_a.bsp && nolink maps/aim_c.bsp
	packlist '@snow' '-@xmas'
	packs || fail "packs.sh failed"
	link maps/fy_b.bsp && nolink maps/de_a.bsp
	packlist 'mix/de_*' aim_c
	packs || fail "packs.sh failed"
	link maps/de_x.bsp && nolink maps/cs_y.bsp && link maps/aim_c.bsp && nolink maps/fy_b.bsp
	packlist '@nosuch'
	packs
	logs "no tag nosuch"
	# Picked by name and by two tags: one pack
	tagsfile '[tag.snow] fy_b' '[tag.xmas] fy_b'
	packlist fy_b @snow @xmas
	packs || fail "packs.sh failed"
	[ "$(grep -c 'fy_b' $T/log)" = 1 ] || fail "fy_b counted more than once"
	logs "1 packs: 1 maps"
}

case_first_wins() {
	fresh
	for p in p1 p2; do
		bsp $D/packs/$p/maps/shared.bsp && mkdir -p $D/packs/$p/models && echo $p >$D/packs/$p/models/m.mdl
	done
	packlist p2 p1
	packs || fail "packs.sh failed"
	points maps/shared.bsp packs/p2/ && points models/m.mdl packs/p2/
	# A file that's in cstrike already is kept
	packlist p1
	echo mine >$G/models/m.mdl.new && rm $G/models/m.mdl && mv $G/models/m.mdl.new $G/models/m.mdl
	packs || fail "packs.sh failed"
	file models/m.mdl && points maps/shared.bsp packs/p1/
}

case_packlist_env() {
	fresh
	mkdir -p $D/packs/plugins && sma $D/packs/plugins/foo.sma
	bsp $D/packs/maps/de_a.bsp && bsp $D/packs/maps/de_b.bsp
	packlist default
	PACKLIST='de_a  # a comment
plugins/foo' packs || fail "packs.sh failed"
	link maps/de_a.bsp && nolink maps/de_b.bsp && nolink maps/de_dust2.bsp
	logs "PACKLIST is set: data/packlist isn't used"
	$H/cs.sh maps >$T/log 2>&1
	logs "  de_a" && logs "  foo.amxx"
}

case_url() {
	fresh
	bsp $FX/u/maps/de_url.bsp && zipdir $FX/de_url.zip $FX/u
	packlist default file://$FX/de_url.zip
	packs || fail "packs.sh failed"
	link maps/de_url.bsp
	[ -f $D/downloads/de_url/.source ] || fail "no downloads/de_url"
	# Not listed any more: gone
	packlist default
	packs || fail "packs.sh failed"
	nolink maps/de_url.bsp
	[ ! -e $D/downloads/de_url ] || fail "downloads/de_url is still there"
}

case_reload_unchanged() {
	fresh
	bsp $D/packs/maps/de_a.bsp && mkdir -p $D/packs/m/sound/x && echo s >$D/packs/m/sound/x/s.wav
	packlist default '*'
	packs || fail "packs.sh failed"
	find $G -type l -printf '%P %l %i\n' | sort >$T/before
	packs || fail "packs.sh failed"
	find $G -type l -printf '%P %l %i\n' | sort >$T/after
	cmp -s $T/before $T/after || fail "a reload that changed nothing changed links: $(diff $T/before $T/after | head -n 4)"
	# Taken out of the packlist: its links go, the rest stay
	packlist default
	packs || fail "packs.sh failed"
	nolink maps/de_a.bsp && nolink sound/x/s.wav && link maps/de_dust2.bsp
}

case_fastdl_shared() {
	fresh
	L=$H/library
	mkdir -p $L/packs/maps && bsp $L/packs/maps/de_a.bsp && mkdir -p $L/packs/s/sound/x && echo s >$L/packs/s/sound/x/s.wav
	packlist default '*'
	FASTDL_URL=http://host/srv/ packs || fail "packs.sh failed"
	link maps/de_a.bsp && link sound/x/s.wav
	[ -e $L/fastdl/srv/maps/de_a.bsp ] && [ -e $L/fastdl/srv/sound/x/s.wav ] || fail "fastdl links missing or broken"
	[ ! -e $L/fastdl/srv/maps/de_dust2.bsp ] || fail "the default pack is in fastdl"
	[ -f $L/servers/srv ] || fail "no servers/srv"
	logs "fastdl: 2 files"
}

case_big_pack() {
	fresh
	mkdir -p $D/packs/big/sound/a $D/packs/big/sound/b
	i=0
	while [ $i -lt 1000 ]; do
		echo $i >$D/packs/big/sound/a/$i.wav && echo $i >$D/packs/big/sound/b/$i.wav
		i=$((i + 1))
	done
	packlist big
	s=$(date +%s%N) && packs && e=$(date +%s%N) || fail "packs.sh failed"
	echo "    first run: $(((e - s) / 1000000)) ms"
	s=$(date +%s%N) && packs && e=$(date +%s%N)
	echo "    reload: $(((e - s) / 1000000)) ms"
	[ "$(find $G/sound -type l | wc -l)" = 2000 ] || fail "not 2000 links"
	logs "big: 0 maps, 2000 files"
}

case_readonly() {
	fresh
	rm -rf $D
	packs tags && fail "packs.sh tags worked without a library"
	[ ! -e $D ] || fail "packs.sh tags made data/"
	fresh
	bsp $D/packs/de_a.bsp
	packs tags || fail "packs.sh tags failed"
	[ ! -e $D/tags ] && [ ! -e $D/packlist ] || fail "packs.sh tags wrote files"
}

case_index() {
	fresh
	mkdir -p $D/packs/maps $D/packs/old
	# Maps in a zip in a zip are indexed without unpacking
	bsp $FX/inner/fy_b.bsp && mkdir -p $FX/b && zipdir $FX/b/inner.zip $FX/inner && zipdir $D/packs/maps/nest.zip $FX/b
	bsp $D/packs/old/maps/de_o.bsp && echo x >$D/packs/old/notes.txt
	echo '[tag.x] fy_b' >$D/packs/tags
	echo https://example.com >$D/packs/maps/nest.url
	tagsfile '[tag.snow] fy_b' 'de_o [tag.xmas] fy_b'
	packs tags || fail "packs.sh tags failed"
	logs "[tag.xmas]: a header has to start its line"
	grep -q '^  fy_b (maps/nest)' $T/out || fail "fy_b in nest.zip not found: $(cat $T/out)"
	logs "packs/tags: not a pack"
	nologs "notes.txt" && nologs "nest.url"
}

case_save_tag_remove() {
	fresh
	bsp $FX/s/maps/de_s.bsp && zipdir $FX/de_s.zip $FX/s
	packs save file://$FX/de_s.zip || fail "packs.sh save failed"
	[ "$(cat $T/out)" = "$(printf 'de_s\tmaps/de_s.zip')" ] || fail "save printed: $(cat $T/out)"
	[ "$(unzip -qz $D/packs/maps/de_s.zip)" = file://$FX/de_s.zip ] || fail "no URL in the zip's comment"
	[ ! -e $D/downloads/de_s ] || fail "the download made for saving is still there"
	packs save file://$FX/de_s.zip && logs "already saved"
	tagsfile '[tag.snow]' 'aim_x'
	packs tag de_s snow xmas || fail "packs.sh tag failed"
	has $D/tags de_s && has $D/tags '[tag.xmas]'
	packs remove de_s || fail "packs.sh remove failed"
	[ ! -e $D/packs/maps/de_s.zip ] || fail "packs/maps/de_s.zip is still there"
	hasnt $D/tags de_s && has $D/tags aim_x
}

case_env_config() {
	rm -rf $G && cp -a $H/cstrike_defaults $G
	# Every file as it is, give or take a newline at the end (which a file env-config.sh
	# appended to keeps)
	sums() { (cd $G && find . -type f | sort | while IFS= read -r f; do printf '%s %s\n' "$(sed '$a\' "$f" | md5sum)" "$f"; done); }
	sums >$T/before
	CVAR_HOSTNAME='test server' CVAR_NEW_CVAR=5 AMXX_PLUGIN_ADMIN=0 $H/env-config.sh 2>$T/log || fail "env-config.sh failed"
	grep -q '^hostname "test server"' $G/server.cfg || fail "hostname not set in server.cfg"
	grep -q '^;admin.amxx' $G/addons/amxmodx/configs/plugins.ini || fail "admin.amxx not turned off"
	$H/env-config.sh 2>$T/log || fail "env-config.sh failed"
	sums >$T/after
	cmp -s $T/before $T/after || fail "not the same files after the variables went: $(diff $T/before $T/after | head -n 4)"
}

# cs reload applies the environment like a start does, without undoing what the
# entrypoint derived (the map cycle, the download URL, metamod's amxmodx line)
case_reload_env() {
	fresh
	rm -rf $G && cp -a $H/cstrike_defaults $G
	mkdir -p $D/packs/plugins && sma $D/packs/plugins/foo.sma
	packlist default
	set -- ENABLE_HLTV=1 FASTDL_URL=http://host/srv/ AMXX_PLUGIN_FOO=0 CVAR_HOSTNAME=x
	# What the entrypoint does before starting the server
	env "$@" sh -c '. /opt/hlds/components.sh && /opt/hlds/packs.sh && . /opt/hlds/settings.sh && /opt/hlds/env-config.sh' >$T/log 2>&1 ||
		fail "the start failed"
	grep -q '^mapcyclefile "packs_mapcycle.txt"' $G/server.cfg $G/game.cfg $G/addons/amxmodx/configs/amxx.cfg ||
		fail "no mapcyclefile"
	cp -a $G $T/started
	# The packlist gets plugin foo, which AMXX_PLUGIN_FOO turns off
	packlist default '*'
	env "$@" $H/cs.sh reload >$T/log 2>&1 || fail "cs reload failed"
	grep -q '^;foo.amxx' $G/addons/amxmodx/configs/plugins.ini || fail "foo.amxx not turned off by AMXX_PLUGIN_FOO=0"
	packlist default
	env "$@" $H/cs.sh reload >$T/log 2>&1 || fail "cs reload failed"
	diff -r --no-dereference $T/started $G >$T/diff || fail "not as it was after the start: $(head -n 5 $T/diff)"
	rm -rf $T/started
}

case_demos() {
	rm -rf $G && mkdir -p $G/demos && cd $H || return
	# A finished demo has its directory offset (at 540) set, an unfinished one 0
	demo() { head -c 540 /dev/zero >"$1" && printf "$2" >>"$1" && head -c 100 /dev/zero >>"$1"; }
	demo $G/demos/hltv-1-de_a.dem '\001\000\000\000'
	demo $G/demos/hltv-2-de_b.dem '\000\000\000\000'
	echo hltv-0-gone.dem >$G/hltv_demos_done.txt
	DELETE_EMPTY_DEMOS=0 ENABLE_VOICE_MKA=0 DEMOS_POLL=1 timeout 3 $H/demos.sh cstrike/demos hltv >$T/log 2>&1
	has $G/hltv_demos_done.txt hltv-1-de_a.dem && hasnt $G/hltv_demos_done.txt hltv-2-de_b.dem
	hasnt $G/hltv_demos_done.txt hltv-0-gone.dem
}

# ---------------------------------------------------------------------------------------

all=$(sed -n 's/^case_\([a-z_]*\)() {$/\1/p' "$0")
# shellcheck disable=SC2048,SC2086 # case names
for c in ${*:-$all}; do
	cases=$((cases + 1)) bad=
	echo "$c"
	"case_$c"
	if [ -n "$bad" ]; then
		failed=$((failed + 1))
		sed 's/^/    | /' $T/log | tail -n 15
	fi
done
echo "$((cases - failed))/$cases passed"
[ $failed = 0 ]
