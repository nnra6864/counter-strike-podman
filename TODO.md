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
- [ ] HLTV takes a player slot: competitive needs `+maxplayers 11`
- [ ] Demos land in `cstrike/demos/`. Prune old ones? (kivotos snapshots this dir, so size matters)

## 3. Voice in demos

From the source: ReHLTV writes every `svc_voicedata` it gets into the demo (`DemoClient::IsHearingVoices` is always true), and each packet carries the sender's slot. The server only sends HLTV the voices ReGameDLL's `CanPlayerHearPlayer` allows. As an unassigned spectator, it hears no one unless `sv_alltalk` is 1 or 3 (bad for competitive).

- [x] `hltv_voice.sma` (AMXX + ReAPI): hook `RG_CSGameRules_CanPlayerHearPlayer` and return true when the listener `is_user_hltv`. Players' comms stay team-only
- [x] `ENABLE_HLTV_VOICE` (1 when HLTV is on): toggles the plugin through `AMXX_PLUGIN_HLTV_VOICE`
- [ ] Test (2026-11-18: plugin loads, demo records, HLTV console via `/tmp/hltv.in` works; voice not tested yet): record with two clients talking, check the demo for `svc_voicedata` (and that playback in the game client has voice)

## 4. Per-player audio tracks (offline tool)

The demo already has what's needed: sender slot + codec frames + demo time. A tool can split them.

- [ ] Find out the codec. ReHLDS sends an empty `svc_voiceinit` codec, so Steam clients use Steam voice (SILK frames inside Steam's voice packet format, like CS:GO). Confirm from a real demo
- [ ] Tool (`tools/demo-voice`): parse the .dem (Rust `dem` crate, or a small Python parser), map slot → name/SteamID from userinfo, decode SILK, put each frame at its demo time, pad silence, write one track per player (`.mka`/`.ogg` per player, or a multi-track file)
- [ ] Optional: run it automatically after each map (HLTV closes the file on map change)
