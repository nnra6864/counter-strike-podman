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

# Compile our own plugins (see plugins/), enabled through env vars
COPY --chown=steam:steam plugins/ /tmp/plugins/
RUN cd cstrike/addons/amxmodx/scripting && \
    for f in /tmp/plugins/*.sma; do \
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

# Clone cstrike for preserving default values
RUN cp -a cstrike cstrike_defaults


# Stage 2: minimal runtime
FROM debian:bookworm-slim AS runtime

ARG UID=1000
ARG GID=1000

RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends libc6:i386 libstdc++6:i386 lib32gcc-s1 ca-certificates && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -g ${GID} steam && useradd -m -u ${UID} -g ${GID} -s /bin/sh steam

WORKDIR /opt/hlds
COPY --from=fetch --chown=${UID}:${GID} /opt/hlds /opt/hlds
COPY --from=fetch --chown=${UID}:${GID} /home/steam/.steam /home/steam/.steam
# ENABLE_* picks the components, CVAR_*, AMXX_* and METAMOD_* edit the configs, HLTV_* configure HLTV.
# All applied on every start
COPY --chmod=755 components.sh env-config.sh env-config.awk hltv.sh /opt/hlds/

RUN <<'EOF' cat > /opt/hlds/entrypoint.sh && chmod +x /opt/hlds/entrypoint.sh && chown steam:steam /opt/hlds/entrypoint.sh
#!/bin/sh
set -e

if [ -z "$(ls -A /opt/hlds/cstrike 2>/dev/null)" ]; then
  echo "Initializing cstrike directory"
  cp -a /opt/hlds/cstrike_defaults/. /opt/hlds/cstrike/
fi

# Sourced: it sets defaults for env-config.sh
. /opt/hlds/components.sh

/opt/hlds/env-config.sh || echo "[env] failed to apply env vars, starting with configs as they are"

case $(printf %s "$ENABLE_HLTV" | tr '[:upper:]' '[:lower:]') in
  1|on|true|yes|enable|enabled) /opt/hlds/hltv.sh & ;;
esac

exec "$@"
EOF

USER steam
ENTRYPOINT ["/opt/hlds/entrypoint.sh"]

EXPOSE 27015/udp 27015/tcp

CMD ["./hlds_run", "-game", "cstrike", "+ip", "0.0.0.0", "+map", "de_dust2", "+maxplayers", "32", "+sv_lan", "0"]
