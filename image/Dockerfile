# Stage 1: fetch everything via SteamCMD
FROM docker.io/cm2network/steamcmd:latest AS fetch

ARG REHLDS_VER=3.15.0.896
ARG REGAMEDLL_VER=5.30.0.814
ARG REAPI_VER=5.29.0.358
ARG METAMOD_VER=1.3.0.149
ARG AMXX_VER=1.10.0-git5474

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

# HLDS looks for steamclient.so in ~/.steam/sdk32
# The base image only symlinks it to steamcmd/linux32, which won't exist in the runtime stage
# So replace the symlink with a real copy of the file
RUN rm -f /home/steam/.steam/sdk32/steamclient.so && \
    cp /home/steam/steamcmd/linux32/steamclient.so /home/steam/.steam/sdk32/steamclient.so

# Download and install ReHLDS
RUN wget https://github.com/rehlds/ReHLDS/releases/download/${REHLDS_VER}/rehlds-bin-${REHLDS_VER}.zip && \
    unzip -q rehlds-bin-${REHLDS_VER}.zip && \
    cp -r bin/linux32/* ./ && \
    rm -rf rehlds-bin-${REHLDS_VER}.zip bin

# Keep the stock game dll, for ENABLE_REGAMEDLL=0.
# If cstrike has no delta.lst the engine falls back to valve's, so keep that one instead
RUN mkdir -p dist/stock dist/regamedll && \
    cp cstrike/dlls/cs.so dist/stock/ && \
    { cp cstrike/delta.lst dist/stock/ 2>/dev/null || cp valve/delta.lst dist/stock/; }

# Download and install ReGameDLL
RUN wget https://github.com/rehlds/ReGameDLL_CS/releases/download/${REGAMEDLL_VER}/regamedll-bin-${REGAMEDLL_VER}.zip && \
    mkdir -p /tmp/regamedll-bin && \
    unzip -q regamedll-bin-${REGAMEDLL_VER}.zip -d /tmp/regamedll-bin && \
    cp -r /tmp/regamedll-bin/bin/linux32/cstrike/* cstrike/ && \
    cp cstrike/dlls/cs.so cstrike/delta.lst dist/regamedll/ && \
    rm -rf regamedll-bin-${REGAMEDLL_VER}.zip /tmp/regamedll-bin

# Fix liblist.game crash issue (metamod's gamedll auto-detect expects cs_i386.so)
RUN cd cstrike/dlls && ln -s cs.so cs_i386.so

# Download and install Metamod-r
RUN wget https://github.com/rehlds/Metamod-r/releases/download/${METAMOD_VER}/metamod-bin-${METAMOD_VER}.zip && \
    mkdir -p /tmp/metamod-bin && \
    unzip -q metamod-bin-${METAMOD_VER}.zip -d /tmp/metamod-bin && \
    cp -r /tmp/metamod-bin/addons cstrike/ && \
    rm -rf metamod-bin-${METAMOD_VER}.zip /tmp/metamod-bin && \
    sed -i 's|gamedll_linux "dlls/cs\.so"|gamedll_linux "addons/metamod/metamod_i386.so"|' cstrike/liblist.gam

# Download and install AMX Mod X
RUN wget https://www.amxmodx.org/amxxdrop/1.10/amxmodx-${AMXX_VER}-base-linux.tar.gz && \
    wget https://www.amxmodx.org/amxxdrop/1.10/amxmodx-${AMXX_VER}-cstrike-linux.tar.gz && \
    tar -xzf amxmodx-${AMXX_VER}-base-linux.tar.gz -C cstrike/ && \
    tar -xzf amxmodx-${AMXX_VER}-cstrike-linux.tar.gz -C cstrike/ && \
    echo 'linux addons/amxmodx/dlls/amxmodx_mm_i386.so' > cstrike/addons/metamod/plugins.ini && \
    rm amxmodx-*.tar.gz

# Download and install ReAPI
RUN wget https://github.com/rehlds/ReAPI/releases/download/${REAPI_VER}/reapi-bin-${REAPI_VER}.zip && \
    unzip -q reapi-bin-${REAPI_VER}.zip -d cstrike/ && \
    rm reapi-bin-${REAPI_VER}.zip

# Compile our own plugins (plugins/, git submodules), enabled through env vars
COPY --chown=steam:steam plugins/ /tmp/plugins/
RUN [ -f /tmp/plugins/hltv-tools/hltv_tools.sma ] || { \
        echo "image/plugins/hltv-tools is empty: run git submodule update --init" >&2; exit 1; }
RUN cd cstrike/addons/amxmodx/scripting && \
    for f in /tmp/plugins/*/*.sma; do \
        ./amxxpc "$f" -o"../plugins/$(basename "$f" .sma).amxx" || exit 1; \
    done

RUN mkdir -p cstrike/logs cstrike/demos

# Replace the builtin server config
RUN <<'EOF' cat > cstrike/server.cfg
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


# Stage 2: goldsrc-demo-tools: repairs demos, tells who joined, writes their voice to a .mka
# (see scripts/hltv.sh and scripts/demos.sh)
FROM debian:bookworm-slim AS demo-tools

ARG ZIG_VER=0.17.1
ARG OPUS_VER=1.6.1
ARG OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils gcc make libc6-dev pkgconf && \
    rm -rf /var/lib/apt/lists/*
# libopus from source, linked statically: bookworm's 1.3.1 decodes quiet stretches a little
# differently from the 1.6.1 the tool is tested with, enough to fail its speech timing tests
RUN curl -fsSL -o /tmp/opus.tar.gz https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz && \
    echo "${OPUS_SHA256}  /tmp/opus.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/opus.tar.gz -C /tmp && cd /tmp/opus-${OPUS_VER} && \
    ./configure -q --prefix=/usr/local --disable-shared --disable-doc --disable-extra-programs && \
    make -s -j"$(nproc)" install && \
    cd / && rm -rf /tmp/opus*
RUN curl -fsSL https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz | tar -xJ -C /opt && \
    ln -s /opt/zig-x86_64-linux-${ZIG_VER}/zig /usr/local/bin/zig
# tools/goldsrc-demo-tools is a git submodule. The tests check voice placement against the
# reference fixtures, with this libopus
COPY tools/goldsrc-demo-tools/ /src/
RUN [ -f /src/build.zig ] || { \
        echo "image/tools/goldsrc-demo-tools is empty: run git submodule update --init" >&2; exit 1; }
RUN cd /src && zig build test && zig build -Doptimize=ReleaseSafe --prefix /out && \
    /out/bin/goldsrc-demo-tools voice testdata/one-player.dem --dump > /dev/null


# Stage 3: minimal runtime
FROM debian:bookworm-slim AS runtime

# curl, jq and bsdtar (libarchive-tools: zip, rar, 7z) download packs, zip and unzip read and
# write the URL in a zip's comment, see scripts/packs.sh
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends libc6:i386 libstdc++6:i386 lib32gcc-s1 ca-certificates \
        curl jq libarchive-tools zip unzip && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Runs as root inside the container. Under rootless podman that is the host user, so files
# in ./cstrike stay owned by you and editable without `podman unshare`, with no keep-id
# (keep-id makes podman copy and chown the whole image on every new image)
WORKDIR /opt/hlds
COPY --from=fetch --chown=0:0 /opt/hlds /opt/hlds
# HLDS looks for steamclient.so in ~/.steam/sdk32
COPY --from=fetch --chown=0:0 /home/steam/.steam /root/.steam
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
