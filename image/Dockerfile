# Stage 1: CS 1.6 itself, via SteamCMD. Nearly all of the server's size, and it never changes,
# so the runtime stage copies it in a layer of its own that stays cached.
# Base images are pinned by digest, so a rebuild gets the same ones: bump them on purpose
# (podman pull <image>, then podman image inspect <image> --format '{{.Digest}}')
FROM docker.io/cm2network/steamcmd:latest@sha256:45f6515d6c4dcde659c9ad6872bdbeacd1bf5c4e7f241829c4d2f28fb5eda581 AS steam

WORKDIR /opt/hlds

USER root
RUN apt-get update && apt-get install -y wget unzip xz-utils lib32gcc-s1 && rm -rf /var/lib/apt/lists/*
RUN chown -R steam:steam /opt/hlds
USER steam

# Download CS 1.6 via SteamCMD
RUN /home/steam/steamcmd/steamcmd.sh \
    +force_install_dir /opt/hlds \
    +login anonymous \
    +app_set_config 90 mod cstrike \
    # Using pre-aniversary build of HLDS as that's what ReHLDS supports
    +app_update 90 -beta steam_legacy validate \
    +quit

# What a cstrike server doesn't use: Half-Life's campaign maps and soundtrack, the 64-bit
# Steam libraries (HLDS is 32-bit) and SteamCMD's leftovers. In its own step, so the
# download above stays cached
RUN rm -rf valve/maps valve/media linux64 steamapps/downloading steamapps/temp

# HLDS looks for steamclient.so in ~/.steam/sdk32
# The base image only symlinks it to steamcmd/linux32, which won't exist in the runtime stage
# So replace the symlink with a real copy of the file
RUN rm -f /home/steam/.steam/sdk32/steamclient.so && \
    cp /home/steam/steamcmd/linux32/steamclient.so /home/steam/.steam/sdk32/steamclient.so

# Keep the stock game dll, for ENABLE_REGAMEDLL=0.
# If cstrike has no delta.lst the engine falls back to valve's, so keep that one instead
RUN mkdir -p dist/stock && \
    cp cstrike/dlls/cs.so dist/stock/ && \
    { cp cstrike/delta.lst dist/stock/ 2>/dev/null || cp valve/delta.lst dist/stock/; }

# The maps CS ships with, with their descriptions and overviews, as the default pack:
# scripts/packs.sh links them into cstrike unless data/packlist leaves them out. Its
# mapcycle.txt orders them in the map cycle
RUN mkdir -p packs/default/maps packs/default/overviews && \
    cp cstrike/mapcycle.txt packs/default/ && \
    for bsp in cstrike/maps/*.bsp; do \
        m=$(basename "$bsp" .bsp); \
        for f in cstrike/maps/"$m".* cstrike/maps/"$m"_detail.txt cstrike/overviews/"$m".*; do \
            if [ -f "$f" ]; then mv "$f" "packs/default/${f#cstrike/}"; fi; \
        done; \
    done

# Pristine copy of cstrike. ./cstrike is a bind mount, which hides the image's cstrike dir and
# is never filled from the image, so the entrypoint seeds an empty one from here, and
# components.sh restores missing addons and refreshes binaries from it.
# Moved, not copied: the image's own cstrike would only be hidden by the mount anyway
RUN mv cstrike cstrike_defaults && mkdir cstrike


# Stage 2: everything on top of CS (ReHLDS, ReGameDLL, Metamod-r, AMX Mod X, ReAPI, our
# plugins, server.cfg), installed over the CS files as usual. Its last step copies only what
# it changed or added to /out, which the runtime stage lays over the CS files, so changing any
# of this rebuilds only that small layer
FROM steam AS addons

ARG REHLDS_VER=3.15.0.896
ARG REGAMEDLL_VER=5.30.0.814
ARG REAPI_VER=5.29.0.358
ARG METAMOD_VER=1.3.0.149
ARG AMXX_VER=1.10.0-git5474
# sha256 of each download, so a moved or replaced release fails the build. ReHLDS, ReGameDLL
# and ReAPI match the digests GitHub lists for the release; Metamod-r and AMX Mod X publish
# none, so theirs are of the files as downloaded on 2026-11-24
ARG REHLDS_SHA256=997baeb7ef3842dab3e034d82dc651ebfe560c23b158adce660a6b97976b4e2b
ARG REGAMEDLL_SHA256=457f5c96a4d10280fcad47f106cbd5be86363a47df1ccab91c514e9d1bc6fd18
ARG REAPI_SHA256=f33a7435540bea8706db3fa948e51a85b511f5b18c383b97402a204dc5419195
ARG METAMOD_SHA256=ede7f59c4e0220afe8c02aa348a130cce527f87d36ffdb674e37a501ce57be94
ARG AMXX_BASE_SHA256=4b8178c09291e787aea7cd52603f49de197997935613cab5e63f153af33545ca
ARG AMXX_CSTRIKE_SHA256=479f7ef264a0ade6accaedbf6c69980d657a669f5a6c8542990457ab82ab0206

# Everything the steps below create, overwrite or chmod gets a newer change time than this
# (unlike the modification time, unzip, tar and cp -p can't set it back), see the last step
RUN touch /tmp/addons-start

# Download and install ReHLDS
RUN wget https://github.com/rehlds/ReHLDS/releases/download/${REHLDS_VER}/rehlds-bin-${REHLDS_VER}.zip && \
    echo "${REHLDS_SHA256}  rehlds-bin-${REHLDS_VER}.zip" | sha256sum -c - && \
    unzip -q rehlds-bin-${REHLDS_VER}.zip && \
    cp -r bin/linux32/* ./ && \
    rm -rf rehlds-bin-${REHLDS_VER}.zip bin

# Download and install ReGameDLL
RUN wget https://github.com/rehlds/ReGameDLL_CS/releases/download/${REGAMEDLL_VER}/regamedll-bin-${REGAMEDLL_VER}.zip && \
    echo "${REGAMEDLL_SHA256}  regamedll-bin-${REGAMEDLL_VER}.zip" | sha256sum -c - && \
    mkdir -p /tmp/regamedll-bin dist/regamedll && \
    unzip -q regamedll-bin-${REGAMEDLL_VER}.zip -d /tmp/regamedll-bin && \
    cp -r /tmp/regamedll-bin/bin/linux32/cstrike/* cstrike_defaults/ && \
    cp cstrike_defaults/dlls/cs.so cstrike_defaults/delta.lst dist/regamedll/ && \
    rm -rf regamedll-bin-${REGAMEDLL_VER}.zip /tmp/regamedll-bin

# Fix liblist.game crash issue (metamod's gamedll auto-detect expects cs_i386.so)
RUN cd cstrike_defaults/dlls && ln -s cs.so cs_i386.so

# Download and install Metamod-r
RUN wget https://github.com/rehlds/Metamod-r/releases/download/${METAMOD_VER}/metamod-bin-${METAMOD_VER}.zip && \
    echo "${METAMOD_SHA256}  metamod-bin-${METAMOD_VER}.zip" | sha256sum -c - && \
    mkdir -p /tmp/metamod-bin && \
    unzip -q metamod-bin-${METAMOD_VER}.zip -d /tmp/metamod-bin && \
    cp -r /tmp/metamod-bin/addons cstrike_defaults/ && \
    rm -rf metamod-bin-${METAMOD_VER}.zip /tmp/metamod-bin && \
    sed -i 's|gamedll_linux "dlls/cs\.so"|gamedll_linux "addons/metamod/metamod_i386.so"|' cstrike_defaults/liblist.gam

# Download and install AMX Mod X
RUN wget https://www.amxmodx.org/amxxdrop/1.10/amxmodx-${AMXX_VER}-base-linux.tar.gz && \
    wget https://www.amxmodx.org/amxxdrop/1.10/amxmodx-${AMXX_VER}-cstrike-linux.tar.gz && \
    printf '%s  %s\n' "${AMXX_BASE_SHA256}" amxmodx-${AMXX_VER}-base-linux.tar.gz \
        "${AMXX_CSTRIKE_SHA256}" amxmodx-${AMXX_VER}-cstrike-linux.tar.gz | sha256sum -c - && \
    tar -xzf amxmodx-${AMXX_VER}-base-linux.tar.gz -C cstrike_defaults/ && \
    tar -xzf amxmodx-${AMXX_VER}-cstrike-linux.tar.gz -C cstrike_defaults/ && \
    echo 'linux addons/amxmodx/dlls/amxmodx_mm_i386.so' > cstrike_defaults/addons/metamod/plugins.ini && \
    rm amxmodx-*.tar.gz

# Download and install ReAPI
RUN wget https://github.com/rehlds/ReAPI/releases/download/${REAPI_VER}/reapi-bin-${REAPI_VER}.zip && \
    echo "${REAPI_SHA256}  reapi-bin-${REAPI_VER}.zip" | sha256sum -c - && \
    unzip -q reapi-bin-${REAPI_VER}.zip -d cstrike_defaults/ && \
    rm reapi-bin-${REAPI_VER}.zip

# Compile our own plugins (plugins/, git submodules), enabled through env vars
COPY --chown=steam:steam plugins/ /tmp/plugins/
RUN [ -f /tmp/plugins/hltv-tools/hltv_tools.sma ] || { \
        echo "image/plugins/hltv-tools is empty: run git submodule update --init" >&2; exit 1; }
RUN cd cstrike_defaults/addons/amxmodx/scripting && \
    for f in /tmp/plugins/*/*.sma; do \
        ./amxxpc "$f" -o"../plugins/$(basename "$f" .sma).amxx" || exit 1; \
    done

RUN mkdir -p cstrike_defaults/logs cstrike_defaults/demos

# Replace the builtin server config
RUN <<'EOF' cat > cstrike_defaults/server.cfg
// Use this file to configure your DEDICATED server.
// This config file is executed on server start.

// disable autoaim
sv_aim 0

// disable clients' ability to pause the server
pausable 0

// default server name. Change to "Bob's Server", etc.
hostname "Counter-Strike 1.6 Server"

// maximum client movement speed
sv_maxspeed 320

// 20 minute timelimit
mp_timelimit 20

sv_cheats 0

// load ban files
exec listip.cfg
exec banned.cfg

mp_consistency 0
EOF

# What the steps above created, overwrote or chmodded, with its permissions, to /out. At worst
# that takes along an unchanged file, never misses one. A layer can't delete, so removing a CS
# file (compared with the CS stage, bind mounted at /base) fails the build
USER root
RUN --mount=type=bind,from=steam,source=/opt/hlds,target=/base \
    set -e; \
    (cd /base && find . -mindepth 1 | sort) > /tmp/base.lst; \
    (cd /opt/hlds && find . -mindepth 1 | sort) > /tmp/now.lst; \
    comm -23 /tmp/base.lst /tmp/now.lst > /tmp/removed.lst; \
    if [ -s /tmp/removed.lst ]; then echo "add-ons removed CS files:" >&2; head /tmp/removed.lst >&2; exit 1; fi; \
    mkdir /out; cd /opt/hlds; \
    find . -mindepth 1 -cnewer /tmp/addons-start -type d -print0 | (cd /out && xargs -0r mkdir -p); \
    find . -mindepth 1 -cnewer /tmp/addons-start ! -type d -print0 | xargs -0r cp -a --parents -t /out; \
    cd /out; \
    find . -type d -print0 | xargs -0r -I{} chmod --reference=/opt/hlds/{} {}


# Stage 3: goldsrc-demo-tools: repairs demos, tells who joined, writes their voice to a .mka
# (see scripts/hltv.sh and scripts/demos.sh)
FROM docker.io/library/debian:trixie-slim@sha256:ab3b3c8c5159eebfca4376430132d53c4d425f869c765ecbe47177a030da575d AS demo-tools

ARG ZIG_VER=0.17.1
# From ziglang.org/download/index.json
ARG ZIG_SHA256=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
ARG OPUS_VER=1.6.1
ARG OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils gcc make libc6-dev pkgconf && \
    rm -rf /var/lib/apt/lists/*
# libopus from source, linked statically: Debian's older libopus (bookworm's 1.3.1) decodes quiet stretches a little
# differently from the 1.6.1 the tool is tested with, enough to fail its speech timing tests
RUN curl -fsSL -o /tmp/opus.tar.gz https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz && \
    echo "${OPUS_SHA256}  /tmp/opus.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/opus.tar.gz -C /tmp && cd /tmp/opus-${OPUS_VER} && \
    ./configure -q --prefix=/usr/local --disable-shared --disable-doc --disable-extra-programs && \
    make -s -j"$(nproc)" install && \
    cd / && rm -rf /tmp/opus*
RUN curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz && \
    echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - && \
    tar -xJf /tmp/zig.tar.xz -C /opt && rm /tmp/zig.tar.xz && \
    ln -s /opt/zig-x86_64-linux-${ZIG_VER}/zig /usr/local/bin/zig
# tools/goldsrc-demo-tools is a git submodule. The tests check voice placement against the
# reference fixtures, with this libopus
COPY tools/goldsrc-demo-tools/ /src/
RUN [ -f /src/build.zig ] || { \
        echo "image/tools/goldsrc-demo-tools is empty: run git submodule update --init" >&2; exit 1; }
# Zig's cache lives in a build cache mount, kept on the build host between builds and never in
# the image, so a change to the tool only recompiles what changed. The tests still run every time
RUN --mount=type=cache,target=/zig-cache \
    export ZIG_GLOBAL_CACHE_DIR=/zig-cache/global ZIG_LOCAL_CACHE_DIR=/zig-cache/local && \
    cd /src && zig build test && zig build -Doptimize=ReleaseSafe --prefix /out && \
    /out/bin/goldsrc-demo-tools voice testdata/one-player.dem --dump > /dev/null


# Stage 4: minimal runtime
FROM docker.io/library/debian:trixie-slim@sha256:ab3b3c8c5159eebfca4376430132d53c4d425f869c765ecbe47177a030da575d AS runtime

# curl, jq and bsdtar (libarchive-tools: zip, rar, 7z) download packs, zip and unzip read and
# write the URL in a zip's comment, see scripts/packs.sh
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends libc6:i386 libstdc++6:i386 lib32gcc-s1 ca-certificates \
        curl jq libarchive-tools zip unzip && \
    rm -rf /var/lib/apt/lists/*

# Runs as root inside the container. Under rootless podman that is the host user, so files
# in ./cstrike stay owned by you and editable without `podman unshare`, with no keep-id
# (keep-id makes podman copy and chown the whole image on every new image)
WORKDIR /opt/hlds
COPY --from=steam --chown=0:0 /opt/hlds /opt/hlds
# HLDS looks for steamclient.so in ~/.steam/sdk32
COPY --from=steam --chown=0:0 /home/steam/.steam /root/.steam
# The add-ons over the CS files, in a small layer of their own
COPY --from=addons --chown=0:0 /out/ /opt/hlds/
COPY --from=demo-tools /out/bin/goldsrc-demo-tools /usr/local/bin/

EXPOSE 27015/udp 27015/tcp
ENTRYPOINT ["/opt/hlds/entrypoint.sh"]
# Only what has to be on the command line (no +ip: the server binds its own address, and
# pasta forwards every host address to it). The rest are cvars (CVAR_*, server.cfg, which the
# server runs on its own at startup). The entrypoint sets +maxplayers and +map from
# MAXPLAYERS and MAP
CMD ["./hlds_run", "-game", "cstrike", "+map", "de_dust2"]

# `podman exec <container> cs <command>`: reload, tags, save, console (see scripts/cs.sh).
RUN ln -s /opt/hlds/cs.sh /usr/local/bin/cs

# Our scripts last, so editing them only rebuilds this small layer.
# ENABLE_* picks the components, data/packlist the maps, CVAR_*, AMXX_* and METAMOD_* edit the configs, HLTV_* configure HLTV.
# All applied on every start
COPY --chmod=755 scripts/ /opt/hlds/
