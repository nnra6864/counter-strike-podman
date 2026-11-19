This is a podman container made for cs 1.6 servers using:

1. [pasta](https://passt.top/passt/about/)
2. [ReHLDS](https://rehlds.dev/)
3. [ReGameDLL](https://rehlds.dev/docs/regamedll-cs/)
4. [Metamod-R](https://github.com/rehlds/Metamod-R)
5. [AMX Mod X](https://www.amxmodx.org/)
6. [ReAPI](https://github.com/rehlds/reapi)

# Usage

## Dependencies

Arch
```sh
sudo pacman -S podman passt
```

## Building

Clone with the submodules (the plugin and the demo tools are their own repos), then build:

```sh
git clone --recurse-submodules https://github.com/nnra6864/counter-strike-podman
cd counter-strike-podman
podman compose build
```

The submodules come from wherever you cloned this repo: GitHub here, or a mirror with the same repo names next to it.
Cloned without them, run `git submodule update --init` first; the build says so if they're missing.

This might take a few minutes depending on your disk and network speeds.

## Running

```sh
podman compose up -d
```

Settings for your server go in a `compose.override.yaml` next to `compose.yaml`, rather than in `compose.yaml` itself.
podman-compose merges it on top automatically, and it's gitignored, so `git pull` never conflicts with your settings:

```yml
services:
  counter-strike:
    container_name: my-server
    environment:
      CVAR_HOSTNAME: "My Server"
```

`MAXPLAYERS` (32) and `MAP` (the starting map, `de_dust2`) set the player slots and the map the server starts on.

Settings are layered, each on top of the one before:

1. `presets/defaults.env`: what every server gets (loaded by `compose.yaml`)
2. any presets your `compose.override.yaml` lists under `env_file:`
3. your `compose.override.yaml`'s `environment:`

Keep one `environment:` and one `volumes:` per file: a second one silently replaces the first.

### Competitive

`presets/competitive.env` sets up 5v5: competitive rules, 10 players plus HLTV, every map recorded with voice and a `.mka` with tracks T first, then CT.
Use it from your `compose.override.yaml`, and put anything of your own on top:

```yml
services:
  counter-strike:
    container_name: counter-strike-competitive
    env_file:
      - presets/competitive.env
    environment:
      CVAR_HOSTNAME: "My Competitive"
      CVAR_RCON_PASSWORD: "change me"
```

The preset itself stays in the repo, so `git pull` brings its updates.

### Updating

```sh
git pull
git submodule update --init
podman compose build
podman compose up -d --force-recreate
```

`git pull` alone doesn't update the submodules (`git config submodule.recurse true` makes it).

`--force-recreate` because podman-compose doesn't notice a new image or a changed env file on its own, and would keep the old container.

### More than one server

Clone the repo once per server, each with its own `compose.override.yaml` (at least a different `container_name`).
Each clone keeps its own `cstrike` dir.
They all use port 27015 unless you change `ports` in `compose.yaml`, so only one runs at a time by default.

### Files

| | |
|---|---|
| `compose.yaml` | the container: ports, volumes, restart policy |
| `compose.override.yaml` | yours, gitignored: what this server changes |
| `presets/` | settings as env files: `defaults.env` for every server, `competitive.env` on top for 5v5 |
| `Dockerfile` | builds the image: ReHLDS, ReGameDLL, Metamod-R, AMX Mod X, ReAPI, the plugins, goldsrc-demo-tools |
| `scripts/` | run inside the container on every start: `entrypoint.sh` runs `components.sh` (which components load), `env-config.sh` (applies the environment variables to the configs), and `hltv.sh` (HLTV, recording while players are on; it starts `demos.sh`, which repairs, deletes or writes a `.mka` for each finished demo) |
| `plugins/` | our AMX Mod X plugins, compiled into the image: [hltv-tools](https://github.com/nnra6864/hltv-tools) (a git submodule) |
| `tools/` | [goldsrc-demo-tools](https://github.com/nnra6864/goldsrc-demo-tools) (a git submodule), built into the image |
| `cstrike/` | the server's files and configs, created on first start, gitignored |

## Configuring

While some configuration is available in `compose.yaml`, most config files and directories are found in the `cstrike` dir.
To locate it, look at your `compose.yml`.
By default, it should be in the same directory as the compose file:

```yml
volumes:
    - ./cstrike:/opt/hlds/cstrike:U,Z
```

### Components

Everything ships in the image, and `ENABLE_*` decides what the server loads:

| Variable | Default | |
|---|---|---|
| `ENABLE_REGAMEDLL` | `1` | ReGameDLL, or the stock game dll |
| `ENABLE_METAMOD` | `1` | Metamod-R |
| `ENABLE_AMXMODX` | `1` | AMX Mod X + ReAPI, needs metamod |
| `ENABLE_HLTV` | `0` | HLTV proxy for recording demos, see [Replays](#replays) |
| `ENABLE_HLTV_VOICE` | `ENABLE_HLTV` | lets HLTV hear every player, so demos have voice (the `hltv_tools` plugin). Needs ReGameDLL and AMX Mod X |

Set them all to `0` for a plain ReHLDS server.
The binaries (game dll, metamod, AMXX dlls and modules) are refreshed from the image on every start, so rebuilding the image upgrades them. Configs and plugins in `cstrike` are never overwritten.

### Replays

With `ENABLE_HLTV: "1"`, an HLTV proxy runs next to the server and records to `cstrike/demos/hltv-<date>-<map>.dem`, a file per map, while someone is on: recording starts when a player connects and stops once nobody has been on for `RECORD_IDLE_STOP` seconds.
Watch one by copying it to your game's `cstrike` dir and running `viewdemo hltv-....dem` in the console.

HLTV takes a player slot, so raise `MAXPLAYERS` by one.
It doesn't accept spectators by default (`HLTV_MAXCLIENTS: "0"`): with voice on, it hears both teams.

| Variable | Default | |
|---|---|---|
| `HLTV_RECORD` | `demos/hltv` | demo name, relative to `cstrike`. Empty = don't record |
| `RECORD_IDLE_STOP` | `120` | seconds with nobody on before recording stops. `0` = record all the time. Needs AMX Mod X (the `hltv_tools` plugin counts the players); without it HLTV records all the time |
| `HLTV_SERVER` | `127.0.0.1:27015` | server to connect to |
| `HLTV_PORT` | `27020` | HLTV's own port. Not published, add it to `ports` for live spectators |
| `HLTV_<CMD>` | | any HLTV command, run as `+<cmd> value`: `HLTV_DELAY`, `HLTV_MAXCLIENTS`, `HLTV_NAME`, `HLTV_HOSTNAME`, ... |

`sv_password` is passed to HLTV automatically. To send it a command at runtime:

```sh
podman exec counter-strike sh -c 'echo status > /tmp/hltv.in'
```

Its output is in the container logs, prefixed with `[hltv]`.

To keep demos somewhere else (a bigger disk, for example), mount over `cstrike/demos` in your `compose.override.yaml`:

```yml
services:
  counter-strike:
    volumes:
      - /path/to/replays:/opt/hlds/cstrike/demos
```

#### Finished demos

Every finished demo is handled once, in the background:

- **Repaired** if it was never finished (server crash, HLTV killed), so the game can still play it. On `podman stop`, HLTV finishes its demo first, so that's only needed after a crash.
- **Deleted** if nobody joined (`DELETE_EMPTY_DEMOS`). HLTV and bots don't count; anyone who connected does.
- Otherwise it gets a **`.mka`** next to it, with the voice chat as one Opus track per player, in sync with the demo from the start. Demos with no voice get no `.mka`.

This uses [goldsrc-demo-tools](https://github.com/nnra6864/goldsrc-demo-tools) (`tools/`), built into the image.

| Variable | Default | |
|---|---|---|
| `DELETE_EMPTY_DEMOS` | `1` | delete demos nobody joined |
| `ENABLE_VOICE_MKA` | `ENABLE_HLTV` | a `.mka` per finished demo |
| `VOICE_MKA_ARGS` | | options: `--order team` (tracks T first, then CT; good for competitive), `--tracks team` or `--tracks mix` (a track per team, or one), `--lenient` (write even if parts of the demo couldn't be read) |

The log lines are prefixed with `[demos]`. Handled demos are listed in `cstrike/hltv_demos_done.txt`, so each is handled once. On its first start, a server handles every demo in its demo dir that isn't listed there yet.
To run the tool by hand, on any demo:

```sh
podman exec counter-strike goldsrc-demo-tools voice cstrike/demos/hltv-....dem --order team
podman exec counter-strike goldsrc-demo-tools info cstrike/demos/hltv-....dem    # who joined
podman exec counter-strike goldsrc-demo-tools repair cstrike/demos/hltv-....dem  # finish a cut-off demo
```

### Environment variables

Settings can also be set with environment variables, in `compose.override.yaml` or a preset (see [Running](#running)).
They are applied to the files in `cstrike` on **every** start, so a server's settings live in its override file, not only in its volume.

| Variable | Edits | Value |
|---|---|---|
| `CVAR_<NAME>` | every server `.cfg` that sets that cvar (`server.cfg`, `game.cfg`, `amxx.cfg`, plugin cfgs, ...) | the value; quoted for you unless it already contains `"`. Several lines (YAML `\|`) repeat the cvar, e.g. for `amx_imessage` |
| `AMXX_PLUGIN_<NAME>` | `addons/amxmodx/configs/plugins.ini` | `0`/`1`, or flags such as `debug` |
| `AMXX_MODULE_<NAME>` | `addons/amxmodx/configs/modules.ini` | `0`/`1` |
| `AMXX_CORE_<KEY>` | `addons/amxmodx/configs/core.ini` | the value |
| `METAMOD_PLUGIN_<NAME>` | `addons/metamod/plugins.ini` | `0`/`1`, or a path to add a new plugin |
| `METAMOD_CFG_<KEY>` | `addons/metamod/config.ini` | the value |

Names are case-insensitive and nothing is hardcoded: whatever is in the files gets picked up, including cvars and plugins you add later.
A cvar that isn't in any file is appended to `amxx.cfg`, which runs after `server.cfg`.

```yml
environment:
  CVAR_HOSTNAME: "My Server"
  CVAR_MP_BUYTIME: "0.5"
  AMXX_PLUGIN_SCROLLMSG: "0"
  AMXX_PLUGIN_IMESSAGE: "0"
```

To see everything that can be set this way, along with the current values:

```sh
podman exec counter-strike /opt/hlds/env-config.sh --list
```

Replaced lines are kept as `env-original:` comments, and every line written from the environment has an `env-managed:` comment above it.
Removing a variable restores the original line on the next start.
Environment changes need the container recreated (`podman compose up -d`, or with `--force-recreate` when only an env file changed), since `podman restart` keeps the old environment.
Don't hand-edit the `env-managed` lines, they are rewritten on every start.

> [!NOTE]
> AMXX plugins that create their own config (`addons/amxmodx/configs/plugins/*.cfg`) only write it on their first run, so a `CVAR_` for such a plugin takes full effect from the second start.

## Stopping

```sh
podman compose down
```

## Console

You can easily access the server console by running:
```sh
podman attach counter-strike
```

> [!NOTE]
> Replace `counter-strike` with your container name.

> [!NOTE]
> To detach from the console without killing the server, press `CTRL + P` followed by `CTRL + Q`.

# ☦

```
   Ὤ
 Ὁ   Ν
Ι̅Ϲ̅ │ Χ̅Ϲ̅
───┼───
ΝΙ │ ΚΑ
   ☦
```

Εἰς δόξαν τοῦ Θεοῦ<br>
*To the glory of God*

Τῇ Ὑπεραγίᾳ Θεοτόκῳ δόξα<br>
*Glory to the Most Holy Theotokos*

Δόξα τῷ Θεῷ πάντων ἕνεκεν<br>
*Glory to God for all things*

ΑΜΗΝ

☦
