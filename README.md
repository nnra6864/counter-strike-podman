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

Everything is automated, simply run:

```sh
podman compose build
```

This might take a few minutes depending on your disk and network speeds.

## Running

Configure `compose.yaml` and run:

```sh
podman compose up -d
```

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
| `ENABLE_HLTV_VOICE` | `ENABLE_HLTV` | lets HLTV hear every player, so demos have voice. Needs ReGameDLL and AMX Mod X |

Set them all to `0` for a plain ReHLDS server.
The binaries (game dll, metamod, AMXX dlls and modules) are refreshed from the image on every start, so rebuilding the image upgrades them. Configs and plugins in `cstrike` are never overwritten.

### Replays

With `ENABLE_HLTV: "1"`, an HLTV proxy runs next to the server and records every map to `cstrike/demos/hltv-<date>-<map>.dem`.
Watch one by copying it to your game's `cstrike` dir and running `viewdemo hltv-....dem` in the console.

HLTV takes a player slot, so raise `+maxplayers` by one.
It doesn't accept spectators by default (`HLTV_MAXCLIENTS: "0"`): with voice on, it hears both teams.

| Variable | Default | |
|---|---|---|
| `HLTV_RECORD` | `demos/hltv` | demo name, relative to `cstrike`. Empty = don't record |
| `HLTV_SERVER` | `127.0.0.1:27015` | server to connect to |
| `HLTV_PORT` | `27020` | HLTV's own port. Not published, add it to `ports` for live spectators |
| `HLTV_<CMD>` | | any HLTV command, run as `+<cmd> value`: `HLTV_DELAY`, `HLTV_MAXCLIENTS`, `HLTV_NAME`, `HLTV_HOSTNAME`, ... |

`sv_password` is passed to HLTV automatically. To send it a command at runtime:

```sh
podman exec counter-strike sh -c 'echo status > /tmp/hltv.in'
```

Its output is in the container logs, prefixed with `[hltv]`.

#### Voice tracks

`tools/demo-voice` turns a demo's voice chat into one `.mka` with a track per player (work in progress: decoding isn't done yet):

```sh
cargo build --release --manifest-path tools/demo-voice/Cargo.toml
tools/demo-voice/target/release/demo-voice cstrike/demos/hltv-....dem --order team   # T first, then CT
tools/demo-voice/target/release/demo-voice cstrike/demos/hltv-....dem --dump         # who spoke, raw packets
```

`--order join` (default) sorts by when players joined, `--order team` by the team they started on.
`--tracks team` or `--tracks mix` merges players into one track per team, or a single track.

### Environment variables

Settings can also be set with environment variables in `compose.yaml`.
They are applied to the files in `cstrike` on **every** start, so a fork or branch can carry its own settings without touching the volume.

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
Environment changes need the container recreated (`podman compose up -d`), since `podman restart` keeps the old environment.
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
