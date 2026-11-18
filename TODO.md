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
- [ ] Demos land in `cstrike/demos/`. Prune old ones? (kivotos snapshots this dir, so size matters)

## 3. Voice in demos

From the source: ReHLTV writes every `svc_voicedata` it gets into the demo (`DemoClient::IsHearingVoices` is always true), and each packet carries the sender's slot. The server only sends HLTV the voices ReGameDLL's `CanPlayerHearPlayer` allows. As an unassigned spectator, it hears no one unless `sv_alltalk` is 1 or 3 (bad for competitive).

- [x] `hltv_voice.sma` (AMXX + ReAPI): hook `RG_CSGameRules_CanPlayerHearPlayer` and return true when the listener `is_user_hltv`. Players' comms stay team-only
- [x] `ENABLE_HLTV_VOICE` (1 when HLTV is on): toggles the plugin through `AMXX_PLUGIN_HLTV_VOICE`
- [x] Test (2026-11-18: one player on CT, voice recorded and decoded; still to check with two players on different teams that each hears only their team): record with two clients talking, check the demo for `svc_voicedata` (and that playback in the game client has voice)

## 4. Per-player audio tracks (`tools/demo-voice`)

`demo-voice <demo.dem> [-o out.mka] [--tracks player|team|mix] [--order join|team] [--dump]`

- [x] Parse the demo with the `dem` crate. Every frame parses (checked on a real ReHLTV demo)
- [x] One track per player, named after them, with the SteamID in a `STEAMID` tag. Keyed by `*sid`, so a rejoin, even in another slot, continues the same track. HLTV (`*hltv`) is skipped
- [x] `--order join` (default, any server): first join. `--order team` (competitive): starting team, T then CT, join order within a team
- [x] `--tracks team|mix`: one track per starting team, or everyone in one track
- [x] Each packet is placed at its demo time and muxed to `.mka` (Opus) with ffmpeg
- [x] **Decoding.** Confirmed 2026-11-18 on a real demo: Steam voice, 24 kHz, Opus PLC chunks (u16 len, u16 seq, frame), CRC ok. Decoded with libopus (`opus` crate), one stateful decoder per player, short losses concealed
- [ ] Packet timing: demo frame time is about 1/updaterate, so check for gaps or jitter once real audio decodes
- [ ] Per-server default for `--order` (env on the server, e.g. `DEMO_VOICE_ORDER=team`)
- [ ] Optional: run it automatically after each map (HLTV closes the file on map change)
- [ ] Later: rewrite the Rust tooling (`tools/demo-voice`) in Zig
