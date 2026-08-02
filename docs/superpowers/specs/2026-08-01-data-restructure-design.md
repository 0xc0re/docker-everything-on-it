# /data Restructure — Design

**Date:** 2026-08-01
**Branch:** `restructure/data-layout`
**Status:** Design approved, not yet implemented

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

```sql
-- sonarr.db
UPDATE RootFolders SET Path = '/data/media/tv'    WHERE Path = '/mnt/storage/video/tv';
UPDATE Series      SET Path = REPLACE(Path, '/mnt/storage/video/tv', '/data/media/tv');
UPDATE ImportLists SET RootFolderPath = REPLACE(RootFolderPath, '/mnt/storage/video/tv', '/data/media/tv');

-- radarr.db
UPDATE RootFolders SET Path = '/data/media/movies' WHERE Path = '/mnt/storage/video/movie';
UPDATE Movies      SET Path = REPLACE(Path, '/mnt/storage/video/movie', '/data/media/movies');
UPDATE ImportLists SET RootFolderPath = REPLACE(RootFolderPath, '/mnt/storage/video/movie', '/data/media/movies');

-- lidarr.db
UPDATE RootFolders SET Path = '/data/media/music' WHERE Path = '/music';
UPDATE Artists     SET Path = REPLACE(Path, '/music', '/data/media/music');
UPDATE ImportLists SET RootFolderPath = REPLACE(RootFolderPath, '/music', '/data/media/music');
```

Run a `SELECT Path FROM ... LIMIT 5` before and after each statement and confirm the
rewrite is correct. Lidarr's `/music` prefix is short and generic — verify no unintended
matches before committing the transaction.

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

## Execution order

Containers stopped for the whole window. Expect roughly 15–30 minutes, dominated by
verification rather than data movement.

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

## Open items

- `/mnt/storage/video/Bluey Minisodes/` (1.1 GB) sits outside the TV root as a loose show
  with a `Season 1` folder. Decide during step 5 whether it moves into `data/media/tv/` or
  stays out of the library.
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
