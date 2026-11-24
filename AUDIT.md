# Audit (2026-11-24)

What was reviewed: everything tracked in the repo (about 3,770 lines; `packs.sh` alone is 1,581 of them, 42%), plus the `hltv-tools` plugin. Not reviewed: the inside of `goldsrc-demo-tools`, which has its own tests and docs.

How it was checked:

- Read every script, the Dockerfile, compose, presets and the README.
- Ran `shellcheck` (clean apart from info notes and one SC2115) and `shfmt -d` (some formatting differences, since formatting isn't enforced).
- Benchmarked `packs.sh` in a throwaway container from the live image (`--network none`), with a copy of the shared library in the scratchpad. Nothing live was changed. The only thing run against the live server was a read-only `cs tags`.
- Read the live state: `counter-strike-NnCompetitive`'s `cstrike/`, the shared library at `/tank/services/counter-strike`, the replay dirs, and the podman images.

## Status (2026-11-24, later that day)

Done, each in its own commit (`git log c4569ed..`), with `tests/run.sh` (16 cases) passing:

- §1.1 password masked, every HLTV value quoted · §1.2/§2.1 link diff (2,000 files: 8.3 s / 5.1 s → 0.18 s / 0.1 s; the real library gives the same result as before) · §1.3 lock · §1.4 `settings.sh`, `cs reload` applies the environment · §1.5 `-name` for packs, warns on no match · §1.6 compile key, failed builds remembered · §1.7 gamedata synced · §1.8 nested archives indexed, failed `.sma` not retried, `demos.sh` supervised, stray files in `packs/` warned about, read-only commands write nothing, 2 GB download cap, `*` documented
- §2.2 fewer forks in the index, regexes cached, zip comments cached, `demos.sh` one awk per poll, `env-config` skips `demos/` and `logs/` · §2.3 one image name in compose
- §3.1 `./cs` · §3.2 `cs console` prints the reply, `cs log` · §3.3 cause found: the user journal is capped at ~50 MB and other containers rotate it within hours; `cs log` doesn't depend on it · §3.4 reload summary (`-v`), `cs tags` wrapped, `cs maps` · §3.5 `PACKLIST` · §3.6 one picker (and a fix for a terminal that reports 0 columns)
- §4.1 awk programs in `lib/`, downloads in `lib/fetch.sh` (`packs.sh` 1,581 → about 1,070 lines) · §4.2 one tags-file parser, `on`/`lower`/`write_in_place` in `common.sh` · §4.3 legacy listed in `TODO.md` §7 · §4.4 the test harness · §4.5 save's output documented, SC2115, `update-ca-certificates`
- §6 HLTV docs, `packs.sh` header, `~/Containers/AGENTS.md`

Left (see `TODO.md` §8): §5 checksums and base image pins, and §2.3 trimming `valve/` (both need a rebuild and a test start), removing the orphaned image, `hltv_tools` writing only on change and the "demo finished" check in `goldsrc-demo-tools` (other repos), and moving the packs docs out of the README (§6).

Priorities: **P1** fix soon, **P2** worth doing, **P3** when you're in there anyway. Effort: **S** under an hour, **M** an evening, **L** more than that.

---

## Top of the list

| # | What | P | Effort |
|---|---|---|---|
| 1 | HLTV prints `sv_password` (and any `HLTV_*PASSWORD`) to the logs | P1 | S |
| 2 | `cs reload` removes every link before making the new ones: maps go missing for a moment on a live server, and it's the slow part | P1 | M |
| 3 | The packs lock is held while the GameBanana file picker waits for you; after a 30 min timeout another run goes ahead anyway and deletes its temp dirs | P2 | S |
| 4 | `cs reload` doesn't apply the environment again (`AMXX_PLUGIN_X=0` for a new pack plugin, `CVAR_` in a newly copied config) | P2 | M |
| 5 | `-name` in the packlist silently does nothing for a pack without maps (plugin packs) | P2 | S |
| 6 | There are three ~1.2 GB images that share no layers, and one belongs to a clone that no longer exists | P2 | S |
| 7 | `packs.sh` is one 1,581-line file with five separate parsers for the tags file and no tests | P2 | L |
| 8 | UX: a `cs` wrapper on the host, `cs console` showing its output, `podman logs` returning nothing | P2 | M |
| 9 | The plugin compile cache key ignores the image's include files (a ReAPI bump keeps stale `.amxx`) | P3 | S |
| 10 | `demos.sh` forks a `grep` per demo every 15 s, forever | P3 | S |

The details follow, by area.

---

## 1. Correctness and safety

### 1.1 HLTV logs the server password (P1, S)

`hltv.sh:27-28` copies `CVAR_SV_PASSWORD` into `HLTV_SERVERPASSWORD`. The loop at `hltv.sh:48` turns every `HLTV_*` variable into a console command. Then `hltv.sh:140` prints every command to stdout:

```
[hltv] starting on port 27020, commands:
[hltv]   serverpassword "the-actual-password"
```

That goes into the container log and then journald, on every HLTV (re)start. The same happens to `HLTV_RCONPASSWORD`, `HLTV_ADMINPASSWORD` and so on.

**Fix:** mask the value when printing, e.g. `sed 's/^\([a-z_]*password\) .*/\1 ****/'` on the printed copy only.

A smaller issue: `quote()` (`hltv.sh:41`) only adds quotes when the value has whitespace. A value containing `;` or `"` (a password, say) would split or break the HLTV console command. Quote every value, and refuse `"` and newlines.

### 1.2 `cs reload` takes every link down before putting the new ones up (P1, M)

`packs.sh:1287-1292` deletes every link listed in `packs_links.txt`, then rebuilds them all one by one in the loop at `1387-1508`. On a live server this leaves a window, up to several seconds with a big pack (see §2.1), where `maps/*.bsp`, models and sounds don't exist. A `changelevel`, a vote, or a client connecting and fetching resources in that window fails or gets kicked.

**Fix (also the main speedup):**

1. Build the wanted set (`path<TAB>target`) first.
2. Read the existing links in one go with `find "$GAME" -type l -printf '%P\t%l\n'`.
3. Diff the two with awk.
4. Remove only the links that are gone or point somewhere else, and create only the missing ones.

A reload that changes nothing then touches nothing. FastDL is already swapped in atomically (`1566-1578`), so this is the same idea for `cstrike/`.

### 1.3 The packs lock: held across a prompt, then ignored (P2, S)

- `packs.sh:111-115` takes `flock` at the top level, before the subcommand dispatch, so **every** `packs.sh` call holds it, including `tags`, `tagnames` and `autotags`.
- `cs save <gamebanana page with several files>` reaches `pick.sh` (`packs.sh:190`) **with the lock held**. While you look at the list, any other server sharing the library that starts or reloads blocks, for up to 1,800 s.
- When the wait times out, it says "going ahead anyway" and then runs `rm -rf "$DOWNLOADS"/.tmp.* "$CACHE"/.tmp.*` (`115`). That deletes the temp dirs of the run that still holds the lock.

**Fix:**

- Choose the file before taking the lock: resolve the GameBanana page and pick first, then lock and download.
- Don't lock for read-only subcommands.
- On timeout, fail rather than go ahead, or at least skip the `rm` of temp dirs.

### 1.4 `cs reload` and the environment (P2, M)

Only the entrypoint runs `env-config.sh`. `cs reload` runs only `packs.sh`. As a result, after a reload:

- a pack plugin that was just added sits in `plugins.ini` **enabled**, even when the override says `AMXX_PLUGIN_<NAME>: "0"` (the README promises that this "still turns one off");
- configs just copied from a pack (`packs.sh:1464-1470`) don't get their `CVAR_` values until the next restart.

You can't simply call `env-config.sh` from `cs reload`. `components.sh` and the entrypoint *derive* variables (`METAMOD_PLUGIN_AMXMODX`, `AMXX_PLUGIN_HLTV_TOOLS`, `CVAR_HLTV_TOOLS_VOICE`, `CVAR_MAPCYCLEFILE`, `CVAR_SV_DOWNLOADURL`) and export them only into the entrypoint's own process. A `podman exec` doesn't have them. Because env-config is reversible, running it without them would **restore the originals**: the mapcycle and the download URL would be reverted.

The same trap applies to anyone who runs `podman exec … /opt/hlds/env-config.sh` without `--list`. Today nothing does, but it's an easy mistake.

**Fix:**

1. Move the derivation (the `components.sh` exports plus `entrypoint.sh:17-29`) into a sourced `settings.sh` that only computes and exports, with no side effects.
2. Have the entrypoint source it, then do the file work.
3. Make `cs reload` run `. settings.sh; packs.sh; env-config.sh`.

### 1.5 `-name` in the packlist only excludes maps (P2, S)

`packs.sh:1197`: `-*)` appends the pattern to `excludes`, which is checked only against **map** names. A plugin pack (or any pack without maps) is never excluded, and nothing warns. This was checked in the bench: with a packlist of `default`, `*` and `-foo`, plus `packs/plugins/foo.sma`, the result was `foo.amxx` in the `; packs:` block of `plugins.ini`.

`-@tag` already handles this (`exclude_units`, `783-793`, adds map-less packs to `xpacks`).

**Fix:** for `-name`, also run `tags match name | exclude_units`. Also warn when an exclusion matches nothing, which catches typos.

### 1.6 Plugin compile cache key (P3, S)

`compile()` (`packs.sh:1347-1351`) keys on `amxxpc32.so`, the source and the pack's own `include/`. `amxxpc` also reads the **image's** `scripting/include/` (AMXX, ReAPI). A `REAPI_VER` bump changes `reapi*.inc` but not `amxxpc32.so`, so cached `.amxx` built against the old headers keep being used.

**Fix:** add `find "$AMXXPC/include" -type f | sort | xargs cat | md5sum` to the key, or simply `AMXX_VER`/`REAPI_VER` written to a file in the image.

`.cache/amxx/` is also never pruned. Each edit of a `.sma` leaves the old build behind. It's small, but it grows.

### 1.7 AMXX gamedata isn't refreshed on upgrade (P3, S, latent)

`components.sh:76-86` refreshes AMXX `dlls/*.so` and `modules/*.so`, but not `addons/amxmodx/data/gamedata/`, which holds the offsets and signatures tied to the AMXX build. Today the volume's copy matches the image's (checked with `diff -rq`), because `AMXX_VER` hasn't changed since the volume was made.

The first AMXX bump would leave old gamedata next to new modules. That's how hamsandwich and fakemeta plugins break subtly. The files aren't user config.

**Fix:** sync the gamedata tree the same way the modules are synced.

### 1.8 Smaller ones (P3)

- **Maps inside a nested archive aren't indexed until the archive is unpacked.** `pack_maps` (`packs.sh:595-603`) lists only the outer archive with `bsdtar -tf`. `unpack` (`297-301`) also opens inner archives. A tag or packlist entry that names a map inside an inner zip doesn't match until something else causes that pack to be unpacked.
- **A `.sma` that doesn't compile is retried on every reload**, printing the same errors each time. There's no negative cache keyed on the same hash.
- **`demos.sh` isn't supervised.** It's started once (`hltv.sh:61`). If it dies, demos stop being handled and nothing says so. `hltv.sh` could restart it the way it restarts `hltv`.
- **Unknown files in `packs/` are ignored without a word.** For example, the shared library still has a `packs/tags` (78 bytes, Nov 19) left from an older layout, while the real tags file is `tags` next to `packs/`. `cs tags` could list files in `packs/` that are neither packs, groups nor `.url`.
- **Read-only subcommands write files.** Even `packs.sh tags` and `tagnames` create `packlist`, `tags`, `autotags` and `mkdir`s if they're missing (`107-141`, `611-662`). If the library mount were ever missing, `cs tags` would quietly start a fresh library in `data/`.
- **Downloads have no size limit.** There's no `curl --max-filesize` and no cap on extraction. The URLs are yours, but a GameBanana uploader can replace a file. A few GB cap is cheap insurance.
- **`*` in the default packlist means "every plugin in `packs/` too".** On a shared library, `cs save` of a plugin goes live on every server whose packlist has `*` at its next reload. That's by design, but it's worth a line in the template: `*` is everything, plugins included.

---

## 2. Performance

### 2.1 `packs.sh` cost per file (measured)

These numbers come from a throwaway container on the live image, using a copy of the shared library: 16 packs, 232 links, the `default` pack plus 15 map zips.

| Library | Cold (first run, unpacking) | Warm (`cs reload`, nothing changed) |
|---|---|---|
| as it is now | 1.6 s | 0.67 s |
| plus one pack of 2,000 small files (a model or sound pack) | 8.3 s | 5.1 s |

That works out to about **2.2 ms per file on every reload**, and nearly all of it is forks. For each file the link loop runs `mkdir -p`, a `$(link_target …)` subshell that runs `up()` (`printf | sed`), and `ln -s`.

A real zombie or jail mod with a few thousand sounds and models makes every reload (and every container start) take 5-15 s. During that time the server has no links (§1.2).

**Fix:**

- The diff from §1.2 removes nearly all of this.
- Then compute the link targets in awk, not with a subshell per file.
- Batch the `mkdir -p` calls: one call per distinct dir, or one `xargs mkdir -p`.

### 2.2 Other hot spots (P3; fine at today's size)

- **`index_walk` (`560-575`) forks a lot per entry.** It calls `is_pack_file` up to three times per entry, and each call forks `lower` (a subshell plus `tr`). A `case` on `*.[zZ][iI][pP]|…` needs no fork.
- **The tags `awk` rebuilds the same regexes over and over.** `matches()` (`686-689`) calls `glob2re` for every (member, index row) pair. That's O(members × maps) regex builds on every `tags` call, and `@a+b` queries and `check` repeat it. Caching `re[m]` is a one-line change.
- **Every `cs save` runs `unzip -qz` on every pack in the library** (`840-842`), to see whether the URL is already saved. That's fine for 16 packs and slow for 500. Keeping `origin` in the index cache, keyed by the same size+mtime stamp as `.maps`, fixes it.
- **`demos.sh:71` forks `grep` once per `.dem` in the demo dir, every 15 s, forever.** It's 39 demos today, but after a year of nightly games it would be thousands of forks every 15 s, scanning a dir on the HDD. One `comm` or `awk` over the dir listing and the done list per poll does the same with two forks. `hltv_demos_done.txt` is also never pruned.
- **`env-config.sh:47` runs `find .` over all of `cstrike/` on every start**, including the `demos/` mount (HDD) and `logs/`. Add `-path ./demos -prune -o -path ./logs -prune -o`.
- **`hltv_tools` rewrites `hltv_tools_players.txt` every 2 s, around the clock** (`hltv_tools.sma:29`; the file's mtime was "now" when checked). That's harmless on ZFS, but writing only when the count changes is one comparison.

### 2.3 Image size and storage (P2, S)

```
localhost/counter-strike-nncompetitive_counter-strike   1.22 GB   (running)
localhost/counter-strike_counter-strike                 1.15 GB   (Regular, stopped)
localhost/counter-strike-competitive_counter-strike     1.15 GB   (its clone is gone)
```

The images share only the Debian base layer. Their 967 MB CS layers have different digests, so this is about 3.5 GB on `tank/podman` for one running server.

- `compose.yaml` has `build:` but no `image:`, so podman-compose names the image after the project directory. Adding `image: localhost/counter-strike:latest` gives every clone the same image and one build. All clones run `master` now, so nothing conflicts, and only one server runs at a time anyway.
- `counter-strike-competitive_counter-strike` belongs to a clone that's no longer in `~/Containers`. `podman rmi` would free 1.15 GB (your call).
- What's in the 967 MB layer, measured in the running container:

  | Dir | Size |
  |---|---|
  | `valve/` | 315 MB |
  | `valve/maps` (Half-Life campaign maps) | 111 MB |
  | `valve/media` (soundtrack) | 56 MB |
  | `linux64/` (64-bit Steam libraries; HLDS is 32-bit) | 21 MB |
  | `steamapps/` (`downloading/`, `temp/`) | leftovers |

  A cstrike server needs `valve/`'s wads, models and sounds, but almost certainly not the HL1 campaign maps or music. Dropping them saves about 190 MB per image. Test one start and one map change before relying on that.

---

## 3. UX

### 3.1 A `cs` on the host (P2, S)

Every command today is `podman exec [-it] counter-strike-NnCompetitive cs …`. Two problems follow:

- It's long to type.
- Forgetting `-it` quietly changes behaviour: there's no picker, autotags get applied, and `remove` refuses.

A small `cs` script in the repo root solves both:

```sh
#!/bin/sh
# ./cs <command>: runs cs in this clone's container (a sketch: check podman-compose ps --format)
c=$(podman compose ps --format '{{.Names}}' | head -n 1)
[ -t 0 ] && t=-it || t=-i
exec podman exec $t "$c" cs "$@"
```

It can also take the host-side jobs that today live only in the README: `./cs up` for `podman compose up -d --force-recreate`, `./cs attach`, and `./cs logs`.

### 3.2 `cs console` shows nothing (P2, M)

`cs console status` writes to the FIFO, and the reply goes only to the container's stdout. That makes `status`, `maps *`, `meta list`, `amx_plugins` and similar useless from `exec`.

**Fix:** the entrypoint already copies server output through `cat "$OUT"` (`entrypoint.sh:84-85`). Make it `tee` into `/tmp/server.log`, truncated when it passes a few MB. `cs console` then notes the file size, sends the command, waits about 0.5 s (or until the output stops) and prints what was added.

### 3.3 `podman logs` came back empty (check this)

`podman logs counter-strike-NnCompetitive` returned 0 bytes, with or without `--tail` or `--since` (log driver: journald, tty on, started 2026-11-23 01:24). `journalctl --user CONTAINER_NAME=…` returned nothing either. `nn-survival` uses the same driver with a tty and *does* return lines, so the problem isn't the setup in general.

The cause wasn't found. It may be journald rate limiting during HLDS's startup burst, or something about how this container was started.

This matters because the README sends you to the log for everything: `[packs]` lines, `cs console` output, `[demos]` and `[hltv]`. Worth a look. §3.2 would also make `cs console` independent of the log.

### 3.4 Output

- **`cs reload` prints one line per pack**, every time. That's fine at 16 packs and noise at 200. Print a summary (maps, files, plugins, what changed since last time) plus warnings, and keep per-pack lines for `-v`.
- **`cs tags` prints each tag on one very long line**, and every entry repeats its path even when the path is just `maps/<same name>`:
  ```
  competitive: de_citadel (maps/de_citadel) de_dust2_winter16 (maps/de_dust2_winter16) …
  ```
  Show the path only when it differs from the name (`de_dust2_xmas (maps/de_dust2_xmas_2)`), and wrap the line, or print one name per line under the tag.
- **There's no command for "what does this server have right now".** A `cs maps` that prints the map cycle (`packs_mapcycle.txt`), plus the pack plugins in `plugins.ini`, saves digging in `cstrike/`.

### 3.5 Packlist

- `-name` should exclude packs as well as maps, and warn when it matches nothing (§1.5).
- The open TODO, `PACKLIST` from the env, fits: it puts all of a server's settings in its override. Keep `data/packlist` for live edits; when the env var is set, document which one wins.

### 3.6 Pickers

`pick.sh` and `tagpick.sh` are about 60% the same code (tty setup, `key()`, the scroll window, drawing). Make them one script with a `--multi` mode. If the tag list gets long, type-to-filter is the next useful thing; it's not needed today.

---

## 4. Code structure and cleanliness

### 4.1 `packs.sh` is doing eight jobs (P2, L)

It handles all of these:

- downloading (GameBanana API, picker, md5)
- archive normalising (`lay_out`)
- the library index
- the tags language (query, match, check, list)
- editing the tags file (`tag`, `remove`)
- `save`
- linking
- `plugins.ini`, the map cycle and FastDL

The subcommands are `if [ "$1" = save ]; then … exit; fi` blocks in the middle of the file (`802`, `930`, `938`, `962`, `995`, `1079`). They come *after* top-level code with side effects (lock, temp cleanup, writing templates), so every subcommand pays for those (§1.3, §1.8).

POSIX sh has no `local`, and the code already works around that: "Own names: the callers' loops use c and f" (`438`), and functions run in subshells for recursion. Each new feature makes a collision likelier.

A layout that keeps it in shell:

```
image/scripts/
  lib/common.sh      say, on, lower, up, write_in_place (for every script)
  packs/fetch.sh     gamebanana, fetch, unpack, lay_out
  packs/library.sh   index, pack_maps, origin, unpacked, resolve, expand
  packs/tags.awk     ONE parser of the tags format + query/match/check/list/names
  packs/tagedit.awk  tag / remove, sharing the parser through awk -f tags.awk -f tagedit.awk
  packs/link.sh      links (the diff, §1.2), plugins.ini, map cycle, fastdl
  packs.sh           init (only for commands that need it) + case "$1" dispatch
```

`awk -f a.awk -f b.awk` shares functions between programs, which removes the duplication described in §4.2.

Rewriting this in Python or Zig instead isn't worth it yet. The split plus tests (§4.4) is enough for its current size. Revisit if the tags language grows again.

### 4.2 Duplication

- **The tags file format is parsed five times:** `tags()` (`667`), `tagnames` (`938`), `autotags` (`962`), `tag` (`995`, with its own `hdr()`) and `remove` (`1079`, another `hdr()`). The rules already differ. `tags()` treats a `[…]` word *anywhere* on a line as a header. `hdr()` only recognises one at the start of a line. So `fy_snow [tag.xmas] de_x` means different things to `cs tags` and to `cs remove`.
- **`on()` exists in four files** (`components.sh:22`, `hltv.sh:32`, `demos.sh:27`, `packs.sh:76`) and is inlined twice more in `entrypoint.sh` (`20`, `35`). Put it in `lib/common.sh`.
- **The "demo finished" check** (`od -j 540`, a magic offset) appears in `hltv.sh:78` and `demos.sh:35`. It belongs in `goldsrc-demo-tools`, which already parses the header, e.g. `goldsrc-demo-tools info --finished` as an exit code.
- **"Write in place to keep labels"** (`cmp -s || cat >`) appears in four places. Make it one `write_in_place src dst` function.
- **The two pickers** (§3.6).

### 4.3 Legacy code that runs on every start

These are migrations for old volumes. Each one is cheap, but it's code to read and keep working forever. Put a "remove after …" note on each (or a list in TODO), and delete them once every volume has migrated:

- default maps from `cstrike/maps` to the default pack (`packs.sh:1295-1312`, a `find` plus `cmp` on every start)
- `hltv_voice` → `hltv_tools` (`components.sh:118-122`)
- saving downloads from before `.original/` was kept (`packs.sh:896-898`)

### 4.4 Tests (P2, M, the most useful change in this section)

The demo tool has tests. The scripts, which hold most of the logic and all of the edge cases, have none. The benchmark for this audit was most of a test harness already:

- **The harness:** `tests/run.sh` starts the built image with `--network none`, a fixture library and a scratch `cstrike/`, runs `packs.sh` or `env-config.sh`, and compares the result with expected files.
- **Fixtures** (all tiny):
  - a map-only zip
  - a zip inside a zip
  - an AlliedModders layout (`scripting/` + `configs/` + `data/lang/`)
  - a `.rar`
  - a lone `.bsp`
  - a broken `.sma`
- **URL entries without a network:** `curl` reads `file://`, so the fetch path can be tested offline.
- **Assertions:**
  - `packs_links.txt`
  - the `; packs:` block of `plugins.ini`
  - `packs_mapcycle.txt`
  - packlist cases: `-name`, `@a+b`, `-@x`, `mypack/de_*`, first pack wins
  - the env-config round trip: apply a variable, remove it, and the file is byte-for-byte the original
- **Lint:** `shellcheck` and `shfmt -d` in the same script, as a pre-commit hook.

### 4.5 Smaller

- **`cs save` relies on a hidden contract.** `packs.sh save` prints `name<TAB>path` on stdout for `cs.sh` (`cs.sh:71-73`), and all of its messages go to stderr. It works, but it's undocumented on the `packs.sh` side. A comment there would do, or `packs.sh save --tags …` could do the tagging itself.
- **`env-config.sh:30`:** `rm -rf "$TMP"/*`: use `${TMP:?}` (shellcheck SC2115).
- **`Dockerfile:206`:** `update-ca-certificates` is redundant (the package's postinst runs it).

---

## 5. Image and build

- **Only libopus has a checksum.** ReHLDS, ReGameDLL, Metamod-R, AMXX, ReAPI (`Dockerfile:69-104`) and Zig (`182`) are downloaded unchecked. Add `ARG *_SHA256` next to each version, the way opus does (`169`, `177`). It's cheap, and a moved or replaced release then fails the build instead of shipping.
- **The base images are unpinned:** `cm2network/steamcmd:latest` and `debian:bookworm-slim`. Bookworm is past its regular security support and in LTS now. Trixie is the stable release, and it still has the i386 multiarch libraries HLDS needs (check `libstdc++6:i386` there before switching). Pinning by digest makes rebuilds reproducible; you'd bump it on purpose.
- **Share one image name** and remove the orphaned image (§2.3).
- **Trim `valve/`** (§2.3).
- **The layering is good.** The 967 MB CS layer is cached on its own, the add-ons are a small diff layer, and the scripts come last. Keep it that way.

---

## 6. Docs

- **The same reference is maintained in five places:**
  - the README
  - the `packs.sh` header (`1-58`)
  - the packlist template (`118-139`)
  - the tags and autotags templates (`611-662`)
  - the `cs.sh` usage (`2-26`)

  It has already drifted. `hltv.sh:13` and the README's Replays table say `HLTV_<CMD>` is "run as `+<cmd> value`", but since commands go through the console (`hltv.sh:43-44`), they aren't.

  **Suggestion:**
  - The README is the reference.
  - `cs help` is the short version.
  - The templates are examples.
  - The script headers keep only developer notes (why, not what) and point to README sections.
- **The README is 541 lines**, mostly packs. Packs, tags, saving, removing, sharing and FastDL could move to `docs/packs.md`, leaving the README with: what it is, build, run, settings, commands.
- **Outside the repo, `~/Containers/AGENTS.md` is stale:**
  - It still describes `counter-strike-NnCompetitive` as a copy of `counter-strike-competitive` (branch `competitive`) and lists that clone. The clone is gone, and NnCompetitive is on `master` with `presets/competitive.env`.
  - It gives the replay path as `Counter-Strike_1.6/NnCompetitive`. The override mounts `/tank/media/Replays/Counter-Strike/NnCompetitive`.

---

## 7. Things that are good, and should stay

- **`env-config.awk` is fully reversible.** The `env-managed:`/`env-original:` markers, and "removing the variable restores the file", make env-driven config safe. Few projects get this right.
- **Files are written in place** to keep ownership and SELinux labels, and comments explain why wherever it's done.
- **Downloads are handled carefully:**
  - GameBanana md5 checks
  - symlinks stripped from archives
  - the original file kept in `.original/`
  - temp dirs on the same filesystem, moved into place
  - the FastDL dir swapped in atomically
- **The entrypoint's stop order** (HLTV finishes its demo, then the server stops), and the restart loops that survive crashes.
- **The Dockerfile's diff-layer trick** for add-ons, and the check that fails the build if an add-on deletes a CS file.
- **Comments say *why*, not what,** throughout. That's what made this audit quick.
- **`TODO.md` is a real log of decisions**, with dates and reasons.

---

## Suggested order

1. §1.1 the password mask (minutes).
2. §2.3 `image:` in compose, and remove the orphaned image.
3. §1.5 `-name` for packs, and §1.3 the lock (both small).
4. §4.4 the test harness, *before* the larger changes, so they come with a safety net.
5. §1.2 and §2.1 the link diff (correctness and speed together).
6. §1.4 `settings.sh`, so `cs reload` applies the environment.
7. §3.1 and §3.2, the host `cs` and `cs console` output.
8. §4.1 split `packs.sh`, one tags parser.
9. The rest of the P3s as you pass by.
