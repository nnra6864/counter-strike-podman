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
| `image/` | what the image is built from; nothing in it needs editing to run a server |
| `image/Dockerfile` | builds the image: ReHLDS, ReGameDLL, Metamod-R, AMX Mod X, ReAPI, the plugins, goldsrc-demo-tools |
| `image/scripts/` | run inside the container on every start: `entrypoint.sh` runs `components.sh` (which components load), `packs.sh` (links the packs in, maps and plugins, see [Packs](#packs)); `cs.sh` is the `cs` command, see [Commands](#commands), `env-config.sh` (applies the environment variables to the configs), and `hltv.sh` (HLTV, recording while players are on; it starts `demos.sh`, which repairs, deletes or writes a `.mka` for each finished demo) |
| `image/plugins/` | our AMX Mod X plugins, compiled into the image: [hltv-tools](https://github.com/nnra6864/hltv-tools) (a git submodule) |
| `image/tools/` | [goldsrc-demo-tools](https://github.com/nnra6864/goldsrc-demo-tools) (a git submodule), built into the image |
| `cstrike/` | the server's files and configs, created on first start, gitignored |
| `data/` | ours, gitignored: the packlist, packs, downloads, FastDL, see [Packs](#packs) |

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

### Packs

Maps, AMX Mod X plugins, models, sounds and sprites come in packs: anything laid out like `cstrike` (`maps/de_x.bsp`, `gfx/env/`, `sound/`, `x.wad`, `addons/amxmodx/`), linked into `cstrike`.
They live in `data/`, next to `cstrike/`: `data/` is what you put together, `cstrike/` is the game's.

```
data/
  packlist           which packs this server uses
  packs/             yours: put whatever you like in it, in any dirs
  tags               which packs and maps have which tags, see Tags below
  downloads/<name>/  from URLs in the packlist, deleted once no packlist has them
  fastdl/<server>/   what players download, see FastDL below
  .cache/            archives from packs/ unpacked, plugins compiled
```

A pack in `packs/` is a dir laid out like `cstrike`, or a file as you downloaded it: a `.zip`, `.rar` or `.7z` (whatever its layout), a `.bsp`, a plugin's `.sma` or `.amxx`.
Archives are unpacked into `.cache/` when used, and again when they change; the file itself is never touched.
Dirs that aren't packs just group them, for keeping things in order; to pick packs by what they are, use [tags](#tags). `packs/` can look like this:

```
packs/
  maps/
    fy_snow.zip
    de_dust2_xmas_2.zip
  plugins/
    knife_round.zip
    hello.sma
  mypack/            a pack dir: maps/, sound/, ...
```

`default` is the maps CS ships with, kept in the image.

`data/packlist` lists the packs in order, one per line, `#` for comments; the first pack wins a file two packs both have.
The first start writes one with `default` and `*`.

| In the packlist | |
|---|---|
| `default` | the maps CS ships with |
| `fy_snow` | a pack or a map by name, wherever it is in `packs/`: `fy_snow.zip`, or the pack with `fy_snow.bsp` in it (only that map from it). Patterns work: `aim_*` |
| `@snow` | everything with this tag, see [Tags](#tags) |
| `@snow+competitive` | everything with both tags |
| `-@xmas` | leave out everything with this tag, from whichever pack |
| `mypack` | `packs/mypack`: a dir, or `mypack.zip` (`.rar`, `.7z`, `.bsp`, `.sma`, `.amxx`) |
| `maps/fy_snow` | `packs/maps/fy_snow.zip` |
| `maps` | every pack in `packs/maps` |
| `maps/de_*` | the packs in it with these names |
| `mypack/de_*` | only these maps from a pack (and its other files) |
| `*` | every pack in `packs/`, plugins too |
| `-cs_*` | leave these maps out, from whichever pack |
| `https://gamebanana.com/mods/83651` | a GameBanana page: its newest file, checked against GameBanana's checksum. A `gamebanana.com/dl/<id>` link picks a file |
| `https://.../maps.zip` | any direct link to a `.zip`, `.rar`, `.7z`, `.bsp`, `.sma` or `.amxx` |
| `name=https://...` | the same, into `downloads/name` |

```
default
-cs_*
-as_*
@snow
-@xmas
knife_round
https://gamebanana.com/mods/83651
aim=https://example.com/aim_maps.zip
```

Packs and maps left out (`-cs_*`, `-@xmas`) are left out wherever the packlist names them, before or after. A pack none of whose maps are wanted is left out whole, with its models and sounds.

After editing it, while the server runs:

```sh
podman exec counter-strike cs reload         # from the next map change
podman exec counter-strike cs reload --now   # restarts the current map for it
```

New maps can be changed to right away; new plugins load with the next map, which `--now` starts (players reconnect). The container also does this on every start.
Each URL is downloaded once, and laid out like `cstrike` whatever the archive looks like (loose `.bsp`s go in `maps/`, skies in `gfx/env/`, `.sma`s in `addons/amxmodx/scripting/`). Its source is in `downloads/<name>/.source`, and the file as it came in `downloads/<name>/.original/`. A download with one map is named after the map (the name `changelevel` and the tags file use), one with one plugin after the plugin, anything else after the GameBanana page's title (or the file's name); `name=URL` names it yourself.

The map cycle is every map from the packs, in packlist order (`cstrike/packs_mapcycle.txt`); within a pack, its `mapcycle.txt` first (`default` has the stock one), then the rest by name. `MAPCYCLE: "0"` keeps `mapcycle.txt`.
If `MAP` is one the packs left out, the server starts on the first map in the cycle.

The links are listed in `cstrike/packs_links.txt` and taken down each time before the new ones go up. Files already in `cstrike` (not links) are never replaced, so maps put straight into `cstrike/maps` still work.
Volumes from before packs have the stock maps as files in `cstrike/maps`: the first start removes the ones that are the same as the image's, and links them back from `default`.

#### Tags

A map can be snow, xmas and competitive all at once, which no dir layout can say. The `tags` file next to `packs/` (in the library, shared by the servers that use it) says which packs and maps have which tags, under headers, from either side:

```ini
[tag.snow]
fy_snow
de_dust2_xmas

[tag.xmas] de_dust2_xmas

[map.fy_snow] winter arena

[tag.arena] aim_* awp_*

[plugin.knife_round] competitive

[tag.competitive]
@competitive_maps
knife_round
```

- `[tag.X]` lists what has tag X. `[map.X]` lists the tags X has; `[plugin.X]` and `[pack.X]` are the same, for reading.
- The names go on the header's line or below it, as many per line as you like, up to the next header. `#` for comments.
- The same header can come more than once, and they add up.
- A name is a pack (its file or dir name, wherever it is in `packs/`), a map in one, or a pack's path (`maps/fy_snow`). Patterns work.
- `@tag` in a tag is everything with that other tag.

In the packlist, `@snow` is everything tagged snow, `@snow+competitive` everything with both, `-@xmas` leaves them out. Tags name what's in `packs/`; for a download, `cs save` it first.
The first start writes a `tags` file with only comments. To see every tag and what has it, and warnings for names that match nothing:

```sh
podman exec counter-strike cs tags
```

#### Plugins

A pack's AMX Mod X plugins go in with it:

- Its `addons/amxmodx/scripting/*.sma` are compiled with the image's `amxxpc` (and its `scripting/include/`), once for the same source. A plugin that doesn't compile is left out, with the errors in the log. A compiled `.amxx` in the pack is used as it is, unless there's source for it.
- They're added to `addons/amxmodx/configs/plugins.ini` between `; packs:` lines, in packlist order, and taken out when the packlist drops them. A plugin `plugins.ini` already lists elsewhere stays where it is.
- `AMXX_PLUGIN_<NAME>: "0"` still turns one off (or `debug`, see [Environment variables](#environment-variables)).
- Configs (anything in `addons/amxmodx/configs/`, any `.cfg` or `.ini`) are copied, not linked, and only when `cstrike` doesn't have them yet: each server keeps its own, and `CVAR_` settings never write into the library.
- Plugins need AMX Mod X (`ENABLE_AMXMODX`); without it they're left out.

Archives from AlliedModders are put into shape like maps: `addons/amxmodx/...`, an `amxmodx/` dir, `scripting/` and `plugins/` dirs (with `configs/` and `data/lang/` next to them), or loose `.sma`, `.inc` and `.amxx` files.

#### Where a pack came from

A URL in a zip's comment (`zip -z`) is where it came from; for other files, a `.url` file next to them with the URL in it (`fy_snow.url` for `fy_snow.rar`). `cs reload` shows it in the log:

```
[packs] packs/maps/fy_snow.zip (https://gamebanana.com/mods/86704): 1 maps, 9 files
```

To download a map or plugin into `packs/` with its URL:

```sh
podman exec counter-strike cs save https://gamebanana.com/mods/84229        # into packs/maps/ (or packs/plugins/)
podman exec counter-strike cs save https://gamebanana.com/mods/84229 winter # into packs/winter/
```

```
[packs] downloading https://gamebanana.com/mods/84229
[packs] downloaded it (1 maps)
[packs] de_inferno_snow: cstrike_inferno.rar is a rar: saving its files as a zip
[packs] saved https://gamebanana.com/mods/84229
[packs]   as packs/maps/de_inferno_snow.zip, with the URL in the zip's comment
[packs]   use it by name in a packlist or the tags file: de_inferno_snow
```

It checks the file against GameBanana's checksum, puts it in `packs/` as a zip and the URL in its comment. A URL that's in `packs/` already is said so and left alone.
A URL a packlist has downloaded already isn't downloaded again: `cs save` saves that download (by URL or by its name; `cs save` alone lists them), and then the URL in the packlist can be replaced with the name. The download goes on the next `cs reload`.
A `.rar` or `.7z` becomes a zip of the same files (only a zip can hold the URL), a lone `.bsp`, `.sma` or `.amxx` a zip with it where the game looks for it. Downloads from before `.original/` was kept are saved as a zip of what was unpacked.
The download itself is never changed. A zip's comment is outside the files in it, so the maps in it are the same bytes, but the zip's own checksum isn't GameBanana's any more.

#### Saving with tags and a reload

`-t` adds the pack to tags in the tags file, and `-r` runs `cs reload` after, so a map the packlist picks (by name, a pattern or a tag) can be played straight away:

```sh
podman exec counter-strike cs save -r -t snow,xmas https://gamebanana.com/mods/84229
```

```
[packs] tagged de_inferno_snow: snow
[packs] tagged de_inferno_snow: xmas
...
[cs] de_inferno_snow works now: cs console changelevel de_inferno_snow
```

Without `-t`, `podman exec -it` shows a picker with every tag in the tags file: up and down (or ctrl-k and ctrl-j) to move, space or tab to pick, type into the slot at the bottom for new tags (spaces or commas between), enter when done, esc for none. Without a terminal it says it didn't tag; `-t ''` is no tags, quietly.
The name goes under `[tag.x]` on a line of its own, where it sorts among the names there (or on the header's line, if that's where they are). A new tag gets a `[tag.x]` before the first tag that sorts after it. A pack that's saved already is tagged all the same, so `cs save -t` works for tagging it later too.
If nothing from the pack ends up in use after `-r`, it says so: the packlist doesn't pick it, or its URL is still there instead of its name.

#### Removing a pack

```sh
podman exec -it counter-strike cs remove de_dust2_winter16
```

```
[packs] packs/maps/de_dust2_winter16.zip (https://gamebanana.com/mods/85466)
[packs]   and from the tags file:
[packs]     [tag.competitive] de_dust2_winter16
[packs]     [tag.snow] de_dust2_winter16
[cs] remove it? [y/N]
```

It takes a pack's name, its path in `packs/` (`maps/fy_snow`) or the name of a map in it, and deletes the pack (and its `.url` file) and every mention of it in the tags file: its name and its maps' names under `[tag.x]`, and their `[map.x]` sections. Patterns (`de_*`), `@tags` and the `[tag.x]` headers stay. It says when `data/packlist` names it. Without a terminal it removes nothing unless given `-y`. Servers keep the map until their next `cs reload`; `-r` reloads this one. A removed pack can be had back from a ZFS snapshot of the library.

#### Sharing packs between servers

Mount one dir on `/opt/hlds/library` in each server's `compose.override.yaml`, and it holds `packs/`, `downloads/`, `fastdl/` and `.cache/` for all of them instead of `data/` (the packlist stays in each server's `data/`):

```yml
services:
  counter-strike:
    volumes:
      - /tank/services/counter-strike:/opt/hlds/library:z
    environment:
      FASTDL_URL: "http://fastdl.example.com/NnCompetitive/"
```

Every file is there once: a pack only one server lists is that server's, one several list is shared, and a URL two servers list is downloaded once.
Each server keeps the downloads it uses in `servers/<name>` there (`<name>` from `FASTDL_URL`, or `SERVER_NAME`), and a download is deleted once no server lists it. Without a name, nothing is deleted.
Retiring a server: delete its `servers/<name>` and `fastdl/<name>`.

#### FastDL

Players download the maps they don't have from the game server, which is slow for big maps.
With `FASTDL_URL`, they get them over HTTP instead (`sv_downloadurl`): `fastdl/<name>/` is written next to the packs, laid out like `cstrike`, with links to exactly the files this server uses (not `default`, players have those; never `addons/` or configs).
The links are relative, so a web server can serve the dir from wherever the library is on the host:

```nginx
server {
    listen 80;
    server_name fastdl.example.com;
    root /tank/services/counter-strike/fastdl;
    autoindex off;
}
```

Use plain `http://` for `FASTDL_URL`, with no redirect to HTTPS on that host: the game client doesn't download over HTTPS (with an `https://` URL it falls back to the slow in-game download). It also remembers a server's download URL until the game is restarted, so after changing it, test with a fresh game.
To check FastDL from a player's machine, use `curl -I http://.../maps/<map>.bsp`, not a browser: browsers try HTTPS first and get some other site on that host.
Players on the server's own network may not reach it through its public address (routers often don't loop that back): resolve the FastDL name to the server's local address there, or the client quietly falls back to the slow download.
The web server has to be able to read the files, which `cs reload` makes world-readable. `FASTDL_URL` can be 127 characters at most.

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

This uses [goldsrc-demo-tools](https://github.com/nnra6864/goldsrc-demo-tools) (`image/tools/`), built into the image.

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

To send a single command without attaching, use `cs console` (below); its output is in `podman logs counter-strike`.

## Commands

`cs` runs in the container, for what you'd otherwise restart it for:

```sh
podman exec counter-strike cs <command>
```

| Command | |
|---|---|
| `reload` | link the packs again after editing `data/packlist` or the tags file: maps, plugins, FastDL, the map cycle. New plugins load with the next map, see [Packs](#packs) |
| `reload --now` | the same, then restart the current map so they load now (players reconnect) |
| `tags` | every tag and what has it, and names in the tags file that match nothing, see [Tags](#tags) |
| `save [-r] [-t tags] <URL> [dir]` | download a map or plugin into `packs/`, as a zip with its URL, see [Where a pack came from](#where-a-pack-came-from). `save` alone lists the packlists' downloads, which can be saved by name. `-t snow,xmas` tags it (with `podman exec -it`, a picker instead), `-r` reloads after, see [Saving with tags](#saving-with-tags-and-a-reload) |
| `remove [-r] [-y] <pack or map>` | delete a pack from `packs/` and take it out of the tags file, after asking, see [Removing a pack](#removing-a-pack) |
| `console <command>` | send a command to the server's console, like `cs console changelevel de_dust2`; the output is in the container's logs |
| `help` | this list |

Settings from environment variables still need the container recreated (`podman compose up -d`).

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
