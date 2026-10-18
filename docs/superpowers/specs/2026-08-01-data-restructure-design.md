# /data Restructure — Design

**Date:** 2026-08-01
**Branch:** `restructure/data-layout`
**Status:** Implemented 2026-10-18 (see the plan file header for deltas)

## Goal

Restore hardlinks and atomic moves across the *arr stack by consolidating downloads and
media under a single bind mount, and route new downloads into per-category folders.

## Problem

Sonarr, Radarr and Lidarr each see downloads and media through **separate bind mounts**:

```
sonarr:  /mnt/storage/downloads   -> /data
         /mnt/storage/video/tv    -> /mnt/storage/video/tv
radarr:  /mnt/storage/downloads   -> /data
         /mnt/storage/video/movie -> /mnt/storage/video/movie
lidarr:  /mnt/storage/downloads   -> /data
         /mnt/storage/audio       -> /music
```

`link()` returns `EXDEV` when the two paths sit on different mounts, even when those
mounts share one underlying filesystem. Every import is therefore a copy followed by a
delete: double the writes, and transient double space consumption on an array that is
already 75% full (3.6 TB free of 15 TB).

Three different path conventions are in use — host-identity mounts for video, `/music`
for audio, `/data` for downloads.

### What is already correct

Both download clients and all three *arrs agree on `/data` for downloads:

| Component | Setting | Value |
|---|---|---|
| qBittorrent | `Session\DefaultSavePath` | `/data/complete` |
| qBittorrent | `Session\TempPath` | `/data/incomplete` |
| NZBGet | `MainDir` | `/data` |
| NZBGet | `DestDir` | `/data/complete` |
| NZBGet | `InterDir` | `/data/incomplete` |

Paths align exactly, so **no remote path mappings are configured and none are needed**.
This must be preserved through the migration.

### Categories are configured but inert

qBittorrent's `categories.json` defines `lidarr`, `radarr`, `tv-sonarr`, `prowlarr`,
`readarr` with `save_path: ""`. NZBGet has `AppendCategoryDir=no` and empty `DestDir`
for all six categories. Result: everything lands flat in one folder — currently 111
mixed movie/TV/music items in `complete/`.

### Enabling fact

All media and downloads are on one device:

```
$ stat -c '%d' /mnt/storage/video/tv /mnt/storage/downloads/complete /mnt/storage/audio
2304
2304
2304                       # /dev/md0, ext4
```

Every move in this migration is a **rename**. No copying, no additional space, near
instant regardless of the 8+ TB involved.

## Target layout

```
/mnt/storage/data/                 ->  /data   (single mount, all *arrs + both clients)
├── complete/                          legacy torrent+usenet output, drains over time
├── incomplete/                        legacy in-progress
├── nzbget/                            nzbget queue, tmp, nzb, scripts, log
├── torrents/
│   ├── movies/
│   ├── tv/
│   └── music/
├── usenet/
│   ├── incomplete/
│   └── complete/{movies,tv,music}
└── media/
    ├── movies/                        <- /mnt/storage/video/movie
    ├── tv/                            <- /mnt/storage/video/tv
    └── music/                         <- /mnt/storage/audio
```

### Why `complete/` and `incomplete/` are preserved

qBittorrent stores an absolute save path per torrent. Renaming `downloads/complete` to
`data/complete` keeps the container-visible path `/data/complete` **byte-identical**, so
no torrent errors and nothing needs rechecking. New downloads go to `torrents/{category}`
and `usenet/`; the legacy folders drain naturally as old torrents are removed.

The alternative — sorting all 111 items into the canonical tree immediately — breaks the
save path of every active torrent. Rejected.

### Non-media content stays put

`/mnt/storage/downloads/` also holds `w5cqu` (39 GB), `web` (25 MB), `backup`,
`Tdarr_Node_Config.json` and `.Trash-1000`. None of these move. Only `complete`,
`incomplete` and `nzbget` are relocated out of it.

## Plex

Plex library metadata and watch history are keyed on file paths. Plex does not need
hardlinks. Its container paths are therefore **preserved via alias mounts** — the host
side changes, the container side does not:

```yaml
plex:
  volumes:
    - ${STORAGE_DIRECTORY}/data/media/movies:/mnt/storage/video/movie:rw
    - ${STORAGE_DIRECTORY}/data/media/tv:/mnt/storage/video/tv:rw
    - ${STORAGE_DIRECTORY}/data/media/music:/mnt/storage/audio:rw
    - ${STORAGE_DIRECTORY}/photos:/mnt/storage/photos:rw   # unchanged
```

No library edits, no rescan, no risk to watch history. The cosmetic inconsistency in the
compose file is an accepted trade.

## Compose changes

Every *arr gets one mount. Both download clients get the same one.

```yaml
sonarr:  volumes: [ "${CONFIG_DIRECTORY}/sonarr:/config", "${STORAGE_DIRECTORY}/data:/data" ]
radarr:  volumes: [ "${CONFIG_DIRECTORY}/radarr:/config", "${STORAGE_DIRECTORY}/data:/data" ]
lidarr:  volumes: [ "${CONFIG_DIRECTORY}/lidarr/config:/config", "${STORAGE_DIRECTORY}/data:/data" ]
qbittorrent: volumes: [ "${CONFIG_DIRECTORY}/qbittorrent:/config", "${STORAGE_DIRECTORY}/data:/data" ]
nzbget:  volumes: [ "${CONFIG_DIRECTORY}/nzbget:/config", "${STORAGE_DIRECTORY}/data:/data" ]
```

Removed: the `${STORAGE_DIRECTORY}/downloads:/downloads` duplicate on qBittorrent (it
pointed at the same host directory as `/data`), and the `video/tv`, `video/movie`,
`audio` identity mounts on the *arrs.

## Database re-pointing

Root folders cannot be changed through the UI — Sonarr would attempt to *move* files that
are already in place and fail. The paths are updated directly with containers stopped.

Back up first:

```bash
cp config/sonarr/sonarr.db{,.bak-20260801}
cp config/radarr/radarr.db{,.bak-20260801}
cp config/lidarr/config/lidarr.db{,.bak-20260801}
```

Three tables per app: `RootFolders.Path`, the main entity table `.Path`, and
`ImportLists.RootFolderPath`. Schemas confirmed present in all three databases; Lidarr has
3 import list rows that a `RootFolders`-only rewrite would miss.

| App | Tables | Old prefix | New prefix |
|---|---|---|---|
| Sonarr | `RootFolders`, `Series`, `ImportLists` | `/mnt/storage/video/tv` | `/data/media/tv` |
| Radarr | `RootFolders`, `Movies`, `ImportLists` | `/mnt/storage/video/movie` | `/data/media/movies` |
| Lidarr | `RootFolders`, `Artists`, `ImportLists` | `/music` | `/data/media/music` |

The rewrite is prefix-anchored — a path changes only when it equals the old prefix or
begins with it followed by `/` — rather than a substring `REPLACE`. On the current data
both forms produce identical results, so this is not correcting an existing hazard; it is
chosen so the operation stays correct if a future path repeats the prefix substring.

**`sqlite3` is not installed on this host.** The implementation plan uses Python's
built-in `sqlite3` module instead, which needs no packages. The helper was tested against
copies of the live databases during planning: 140/140 Sonarr series and 288/288 Lidarr
artists rewritten, zero residual, zero double-prefixing.

Run a `SELECT Path FROM ... LIMIT 5` before and after each statement and confirm the
rewrite is correct.

### Pre-flight check (completed 2026-08-01)

Every tracked item sits under its root folder, so the `REPLACE` statements are complete
and cannot miss records or match unintended ones:

```
Sonarr:  140 series  — 0 with paths outside /mnt/storage/video/tv/
Radarr:  906 movies  — 0 with paths outside /mnt/storage/video/movie/
Lidarr:  288 artists — 0 with paths outside /music/
```

This resolves the concern about Lidarr's short `/music` prefix. Re-run this check
immediately before the migration if the libraries have changed since.

## Adjacent fixes in scope

### Category subfolders

New downloads route by category. Existing torrents are unaffected.

qBittorrent `categories.json`:

```json
{
  "lidarr":    { "save_path": "/data/torrents/music" },
  "radarr":    { "save_path": "/data/torrents/movies" },
  "tv-sonarr": { "save_path": "/data/torrents/tv" },
  "prowlarr":  { "save_path": "/data/torrents/prowlarr" }
}
```

**Risk:** category save paths only apply when Auto Torrent Management Mode is active.
Setting `Session\AutoTMMByDefault=true` affects newly added torrents only, which is what
we want. `Session\CategoryChangedTMMEnabled` and `Session\SavePathChangedTMMEnabled` must
stay **false** — enabling either would relocate the 111 existing torrents and defeat the
legacy-path preservation above. Verify these three keys explicitly after the edit.

The `readarr` category is dropped (books are out of scope).

NZBGet:

```
AppendCategoryDir=yes
DestDir=/data/usenet/complete
InterDir=/data/usenet/incomplete
Category1.Name=Movies    Category1.DestDir=/data/usenet/complete/movies
Category2.Name=TV        Category2.DestDir=/data/usenet/complete/tv
Category3.Name=Music     Category3.DestDir=/data/usenet/complete/music
```

`NzbDir`, `QueueDir`, `TempDir`, `ScriptDir` and `LogFile` stay under `/data/nzbget/` so
the existing queue survives the move.

**Risk:** changing `InterDir` invalidates in-flight usenet downloads. Pause the queue and
let it drain before the cutover, or accept that in-progress items restart.

### Download client hostnames

Sonarr and Lidarr currently reach the download clients over the public internet, hairpinning
back through nginx-proxy-manager to containers on the same host:

| App | Client | Current host | Problem |
|---|---|---|---|
| Sonarr | NZBGet | `nzbget.merle.io:443` | public round-trip |
| Sonarr | qBittorrent | `transmission.merle.io:443` | public round-trip, legacy name |
| Lidarr | NZBGet | `nzbget.merle.io:443` | public round-trip |
| Lidarr | qBittorrent | `transmission.merle.io:443` | public round-trip, legacy name |
| Radarr | NZBGet | `192.168.20.14:6789` | already correct |
| Radarr | qBittorrent | `transmission.merle.io:443` | public round-trip, legacy name |

**Primary approach — host IP.** Use `192.168.20.14:9091` for qBittorrent and
`192.168.20.14:6789` for NZBGet, both plain HTTP. This is already proven in this stack:
Radarr reaches NZBGet this way today.

**Optional improvement — compose service name.** qBittorrent and NZBGet run in the VPN
container's network namespace, so they are addressable as `vpn:8080` and `vpn:6789` from
other services on `docker-everything-on-it_default` (172.19.0.0/16). This requires adding
the bridge subnet to the VPN container's allowed networks, since the WireGuard killswitch
would otherwise drop the return traffic:

```yaml
- LOCAL_NETWORK=192.168.20.0/24,172.19.0.0/16
```

Try this second, after the host-IP change is verified working. Fall back if the killswitch
interferes.

The disabled `Transmission` and `Transmission-OpenVPN` client entries in Sonarr and Radarr
are dead config and get removed.

### nzbget.log

The log is 5.6 GB. `RotateLog=3` is set but is not firing. Truncate in place (do not
delete — NZBGet holds the file handle) and confirm rotation afterward:

```bash
truncate -s 0 /mnt/storage/downloads/nzbget/nzbget.log
```

Investigate why rotation stalled; if unresolved, cap it with a logrotate entry.

## Privileges

**This migration runs entirely unprivileged as `c0re` (uid 1000). No sudo required.**

Verified 2026-08-01:

| Path | Owner | Writable as c0re |
|---|---|---|
| `/mnt/storage` | `nobody:nogroup` `drwxrwsr-x` | yes — c0re is in `nogroup` |
| `/mnt/storage/video` (+ `movie`, `tv`) | `c0re:users` | yes — owner |
| `/mnt/storage/audio` | `c0re:users` | yes — owner |
| `/mnt/storage/downloads` (+ `complete`, `nzbget`) | `c0re:users` | yes — owner |
| `nzbget.log` | `c0re:users` | yes — owner |
| Docker socket | `docker` group | yes — c0re is in `docker` |

The six renames, tree creation, log truncate, SQLite edits, config edits and all
`docker compose` commands therefore need no elevation. Running an 8 TB restructure as
root would add risk without adding capability — a mistyped `mv` or `rm` has a far larger
blast radius. Keep it unprivileged.

The only root-owned path in the wider plan is `config/overseer` (root:root), which belongs
to the Seerr branch and is handled through the Docker socket rather than sudo, per the
official migration guide:

```bash
docker run --rm -v ${CONFIG_DIRECTORY}/overseer/config:/data alpine chown -R 1000:1000 /data
```

### Note on the sudoers state

Passwordless sudo was attempted but is **not currently active**. `sudo -l` reports:

```
(ALL) NOPASSWD: ALL      <- added to /etc/sudoers
(ALL : ALL) ALL          <- stock %sudo group rule
```

Sudoers is last-match-wins, and the stock `%sudo` rule appears after the NOPASSWD line, so
the password requirement is reinstated. The fix is a drop-in under `/etc/sudoers.d/`, which
is included at the end of `/etc/sudoers` and therefore always wins:

```bash
echo 'c0re ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/010-c0re-nopasswd
sudo chmod 0440 /etc/sudoers.d/010-c0re-nopasswd
sudo visudo -c
```

Irrelevant to this branch either way — recorded so the state is not re-investigated later.

## Execution order

Containers stopped for the whole window. Expect roughly 15–30 minutes, dominated by
verification rather than data movement. Downtime window confirmed acceptable.

1. Pause the NZBGet queue; let in-flight downloads drain.
2. `docker compose down` (this stack only — nginx-proxy-manager and owrx are separate).
3. Back up the three *arr databases.
4. Create the target tree under `/mnt/storage/data/`.
5. Rename into place — all renames, all instant:
   - `downloads/complete`  -> `data/complete`
   - `downloads/incomplete` -> `data/incomplete`
   - `downloads/nzbget`     -> `data/nzbget`
   - `video/movie`          -> `data/media/movies`
   - `video/tv`             -> `data/media/tv`
   - `audio`                -> `data/media/music`
   - `video/Bluey Minisodes` -> `data/torrents/tv/Bluey Minisodes.manual`
     (staged for manual import — see below, **not** merged into `media/tv/`)
6. Apply the SQL re-pointing.
7. Edit `qBittorrent.conf`, `categories.json`, `nzbget.conf`.
8. Update `docker-compose.yml` and `docker-compose.plex.yml`.
9. `docker compose up -d`.
10. Verify (below).
11. Update the download client hostnames through each *arr's UI.

## Verification

Not complete until all of these pass:

- [ ] `docker ps` — all containers up, VPN healthy
- [ ] Sonarr, Radarr, Lidarr: **System → Status** shows no path or root-folder errors
- [ ] Root folders report correct free space (~3.6 TB), not 0 or missing
- [ ] Series/movie/artist counts match pre-migration figures
- [ ] qBittorrent: **zero** errored torrents; count matches pre-migration
- [ ] NZBGet queue intact, history preserved
- [ ] Plex: libraries intact, no items marked unavailable, watch history preserved
- [ ] **Hardlink proof** — the point of the exercise:
      ```bash
      docker exec sonarr sh -c 'touch /data/torrents/tv/.hltest && \
        ln /data/torrents/tv/.hltest /data/media/tv/.hltest && \
        echo HARDLINK OK; rm -f /data/torrents/tv/.hltest /data/media/tv/.hltest'
      ```
- [ ] Force an import of one test download; confirm the *arr log reports a hardlink or
      instant move rather than a copy
- [ ] Tautulli still reporting (it uses the Plex API, so should be unaffected)

## Rollback

Every step is reversible. Renames reverse with renames; databases restore from the `.bak`
copies; compose files revert with git. Rollback is: `docker compose down`, reverse the six
renames, restore the three databases, `git checkout` the compose files, `docker compose up -d`.

Keep the database backups until the stack has run clean for a week.

## Bluey Minisodes — staged manual import

**Decision: goes into the TV library, via Sonarr Manual Import rather than a direct move.**

Sonarr already tracks `Bluey Minisodes` at `/mnt/storage/video/tv/Bluey Minisodes`
(27 of 31 episodes, 0.71 GB). The loose copy at `/mnt/storage/video/Bluey Minisodes/`
(1.1 GB, Season 1 only) is a **second copy using different episode numbering**:

| Episode title | Loose copy | Tracked copy |
|---|---|---|
| Butlers | S01E17 — 123 MB WEBDL | S01E15 — 51 MB HDTV |
| Goldilocks | S01E19 — 97 MB WEBDL | S01E17 — 29 MB HDTV |
| Three Pigs | S01E06 — 93 MB WEBDL | — |
| Tattoo Shop | — | S01E06 — 46 MB WEBDL |

The same episodes carry different `S01Exx` numbers in each copy, and the loose files are
the higher-quality versions (WEBDL vs HDTV, 2–3× the size). The tracked copy is the only
one with Season 2.

Merging the two directories with `mv` would collide two Season 1 folders whose numbering
disagrees, producing mis-mapped episodes and silent duplicates. Instead:

1. During step 5, move the loose copy to `data/torrents/tv/Bluey Minisodes.manual/`
   rather than into `media/tv/`.
2. After the migration is verified, use **Sonarr → Wanted → Manual Import** against that
   path. Sonarr re-parses each file and maps it to the correct TVDB episode, offering the
   WEBDL files as upgrades over the HDTV ones where they match.
3. Delete the staging directory once the import is confirmed.

This is decoupled from the migration and can happen any time afterward. Nothing is
destroyed if it is deferred or abandoned.

## Open items

- NZBGet's queue and scripts live in the data tree rather than `/config`. Left as-is to
  avoid queue loss; worth relocating in a later pass.

## Out of scope

Handled in separate branches, in this order:

1. **Repo hygiene** — `.gitignore` merge conflict markers, untrack `.env` and add
   `.env.example`, delete `docker-compose.yml~`, drop the obsolete `version:` key, merge
   `docker-compose.plex.yml` in, bring nginx-proxy-manager under version control.
2. **Overseerr → Seerr** — `ghcr.io/seerr-team/seerr:latest`, `init: true`, and
   `chown -R 1000:1000` on the config directory, which is currently root-owned.
3. **Small fixes** — restart policies on `vpn` and `qbittorrent`, rename `USER`/`PASS` to
   `PIA_USER`/`PIA_PASS` (shell environment currently overrides the `.env` values),
   Tautulli's broken `/logs` mount (literal backslash in the YAML path created a bogus
   directory), Maintainerr image path `jorenn92` -> `maintainerr`, FlareSolverr -> Byparr.
4. **Additions** — Recyclarr, Unpackerr, a queue cleaner (Cleanuparr or Decluttarr).

This branch depends on none of them and none of them depend on it.
