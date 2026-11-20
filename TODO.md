# TODO

## 1. Optional components (env toggles)

Everything stays in the image. `ENABLE_*` picks what the server actually loads, so a plain ReHLDS server is one env change away.

- [x] `ENABLE_REGAMEDLL` (1): ReGameDLL `cs.so` + `delta.lst`, or the stock ones (kept in the image)
- [x] `ENABLE_METAMOD` (1): `liblist.gam` `gamedll_linux` points at metamod, or straight at `dlls/cs.so`
- [x] `ENABLE_AMXMODX` (1, needs metamod): the amxmodx line in `addons/metamod/plugins.ini`. ReAPI comes with it
- [x] Binaries (`cs.so`, metamod, amxx dlls/modules) are refreshed from the image on every start, so rebuilding the image actually upgrades them. Configs and plugins in the volume are left alone
- [x] Warn and skip when a dependency is off (AMXX without metamod, voice without ReAPI/ReGameDLL)

## 2. Replays (HLTV)

ReHLDS ships the open-source ReHLTV (`hltv`, `proxy.so`, `core.so`), already in the image.

- [x] `ENABLE_HLTV` (0): start `hltv` in the container, connected to 127.0.0.1, auto-retry, restarted if it dies
- [x] `HLTV_<CMD>=value` is passed as `+<cmd> value` (`HLTV_DELAY`, `HLTV_MAXCLIENTS`, `HLTV_NAME`, ...). `HLTV_RECORD=demos/match` records `demos/match-<date>-<map>.dem`, one file per map
- [x] Defaults: record on, `maxclients 0` (no live spectators, since it can hear both teams), port 27020 not published
- [x] HLTV takes a player slot: competitive needs `+maxplayers 11` (competitive branch, 2026-11-18)
- [x] Demos go to the HDD instead of being pruned: `compose.override.yaml` (gitignored, per host) mounts `/tank/media/Replays/Counter-Strike_1.6/<Regular|Competitive>` over `cstrike/demos`

## 3. Voice in demos

From the source: ReHLTV writes every `svc_voicedata` it gets into the demo (`DemoClient::IsHearingVoices` is always true), and each packet carries the sender's slot. The server only sends HLTV the voices ReGameDLL's `CanPlayerHearPlayer` allows. As an unassigned spectator, it hears no one unless `sv_alltalk` is 1 or 3 (bad for competitive).

- [x] `hltv_voice.sma` (AMXX + ReAPI): hook `RG_CSGameRules_CanPlayerHearPlayer` and return true when the listener `is_user_hltv`. Players' comms stay team-only
- [x] `ENABLE_HLTV_VOICE` (1 when HLTV is on): toggles the plugin through `AMXX_PLUGIN_HLTV_VOICE`
- [x] Test (2026-11-18: one player on CT, voice recorded and decoded; still to check with two players on different teams that each hears only their team): record with two clients talking, check the demo for `svc_voicedata` (and that playback in the game client has voice)

## 4. Per-player audio tracks (goldsrc-demo-tools, was goldsrc-hltv-voice)

`goldsrc-hltv-voice <demo.dem> [-o out.mka] [--tracks player|team|mix] [--order join|team] [--dump] [--lenient]`. Prototyped in Rust as `tools/demo-voice` (removed 2026-11-18, see git history)

- [x] Parse the demo with the `dem` crate. Every frame parses (checked on a real ReHLTV demo)
- [x] One track per player, named after them, with the SteamID in a `STEAMID` tag. Keyed by `*sid`, so a rejoin, even in another slot, continues the same track. HLTV (`*hltv`) is skipped
- [x] `--order join` (default, any server): first join. `--order team` (competitive): starting team, T then CT, join order within a team
- [x] `--tracks team|mix`: one track per starting team, or everyone in one track
- [x] Each packet is placed at its demo time and muxed to `.mka` (Opus) with ffmpeg
- [x] **Decoding.** Confirmed 2026-11-18 on a real demo: Steam voice, 24 kHz, Opus PLC chunks (u16 len, u16 seq, frame), CRC ok. Decoded with libopus (`opus` crate), one stateful decoder per player, short losses concealed
- [x] Packet timing (2026-11-19, all 3 demos with voice plus the tool's test demo, one speaker each): HLTV frames come every ~54 ms with 2-3 Opus frames (20 ms each) per packet, up to 110 ms apart. A spurt's first packet carries up to 140 ms of buffered audio, so placing each packet at its demo time (or after the previous audio) keeps 17-97 ms of headroom: no holes inside a spurt and no drift from a steady 20 ms clock. To check again with more players or a busy server: placing a spurt on its sequence numbers instead would rule holes out entirely
- [x] Per-server `--order`: regular = `join`, competitive = `team`: `VOICE_MKA_ARGS: "--order team"`, set by `presets/competitive.env` (2026-11-18)
- [x] Run it automatically after each map (HLTV closes the file on map change): `voice.sh`, `ENABLE_VOICE_MKA` (2026-11-18)
- [x] Rewrite in Zig as its own project: [goldsrc-hltv-voice](https://git.nnstdios.com/nnra6864/goldsrc-hltv-voice), built in the image (2026-11-18)

## 5. Layout

- [x] Competitive as a preset instead of a `competitive` branch; every server runs master (2026-11-18). Presets are env files (`presets/defaults.env`, `presets/competitive.env`) listed in `compose.override.yaml`, which goes on top: podman-compose 1.6 `include:` merges the included file last (the preset would win) and `extends:` puts the preset under `compose.yaml` (the defaults would win). `MAXPLAYERS` replaces `+maxplayers` so a preset can set it
- [x] Container scripts in `scripts/` (2026-11-18)
- [x] `hltv_voice` became `hltv_tools`: also writes the player count (bots, HLTV not counted) for recording only while someone is on. An old `hltv_voice` line in `plugins.ini` is turned off (2026-11-19)
- [x] Record only while players are on (`RECORD_IDLE_STOP`), repair demos a crash left unfinished, delete demos nobody joined (`DELETE_EMPTY_DEMOS`), `.mka` for the rest: `hltv.sh`, `demos.sh` (was `voice.sh`), goldsrc-demo-tools (2026-11-19)
- [x] The plugin (hltv-tools) and goldsrc-demo-tools as git submodules with relative URLs: built from wherever this repo was cloned (GitHub or the Forgejo mirror), no clones during the build (2026-11-19)

## 6. Maps (packs)

- [x] Packs: a dir per pack, laid out like `cstrike`, symlinked in (`scripts/packs.sh`, links listed in `cstrike/packs_links.txt`). Files already in `cstrike` are never replaced (2026-11-19)
- [x] The maps CS ships with (with their `maps/*.txt`, `.res` and overviews, and the stock `mapcycle.txt` for their order) as the `default` pack in the image. Old volumes: their files that match the image's are removed and linked back (2026-11-19)
- [x] `data/` next to `cstrike/`: ours (packlist, packs, downloads, fastdl), `cstrike/` stays the game's (2026-11-19)
- [x] `data/packlist` instead of an env var, so it can change live: `podman exec <container> packs` relinks, new maps work from the next map change. `pack/de_*`, `*`, `-cs_*`, URLs (GameBanana pages through apiv11 with its MD5, `/dl/` links, any direct `.zip`/`.rar`/`.7z`/`.bsp`), `name=URL`. Any archive layout is put into shape (2026-11-19)
- [x] Map cycle from the packs (`MAPCYCLE`, on by default). A `MAP` the packs left out falls back to the first map in the cycle (2026-11-19)
- [x] Shared library on `/opt/hlds/library`: one copy of every file for all servers, per-server `servers/<name>` so a download goes once no server lists it, a lock so servers don't run at once (2026-11-19)
- [x] FastDL: `FASTDL_URL` sets `sv_downloadurl` and writes `fastdl/<name>/`, relative links to exactly this server's files, for Angie (2026-11-19)
- [x] Tags: a `tags` file in the library, `[tag.X]` and `[map.X]`/`[plugin.X]`/`[pack.X]` headers with names on the line or below; `@tag` in tags. Packlist `@snow`, `@snow+competitive`, `-@xmas`, and packs or maps by name wherever they are in `packs/`. `packs tags` lists them and warns about names that match nothing (2026-11-19)
- [x] `cs` command in the container: `reload [--now]` (was `packs`), `tags`, `save`, `console <command>` through a FIFO the server reads, with what's typed on the attached console passed on. Its output goes through a pipe too: stdin a FIFO with stdout the terminal made HLDS segfault on start. `save` always writes a zip, a `.rar`/`.7z` as a zip of the same files (2026-11-19)
- [ ] The packlist from the override (`PACKLIST` env, lines like the file), so each server's packs are with its other settings
- [x] HTTPS for `sv_downloadurl`: the client doesn't (2026-11-19: with an `https://` URL, a 443 block with its own log got no request and the map came the slow way). The client keeps the download URL until the game restarts
- [x] Build files in `image/` (Dockerfile, scripts, the plugin and tool submodules), so the repo's top is what you touch to run a server (2026-11-19)
- [x] Plugins in packs instead of a `data/plugins/`: `.sma` compiled (cached), linked, in `plugins.ini` between `; packs:` lines in packlist order, configs copied once. Packs in `packs/` can be archives or lone `.bsp`/`.sma`/`.amxx`, unpacked into `.cache/`; dirs that aren't packs group them (`maps/fy_snow`, `maps`, `maps/de_*`). Origin from a zip comment or a `.url` file; `packs save <download> [dir]` keeps a download in `packs/`, tagged, the download kept as it came in `.original/` (2026-11-19)
- [x] `cs save -r` reloads after saving and says whether the pack is in use (the maps to `changelevel` to); `-t snow,xmas` adds it to tags, sorted into the tags file, and `podman exec -it` gets a picker (`tagpick.sh`) instead (2026-11-20)
- [x] `cs remove [-r] [-y] <pack or map>`: deletes the pack and its mentions in the tags file, after showing them and asking (2026-11-20)
- [x] ~~A competitive map pool for `presets/competitive.env`~~: not needed, a competitive server's packlist says `@competitive` and the tags file holds the pool (2026-11-19)
