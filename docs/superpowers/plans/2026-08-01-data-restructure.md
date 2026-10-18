# /data Restructure Implementation Plan

> **Status 2026-10-18: EXECUTED.** Run as part of the post-rebuild restructure (see
> `/mnt/storage/_os-rebuild-2026-10/PROGRESS.md`, Session 4). Deltas from this plan:
> counts were 143/957/289 series/movies/artists and 12 torrents; Plex + Tautulli moved to
> `/mnt/flash/plex` (own project) instead of `docker-compose.plex.yml`; download clients use
> `vpn:9091` / `vpn:6789`; `/mnt/storage` top level is not writable by c0re on 26.04 (not in
> `nogroup`), so `data/` was created and `audio` moved with sudo; two extra path columns were
> re-pointed that this plan missed: Radarr `Collections.RootFolderPath` (231 rows) and Lidarr
> `TrackFiles.Path` (35,210 rows). Bluey: 5 title-consistent files imported, 14 left staged.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate downloads and media under a single `/data` bind mount so hardlinks and atomic moves work, and route new downloads into per-category folders.

**Architecture:** All media and downloads already live on one ext4 array (`/dev/md0`), so every relocation is a rename — instant, no copying, no extra space. Legacy `complete/` and `incomplete/` folders keep their exact container paths so none of the 24 existing torrents break. Plex keeps its container paths via alias mounts, so no rescan. The *arr databases are re-pointed with SQL while stopped, because the UI would try to move files that are already in place.

**Tech Stack:** Docker Compose, SQLite, ext4, qBittorrent WebAPI, NZBGet, Sonarr/Radarr/Lidarr v3/v4 APIs

**Design doc:** `docs/superpowers/specs/2026-08-01-data-restructure-design.md`

**Privileges:** Runs entirely as `c0re` (uid 1000). No sudo. Passwordless sudo is available but deliberately unused — root widens the blast radius of a mistyped `mv` without adding capability.

---

## Conventions used throughout

Every task follows: **verify precondition → act → verify postcondition**. Do not proceed
past a failed verification. Each task lists its own rollback.

Shell variables used in every task (set these once per shell session):

```bash
cd /mnt/flash/docker-everything-on-it
export STORAGE=/mnt/storage
export CONFIG=/mnt/flash/docker-everything-on-it/config
export STAMP=$(date +%Y%m%d-%H%M%S)
export WORK=/mnt/flash/docker-everything-on-it/.migration-$STAMP
mkdir -p "$WORK"
echo "workdir: $WORK"
```

API keys (already confirmed present in the configs):

```bash
export SONARR_KEY=8b19e7963ae64e93849869c527bb5855
export RADARR_KEY=ed916c6fabbd4324bc258c4562ac8282
export LIDARR_KEY=1a3d21e39a4c401aa42203034dc44245
```

---

## Task 1: Capture the pre-migration baseline

Everything in Task 10 compares against these numbers. Without them there is no way to
prove nothing was lost.

**Files:**
- Create: `$WORK/baseline.txt`

- [ ] **Step 1: Record library counts and root folders**

```bash
{
  echo "=== BASELINE $(date -Is) ==="
  echo "--- sonarr ---"
  curl -s -H "X-Api-Key: $SONARR_KEY" http://localhost:8989/api/v3/series \
    | python3 -c 'import json,sys; s=json.load(sys.stdin); print("series:",len(s)); print("outside_root:",len([x for x in s if not x["path"].startswith("/mnt/storage/video/tv/")]))'
  curl -s -H "X-Api-Key: $SONARR_KEY" http://localhost:8989/api/v3/rootfolder \
    | python3 -c 'import json,sys; [print("root:",r["path"],r.get("accessible")) for r in json.load(sys.stdin)]'
  echo "--- radarr ---"
  curl -s -H "X-Api-Key: $RADARR_KEY" http://localhost:7878/api/v3/movie \
    | python3 -c 'import json,sys; m=json.load(sys.stdin); print("movies:",len(m)); print("outside_root:",len([x for x in m if not x["path"].startswith("/mnt/storage/video/movie/")]))'
  curl -s -H "X-Api-Key: $RADARR_KEY" http://localhost:7878/api/v3/rootfolder \
    | python3 -c 'import json,sys; [print("root:",r["path"],r.get("accessible")) for r in json.load(sys.stdin)]'
  echo "--- lidarr ---"
  curl -s -H "X-Api-Key: $LIDARR_KEY" http://localhost:8686/api/v1/artist \
    | python3 -c 'import json,sys; a=json.load(sys.stdin); print("artists:",len(a)); print("outside_root:",len([x for x in a if not x["path"].startswith("/music/")]))'
  curl -s -H "X-Api-Key: $LIDARR_KEY" http://localhost:8686/api/v1/rootfolder \
    | python3 -c 'import json,sys; [print("root:",r["path"],r.get("accessible")) for r in json.load(sys.stdin)]'
  echo "--- qbittorrent ---"
  echo "fastresume: $(ls "$CONFIG"/qbittorrent/qBittorrent/BT_backup/*.fastresume 2>/dev/null | wc -l)"
  echo "save_paths:"
  python3 - <<'PY'
import glob, re, collections, os
c = collections.Counter()
for p in glob.glob(os.environ['CONFIG'] + '/qbittorrent/qBittorrent/BT_backup/*.fastresume'):
    d = open(p, 'rb').read()
    for m in re.finditer(rb'save_path(\d+):', d):
        n = int(m.group(1))
        c[d[m.end():m.end()+n].decode('utf8', 'replace')] += 1
for k, v in c.most_common():
    print(f"  {v:5d}  {k}")
PY
  echo "--- disk ---"
  echo "downloads/complete items: $(ls "$STORAGE"/downloads/complete | wc -l)"
  echo "video/movie items:        $(ls "$STORAGE"/video/movie | wc -l)"
  echo "video/tv items:           $(ls "$STORAGE"/video/tv | wc -l)"
  echo "audio items:              $(ls "$STORAGE"/audio | wc -l)"
  du -sh "$STORAGE"/video/movie "$STORAGE"/video/tv "$STORAGE"/audio 2>/dev/null
  df -h "$STORAGE" | tail -1
} | tee "$WORK/baseline.txt"
```

- [ ] **Step 2: Verify the baseline matches expectations**

Expected, from the 2026-08-01 survey:

```
series: 140          outside_root: 0
movies: 906          outside_root: 0
artists: 288         outside_root: 0
fastresume: 24       all save_path = /data/complete
downloads/complete items: 111
video/movie items:        1638
video/tv items:           168
audio items:              443
```

The on-disk item counts intentionally exceed the library counts — `video/movie` holds
1638 entries against 906 tracked movies. This is pre-existing and out of scope; the
migration preserves whatever is there. It matters only that the count is **identical**
before and after.

If `outside_root` is anything other than `0` for any app, **stop**. The SQL in Task 6
assumes every path sits under its root folder. Investigate the outliers first.

If the counts differ from the above, that is fine — the library has simply changed. Use
the values you just captured as the comparison target in Task 10.

**Rollback:** None needed — read-only.

---

## Task 2: Back up databases and configs

**Files:**
- Create: `$WORK/config-backup/`

- [ ] **Step 1: Copy the three *arr databases and the client configs**

```bash
mkdir -p "$WORK/config-backup"
cp "$CONFIG/sonarr/sonarr.db"          "$WORK/config-backup/"
cp "$CONFIG/radarr/radarr.db"          "$WORK/config-backup/"
cp "$CONFIG/lidarr/config/lidarr.db"   "$WORK/config-backup/"
cp "$CONFIG/qbittorrent/qBittorrent/qBittorrent.conf" "$WORK/config-backup/"
cp "$CONFIG/qbittorrent/qBittorrent/categories.json"  "$WORK/config-backup/"
cp "$CONFIG/nzbget/nzbget.conf"        "$WORK/config-backup/"
cp docker-compose.yml docker-compose.plex.yml "$WORK/config-backup/"
```

- [ ] **Step 2: Verify every backup landed and is non-empty**

```bash
ls -la "$WORK/config-backup/"
find "$WORK/config-backup" -size 0 -print | grep . && echo "EMPTY FILE FOUND — STOP" || echo "all backups non-empty"
```

Expected: 8 files, none zero-length, `all backups non-empty`.

Note these are copies of **live** SQLite databases. They are taken before shutdown only as
a safety net; the authoritative backup is Task 3 Step 3, taken after a clean stop.

**Rollback:** None needed.

---

## Task 3: Drain the queue and stop the stack

**Files:** None modified.

- [ ] **Step 1: Pause the NZBGet queue and let in-flight downloads finish**

Open NZBGet at `http://192.168.20.14:6789` and pause the queue. Changing `InterDir` in
Task 8 invalidates anything still in progress.

Wait until the queue is empty, or accept that in-progress items restart from scratch.

```bash
ls "$STORAGE"/downloads/incomplete | wc -l
```

Expected: `0`, or a number you have decided to abandon.

- [ ] **Step 2: Stop the stack**

Only this compose project. `nginx-proxy-manager` and `owrx-docker` are separate projects
and must keep running.

```bash
docker compose down
docker ps --format '{{.Names}}'
```

Expected: `nginx-proxy-manager_app_1` and `owrx-mbe` still listed. None of `sonarr`,
`radarr`, `lidarr`, `qbittorrent`, `nzbget`, `plex`, `overseerr`, `tautulli`,
`prowlarr`, `flaresolverr`, `maintainerr`, `wireguard-pia`.

Note `plex` is in `docker-compose.plex.yml`, a separate file. If it is still running:

```bash
docker compose -f docker-compose.plex.yml down
```

- [ ] **Step 3: Take the authoritative cold backup**

```bash
mkdir -p "$WORK/config-backup-cold"
cp "$CONFIG/sonarr/sonarr.db"        "$WORK/config-backup-cold/"
cp "$CONFIG/radarr/radarr.db"        "$WORK/config-backup-cold/"
cp "$CONFIG/lidarr/config/lidarr.db" "$WORK/config-backup-cold/"
ls -la "$WORK/config-backup-cold/"
```

Expected: three `.db` files. These are the ones to restore from — they were copied with
no writer attached, so there are no `-wal`/`-shm` consistency concerns.

**Rollback:** `docker compose up -d` restores the previous state exactly. Nothing has
changed on disk yet.

---

## Task 4: Create the target tree

**Files:**
- Create: `/mnt/storage/data/` and subdirectories

- [ ] **Step 1: Verify the target does not already exist**

```bash
test -e "$STORAGE/data" && echo "ALREADY EXISTS — STOP AND INVESTIGATE" || echo "clear to create"
```

Expected: `clear to create`.

- [ ] **Step 2: Create the directory skeleton**

Only the new folders. `complete`, `incomplete`, `nzbget` and the three `media` folders are
created by the renames in Task 5 and must **not** be pre-created — `mv` into an existing
directory nests instead of renaming.

```bash
mkdir -p "$STORAGE"/data/torrents/{movies,tv,music}
mkdir -p "$STORAGE"/data/usenet/incomplete
mkdir -p "$STORAGE"/data/usenet/complete/{movies,tv,music}
mkdir -p "$STORAGE"/data/media
```

- [ ] **Step 3: Verify the skeleton and confirm no stray media dirs**

```bash
find "$STORAGE/data" -type d | sort
test -e "$STORAGE/data/media/tv" && echo "ERROR: media/tv pre-exists, Task 5 will nest" || echo "media/ correctly empty"
```

Expected:

```
/mnt/storage/data
/mnt/storage/data/media
/mnt/storage/data/torrents
/mnt/storage/data/torrents/movies
/mnt/storage/data/torrents/music
/mnt/storage/data/torrents/tv
/mnt/storage/data/usenet
/mnt/storage/data/usenet/complete
/mnt/storage/data/usenet/complete/movies
/mnt/storage/data/usenet/complete/music
/mnt/storage/data/usenet/complete/tv
/mnt/storage/data/usenet/incomplete
media/ correctly empty
```

**Rollback:** `rm -rf "$STORAGE/data"` — it contains only empty directories at this point.

---

## Task 5: Relocate media and downloads

Every one of these is a rename within `/dev/md0`. Each returns instantly regardless of size.

**Files:**
- Move: six directories under `/mnt/storage`

- [ ] **Step 1: Confirm source and destination are the same filesystem**

If this fails, the moves become multi-hour copies and the plan is invalid.

```bash
for p in "$STORAGE/video/tv" "$STORAGE/downloads/complete" "$STORAGE/audio" "$STORAGE/data"; do
  printf '%s  %s\n' "$(stat -c '%d' "$p")" "$p"
done
```

Expected: the same device number (`2304`) on all four lines.

- [ ] **Step 2: Perform the six renames**

`mv -n` refuses to overwrite. Order does not matter.

```bash
set -e
mv -n "$STORAGE/downloads/complete"   "$STORAGE/data/complete"
mv -n "$STORAGE/downloads/incomplete" "$STORAGE/data/incomplete"
mv -n "$STORAGE/downloads/nzbget"     "$STORAGE/data/nzbget"
mv -n "$STORAGE/video/movie"          "$STORAGE/data/media/movies"
mv -n "$STORAGE/video/tv"             "$STORAGE/data/media/tv"
mv -n "$STORAGE/audio"                "$STORAGE/data/media/music"
set +e
echo "renames complete"
```

- [ ] **Step 3: Stage Bluey Minisodes for manual import**

Not merged into `media/tv/` — the loose copy uses different episode numbering than the
tracked copy. See the design doc for the collision table.

```bash
mv -n "$STORAGE/video/Bluey Minisodes" "$STORAGE/data/torrents/tv/Bluey Minisodes.manual"
ls "$STORAGE/data/torrents/tv/Bluey Minisodes.manual/"
```

Expected: `Season 1`.

- [ ] **Step 4: Verify the new tree and that nothing was left behind**

```bash
echo "--- new tree ---"
ls "$STORAGE/data" "$STORAGE/data/media"
echo "--- counts (compare to baseline) ---"
echo "complete items: $(ls "$STORAGE/data/complete" | wc -l)"
echo "movies:  $(ls "$STORAGE/data/media/movies" | wc -l)"
echo "tv:      $(ls "$STORAGE/data/media/tv" | wc -l)"
echo "music:   $(ls "$STORAGE/data/media/music" | wc -l)"
echo "--- old locations should be gone ---"
for p in "$STORAGE/video/movie" "$STORAGE/video/tv" "$STORAGE/audio" \
         "$STORAGE/downloads/complete" "$STORAGE/downloads/incomplete" "$STORAGE/downloads/nzbget"; do
  test -e "$p" && echo "STILL PRESENT: $p" || echo "moved: $p"
done
echo "--- non-media left in downloads/ (expected to remain) ---"
ls "$STORAGE/downloads"
echo "--- video/ should now be empty ---"
ls -A "$STORAGE/video"
```

Expected, matching the Task 1 baseline exactly:

```
complete items: 111
movies:  1638
tv:      168
music:   443
```

All six old locations must report `moved:`. `downloads/` still holds `w5cqu`, `web`,
`backup`, `Tdarr_Node_Config.json` and `.Trash-1000`.

Compare every count against `$WORK/baseline.txt`. A rename either moves a directory whole
or fails — a mismatch means something did not move at all. Stop and investigate before
touching the databases.

Note the Bluey staging move in Step 3 comes out of `$STORAGE/video/`, not `video/tv/`, so
it does not affect the `tv` count. `$STORAGE/video` should now be empty — leave the empty
directory in place until Task 10 confirms the stack is healthy, then remove it:

```bash
rmdir "$STORAGE/video"    # only after Task 10 passes; fails safely if not empty
```

**Rollback:** Reverse each rename.

```bash
mv "$STORAGE/data/complete"      "$STORAGE/downloads/complete"
mv "$STORAGE/data/incomplete"    "$STORAGE/downloads/incomplete"
mv "$STORAGE/data/nzbget"        "$STORAGE/downloads/nzbget"
mv "$STORAGE/data/media/movies"  "$STORAGE/video/movie"
mv "$STORAGE/data/media/tv"      "$STORAGE/video/tv"
mv "$STORAGE/data/media/music"   "$STORAGE/audio"
mv "$STORAGE/data/torrents/tv/Bluey Minisodes.manual" "$STORAGE/video/Bluey Minisodes"
```

---

## Task 6: Re-point the *arr databases

The UI cannot do this — changing a root folder makes Sonarr attempt to *move* files that
are already in place, which fails.

**Files:**
- Modify: `config/sonarr/sonarr.db`
- Modify: `config/radarr/radarr.db`
- Modify: `config/lidarr/config/lidarr.db`

- [ ] **Step 1: Confirm the containers are stopped**

Editing a live SQLite database corrupts it.

```bash
docker ps --format '{{.Names}}' | grep -E '^(sonarr|radarr|lidarr)$' && echo "STILL RUNNING — STOP" || echo "safe to edit"
```

Expected: `safe to edit`.

- [ ] **Step 2: Write the repath helper**

The `sqlite3` CLI is **not installed on this host**. Python's built-in `sqlite3` module is
used instead — no packages to install.

The helper does true prefix replacement: a path is rewritten only when it equals the old
prefix or begins with the old prefix followed by `/`.

This was verified against copies of the real databases during planning — 140/140 Sonarr
series and 288/288 Lidarr artists rewritten, zero residual, zero double-prefixing. On the
current data a naive `REPLACE` would produce identical output (no path contains `/music`
more than once), so the anchored form is not fixing an existing corruption. It is used
because it is correct by construction rather than by coincidence: it stays safe if an
artist or series is later added whose path repeats the prefix substring.

```bash
cat > "$WORK/repath.py" <<'PY'
import sqlite3, sys

db, table, col, old, new, mode = sys.argv[1:7]

def rewrite(p):
    if p == old:
        return new
    if p.startswith(old + '/'):
        return new + p[len(old):]
    return None

con = sqlite3.connect(db)
con.execute("PRAGMA foreign_keys=ON")
rows = con.execute(f"SELECT rowid, {col} FROM {table} WHERE {col} IS NOT NULL").fetchall()
changes = [(rid, p, rewrite(p)) for rid, p in rows]
changes = [(rid, p, n) for rid, p, n in changes if n is not None]

print(f"{table}.{col}: {len(rows)} rows, {len(changes)} to rewrite")
for _, p, n in changes[:3]:
    print(f"   {p}\n-> {n}")
if len(changes) > 3:
    print(f"   ... and {len(changes) - 3} more")

if mode == "apply":
    with con:
        con.executemany(f"UPDATE {table} SET {col}=? WHERE rowid=?",
                        [(n, rid) for rid, _, n in changes])
    print(f"APPLIED {len(changes)} updates")
    left = con.execute(
        f"SELECT COUNT(*) FROM {table} WHERE {col} = ? OR {col} LIKE ?",
        (old, old + '/%')).fetchone()[0]
    print(f"residual rows still on old prefix: {left}")
    if left:
        sys.exit("RESIDUAL ROWS REMAIN — INVESTIGATE")
else:
    print("(dry run, nothing written)")
con.close()
PY
echo "helper written"
```

- [ ] **Step 3: Dry-run all nine rewrites**

Nothing is written. Read every line of the output before continuing.

```bash
run() { python3 "$WORK/repath.py" "$@"; echo; }

echo "########## SONARR ##########"
run "$CONFIG/sonarr/sonarr.db" RootFolders Path           /mnt/storage/video/tv    /data/media/tv     dry
run "$CONFIG/sonarr/sonarr.db" Series      Path           /mnt/storage/video/tv    /data/media/tv     dry
run "$CONFIG/sonarr/sonarr.db" ImportLists RootFolderPath /mnt/storage/video/tv    /data/media/tv     dry

echo "########## RADARR ##########"
run "$CONFIG/radarr/radarr.db" RootFolders Path           /mnt/storage/video/movie /data/media/movies dry
run "$CONFIG/radarr/radarr.db" Movies      Path           /mnt/storage/video/movie /data/media/movies dry
run "$CONFIG/radarr/radarr.db" ImportLists RootFolderPath /mnt/storage/video/movie /data/media/movies dry

echo "########## LIDARR ##########"
run "$CONFIG/lidarr/config/lidarr.db" RootFolders Path           /music /data/media/music dry
run "$CONFIG/lidarr/config/lidarr.db" Artists     Path           /music /data/media/music dry
run "$CONFIG/lidarr/config/lidarr.db" ImportLists RootFolderPath /music /data/media/music dry
```

Expected rewrite counts, matching the Task 1 baseline:

```
sonarr  RootFolders 1 of 1     Series 140 of 140     ImportLists 0 of 0
radarr  RootFolders 1 of 1     Movies 906 of 906     ImportLists 1 of 1
lidarr  RootFolders 1 of 1     Artists 288 of 288    ImportLists 3 of 3
```

If any "to rewrite" count is lower than its row count, some paths sit outside the root
folder. **Stop** and investigate — Task 1 Step 2 should have caught this.

- [ ] **Step 4: Apply all nine rewrites**

Identical commands with `dry` changed to `apply`. The helper exits non-zero if any row is
left on the old prefix, so a failure is loud.

```bash
run() { python3 "$WORK/repath.py" "$@" || { echo "FAILED — STOP"; return 1; }; echo; }

echo "########## SONARR ##########"
run "$CONFIG/sonarr/sonarr.db" RootFolders Path           /mnt/storage/video/tv    /data/media/tv     apply
run "$CONFIG/sonarr/sonarr.db" Series      Path           /mnt/storage/video/tv    /data/media/tv     apply
run "$CONFIG/sonarr/sonarr.db" ImportLists RootFolderPath /mnt/storage/video/tv    /data/media/tv     apply

echo "########## RADARR ##########"
run "$CONFIG/radarr/radarr.db" RootFolders Path           /mnt/storage/video/movie /data/media/movies apply
run "$CONFIG/radarr/radarr.db" Movies      Path           /mnt/storage/video/movie /data/media/movies apply
run "$CONFIG/radarr/radarr.db" ImportLists RootFolderPath /mnt/storage/video/movie /data/media/movies apply

echo "########## LIDARR ##########"
run "$CONFIG/lidarr/config/lidarr.db" RootFolders Path           /music /data/media/music apply
run "$CONFIG/lidarr/config/lidarr.db" Artists     Path           /music /data/media/music apply
run "$CONFIG/lidarr/config/lidarr.db" ImportLists RootFolderPath /music /data/media/music apply
```

Expected: each reports `APPLIED n updates` and `residual rows still on old prefix: 0`.

- [ ] **Step 5: Independently verify the final state**

```bash
python3 - <<'PY'
import sqlite3, os
C = os.environ['CONFIG']
checks = [
    (f"{C}/sonarr/sonarr.db",        "sonarr", "Series",  "/data/media/tv"),
    (f"{C}/radarr/radarr.db",        "radarr", "Movies",  "/data/media/movies"),
    (f"{C}/lidarr/config/lidarr.db", "lidarr", "Artists", "/data/media/music"),
]
ok = True
for db, name, table, prefix in checks:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    root = con.execute("SELECT Path FROM RootFolders").fetchall()
    total = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    good = con.execute(f"SELECT COUNT(*) FROM {table} WHERE Path LIKE ?", (prefix + '/%',)).fetchone()[0]
    stale = con.execute(
        f"SELECT COUNT(*) FROM {table} WHERE Path LIKE '/mnt/storage/%' OR Path LIKE '/music/%'"
    ).fetchone()[0]
    status = "OK" if (good == total and stale == 0) else "FAIL"
    if status == "FAIL":
        ok = False
    print(f"{name:8s} root={[r[0] for r in root]}  {table}: {good}/{total} on new prefix, {stale} stale  {status}")
    con.close()
print("\nALL GOOD" if ok else "\nPROBLEMS FOUND — DO NOT START THE STACK")
PY
```

Expected:

```
sonarr   root=['/data/media/tv']      Series: 140/140 on new prefix, 0 stale  OK
radarr   root=['/data/media/movies']  Movies: 906/906 on new prefix, 0 stale  OK
lidarr   root=['/data/media/music']   Artists: 288/288 on new prefix, 0 stale  OK

ALL GOOD
```

**Rollback:** Restore from the cold backup.

```bash
cp "$WORK/config-backup-cold/sonarr.db" "$CONFIG/sonarr/sonarr.db"
cp "$WORK/config-backup-cold/radarr.db" "$CONFIG/radarr/radarr.db"
cp "$WORK/config-backup-cold/lidarr.db" "$CONFIG/lidarr/config/lidarr.db"
```

---

## Task 7: Reconfigure qBittorrent

**Files:**
- Modify: `config/qbittorrent/qBittorrent/categories.json`
- Modify: `config/qbittorrent/qBittorrent/qBittorrent.conf:65-66`

- [ ] **Step 1: Write the category save paths**

Existing torrents are unaffected — they carry their own absolute `save_path`. This only
governs newly added torrents. The `readarr` category is dropped (books are out of scope).

```bash
cat > "$CONFIG/qbittorrent/qBittorrent/categories.json" <<'JSON'
{
    "lidarr": {
        "save_path": "/data/torrents/music"
    },
    "prowlarr": {
        "save_path": "/data/torrents/prowlarr"
    },
    "radarr": {
        "save_path": "/data/torrents/movies"
    },
    "tv-sonarr": {
        "save_path": "/data/torrents/tv"
    }
}
JSON
python3 -m json.tool "$CONFIG/qbittorrent/qBittorrent/categories.json"
```

Expected: the JSON prints back formatted, confirming it parses.

- [ ] **Step 2: Create the prowlarr category directory**

The other three were created in Task 4.

```bash
mkdir -p "$STORAGE/data/torrents/prowlarr"
ls "$STORAGE/data/torrents"
```

Expected: `movies  music  prowlarr  tv`.

- [ ] **Step 3: Update the two stale legacy path keys**

Lines 65-66 are leftovers from a pre-4.x qBittorrent. The live settings are
`Session\DefaultSavePath` (line 23) and `Session\TempPath` (line 39), which already read
`/data/complete` and `/data/incomplete` and are **correct as-is** — do not change them.
The legacy keys are updated only so nothing references the `/downloads` mount being
removed in Task 9.

```bash
sed -i \
  -e 's|^Downloads\\SavePath=/downloads/$|Downloads\\SavePath=/data/complete/|' \
  -e 's|^Downloads\\TempPath=/downloads/incomplete/$|Downloads\\TempPath=/data/incomplete/|' \
  "$CONFIG/qbittorrent/qBittorrent/qBittorrent.conf"

grep -nE '^(Downloads\\|Session\\DefaultSavePath|Session\\TempPath)' \
  "$CONFIG/qbittorrent/qBittorrent/qBittorrent.conf"
```

Expected:

```
23:Session\DefaultSavePath=/data/complete
39:Session\TempPath=/data/incomplete
65:Downloads\SavePath=/data/complete/
66:Downloads\TempPath=/data/incomplete/
```

- [ ] **Step 4: Confirm no auto-relocation keys are present**

Auto Torrent Management is enabled through the UI in Task 11, deliberately **after** the
stack is verified. The dangerous settings are the relocation triggers — if any of these
keys exists and is enabled, qBittorrent will move the 24 existing torrents out of
`/data/complete` and undo the whole preservation strategy.

```bash
grep -nE 'AutoTMM|TMMTriggers|CategoryChanged|SavePathChanged' \
  "$CONFIG/qbittorrent/qBittorrent/qBittorrent.conf" || echo "no TMM keys present — defaults apply (manual mode, no relocation)"
```

Expected: `no TMM keys present`. If any appear, record them and check them in the UI in
Task 11 before enabling anything.

**Rollback:**

```bash
cp "$WORK/config-backup/categories.json"  "$CONFIG/qbittorrent/qBittorrent/categories.json"
cp "$WORK/config-backup/qBittorrent.conf" "$CONFIG/qbittorrent/qBittorrent/qBittorrent.conf"
```

---

## Task 8: Reconfigure NZBGet

**Files:**
- Modify: `config/nzbget/nzbget.conf` (lines 17, 34, 486, 711, 1102, 1677, 1681)

- [ ] **Step 1: Point the output directories at the usenet tree**

`MainDir=/data` (line 11) stays as-is, which keeps `NzbDir`, `QueueDir`, `TempDir`,
`ScriptDir` and `LogFile` resolving under `/data/nzbget/` — the directory moved in Task 5.
The existing queue therefore survives.

```bash
sed -i \
  -e 's|^DestDir=\${MainDir}/complete$|DestDir=${MainDir}/usenet/complete|' \
  -e 's|^InterDir=\${MainDir}/incomplete$|InterDir=${MainDir}/usenet/incomplete|' \
  -e 's|^AppendCategoryDir=no$|AppendCategoryDir=yes|' \
  "$CONFIG/nzbget/nzbget.conf"

grep -nE '^(MainDir|DestDir|InterDir|NzbDir|QueueDir|TempDir|ScriptDir|LogFile|AppendCategoryDir)=' \
  "$CONFIG/nzbget/nzbget.conf"
```

Expected:

```
11:MainDir=/data
17:DestDir=${MainDir}/usenet/complete
34:InterDir=${MainDir}/usenet/incomplete
46:NzbDir=${MainDir}/nzbget/nzb
52:QueueDir=${MainDir}/nzbget/queue
55:TempDir=${MainDir}/nzbget/tmp
71:ScriptDir=${MainDir}/nzbget/scripts
88:LogFile=${MainDir}/nzbget/nzbget.log
711:AppendCategoryDir=yes
```

- [ ] **Step 2: Set explicit per-category destinations**

Explicit `DestDir` values are used rather than relying on `AppendCategoryDir`, which would
append the category name verbatim and produce `Movies/`, `TV/`, `Music/` with capitals
that do not match the torrent tree.

```bash
sed -i \
  -e '486s|^Category1.DestDir=$|Category1.DestDir=${MainDir}/usenet/complete/movies|' \
  -e '1677s|^Category2.DestDir=$|Category2.DestDir=${MainDir}/usenet/complete/tv|' \
  -e '1681s|^Category3.DestDir=$|Category3.DestDir=${MainDir}/usenet/complete/music|' \
  "$CONFIG/nzbget/nzbget.conf"

grep -nE '^Category[1-6]\.(Name|DestDir)=' "$CONFIG/nzbget/nzbget.conf"
```

Expected: `Category1` (Movies) → `.../movies`, `Category2` (TV) → `.../tv`,
`Category3` (Music) → `.../music`. Categories 4-6 (Software, Prowlarr, Readarr) keep
empty `DestDir` and will fall back to `AppendCategoryDir`.

Line numbers are asserted by the `sed` address prefix. If a line has shifted, `sed` makes
no change and the `grep` will show it — do not proceed on a silent no-op.

- [ ] **Step 3: Fix the log bloat at its source**

`nzbget.log` reached 5.6 GB because `DetailTarget=log` (line 1102) writes one line per
downloaded article — 491 lines for a single file. `RotateLog=3` cannot keep up. Sending
DETAIL to screen only keeps it in `docker logs` without writing to disk.

```bash
sed -i '1102s|^DetailTarget=log$|DetailTarget=screen|' "$CONFIG/nzbget/nzbget.conf"
grep -nE '^(DetailTarget|InfoTarget|WarningTarget|ErrorTarget|DebugTarget|RotateLog|WriteLog)=' \
  "$CONFIG/nzbget/nzbget.conf"
```

Expected: `1102:DetailTarget=screen`, everything else unchanged.

- [ ] **Step 4: Truncate the existing log**

Truncate rather than delete — NZBGet is stopped now, but truncation is the correct habit
while a writer holds the handle.

```bash
ls -la "$STORAGE/data/nzbget/nzbget.log"
truncate -s 0 "$STORAGE/data/nzbget/nzbget.log"
ls -la "$STORAGE/data/nzbget/nzbget.log"
df -h "$STORAGE" | tail -1
```

Expected: size goes from ~5.6 GB to `0`, and available space on `/mnt/storage` increases
by roughly 5.6 GB.

**Rollback:**

```bash
cp "$WORK/config-backup/nzbget.conf" "$CONFIG/nzbget/nzbget.conf"
```

The truncated log is not recoverable, which is intended.

---

## Task 9: Update the compose files

**Files:**
- Modify: `docker-compose.yml`
- Modify: `docker-compose.plex.yml`

- [ ] **Step 1: Give qBittorrent a single data mount**

Removes the duplicate `/downloads` mount, which pointed at the same host directory as
`/data`.

Replace the `volumes:` block of the `qbittorrent` service (currently lines 42-45) with:

```yaml
        volumes:
            - ${CONFIG_DIRECTORY}/qbittorrent:/config
            - ${STORAGE_DIRECTORY}/data:/data
```

- [ ] **Step 2: Give Sonarr a single data mount**

Replace the `volumes:` block of the `sonarr` service (currently lines 53-57) with:

```yaml
        volumes:
            - ${CONFIG_DIRECTORY}/sonarr:/config
            - ${STORAGE_DIRECTORY}/data:/data
            - /etc/localtime:/etc/localtime:ro
```

- [ ] **Step 3: Give Radarr a single data mount**

Replace the `volumes:` block of the `radarr` service (currently lines 71-75) with:

```yaml
        volumes:
            - ${CONFIG_DIRECTORY}/radarr:/config
            - ${STORAGE_DIRECTORY}/data:/data
            - /etc/localtime:/etc/localtime:ro
```

- [ ] **Step 4: Give Lidarr a single data mount**

Replace the `volumes:` block of the `lidarr` service (currently lines 91-94) with:

```yaml
        volumes:
            - ${CONFIG_DIRECTORY}/lidarr/config:/config
            - ${STORAGE_DIRECTORY}/data:/data
```

- [ ] **Step 5: Give NZBGet a single data mount**

Replace the `volumes:` block of the `nzbget` service (currently lines 108-110) with:

```yaml
        volumes:
            - ${CONFIG_DIRECTORY}/nzbget:/config
            - ${STORAGE_DIRECTORY}/data:/data
```

- [ ] **Step 6: Repoint Plex with alias mounts**

The container-side paths are deliberately unchanged so Plex's library paths, watch history
and metadata are untouched. Only the host side moves.

In `docker-compose.plex.yml`, replace the media volume lines (currently lines 23-25) with:

```yaml
              - ${STORAGE_DIRECTORY}/data/media/movies:/mnt/storage/video/movie:rw
              - ${STORAGE_DIRECTORY}/data/media/tv:/mnt/storage/video/tv:rw
              - ${STORAGE_DIRECTORY}/data/media/music:/mnt/storage/audio:rw
```

Leave the `photos`, `/config` and `/transcode` mounts exactly as they are.

- [ ] **Step 7: Validate both compose files parse and resolve**

```bash
docker compose config >/dev/null && echo "docker-compose.yml OK"
docker compose -f docker-compose.plex.yml config >/dev/null && echo "plex OK"
```

Expected: both `OK`, no warnings about undefined variables.

- [ ] **Step 8: Confirm every media mount resolves to a real path**

```bash
docker compose config | grep -A1 'source:' | grep -oP '(?<=source: ).*' | sort -u | while read -r p; do
  case "$p" in /*) test -e "$p" && echo "ok      $p" || echo "MISSING $p" ;; esac
done
docker compose -f docker-compose.plex.yml config | grep -oP '(?<=source: ).*' | while read -r p; do
  case "$p" in /*) test -e "$p" && echo "ok      $p" || echo "MISSING $p" ;; esac
done
```

Expected: every line `ok`. Any `MISSING` means a path was mistyped — fix before starting.

- [ ] **Step 9: Commit the compose changes**

```bash
git add docker-compose.yml docker-compose.plex.yml
git commit -m "Consolidate *arr and download client mounts under single /data

Replaces per-app media mounts with one ${STORAGE_DIRECTORY}/data:/data bind
so hardlinks and atomic moves work. Plex keeps its container paths via
alias mounts, avoiding a library rescan. Drops the duplicate /downloads
mount on qbittorrent."
```

**Rollback:**

```bash
git checkout docker-compose.yml docker-compose.plex.yml
```

---

## Task 10: Start the stack and verify

**Files:** None modified.

- [ ] **Step 1: Start both compose projects**

```bash
docker compose up -d
docker compose -f docker-compose.plex.yml up -d
sleep 30
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Expected: all services `Up`. `wireguard-pia` should reach `(healthy)` within a minute or
two — recheck if it is still starting.

- [ ] **Step 2: Confirm the mounts landed as intended**

```bash
for c in sonarr radarr lidarr qbittorrent nzbget; do
  echo "--- $c ---"
  docker inspect "$c" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
done
```

Expected: each shows exactly one `/mnt/storage/data -> /data` plus its `/config`
(and `/etc/localtime` for sonarr/radarr). No `/mnt/storage/video/*`, no `/music`,
no `/downloads`.

- [ ] **Step 3: Verify the libraries survived**

```bash
curl -s -H "X-Api-Key: $SONARR_KEY" http://localhost:8989/api/v3/series \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); print("series:",len(s)); print("bad_paths:",len([x for x in s if not x["path"].startswith("/data/media/tv/")]))'
curl -s -H "X-Api-Key: $RADARR_KEY" http://localhost:7878/api/v3/movie \
  | python3 -c 'import json,sys; m=json.load(sys.stdin); print("movies:",len(m)); print("bad_paths:",len([x for x in m if not x["path"].startswith("/data/media/movies/")]))'
curl -s -H "X-Api-Key: $LIDARR_KEY" http://localhost:8686/api/v1/artist \
  | python3 -c 'import json,sys; a=json.load(sys.stdin); print("artists:",len(a)); print("bad_paths:",len([x for x in a if not x["path"].startswith("/data/media/music/")]))'
```

Expected: counts identical to `$WORK/baseline.txt` (140 / 906 / 288) and `bad_paths: 0`
for all three.

- [ ] **Step 4: Verify root folders are accessible with correct free space**

An inaccessible root folder or `0` free space means the mount is wrong.

```bash
curl -s -H "X-Api-Key: $SONARR_KEY" http://localhost:8989/api/v3/rootfolder \
  | python3 -c 'import json,sys; [print(r["path"],"accessible:",r["accessible"],"free:",round(r.get("freeSpace",0)/1e12,2),"TB") for r in json.load(sys.stdin)]'
curl -s -H "X-Api-Key: $RADARR_KEY" http://localhost:7878/api/v3/rootfolder \
  | python3 -c 'import json,sys; [print(r["path"],"accessible:",r["accessible"],"free:",round(r.get("freeSpace",0)/1e12,2),"TB") for r in json.load(sys.stdin)]'
curl -s -H "X-Api-Key: $LIDARR_KEY" http://localhost:8686/api/v1/rootfolder \
  | python3 -c 'import json,sys; [print(r["path"],"accessible:",r["accessible"],"free:",round(r.get("freeSpace",0)/1e12,2),"TB") for r in json.load(sys.stdin)]'
```

Expected: `/data/media/tv`, `/data/media/movies`, `/data/media/music`, all
`accessible: True`, all reporting roughly 3.6 TB free.

- [ ] **Step 5: Check for health issues raised by the apps themselves**

```bash
for pair in "8989 v3 $SONARR_KEY" "7878 v3 $RADARR_KEY" "8686 v1 $LIDARR_KEY"; do
  set -- $pair
  echo "--- port $1 ---"
  curl -s -H "X-Api-Key: $3" "http://localhost:$1/api/$2/health" \
    | python3 -c 'import json,sys; h=json.load(sys.stdin); print("clean") if not h else [print(x["type"],":",x["message"]) for x in h]'
done
```

Expected: `clean`, or only pre-existing warnings unrelated to paths. Any message
mentioning a missing root folder or inaccessible path is a failure.

- [ ] **Step 6: Verify qBittorrent kept all its torrents**

```bash
docker logs qbittorrent --tail 30
ls "$CONFIG"/qbittorrent/qBittorrent/BT_backup/*.fastresume | wc -l
```

Then open `http://192.168.20.14:9091` and confirm the torrent list shows the baseline
count (24) with **zero** in an errored or "missing files" state.

- [ ] **Step 7: Verify NZBGet kept its queue and history**

Open `http://192.168.20.14:6789`. Confirm the history is intact and the queue matches what
was there at Task 3. Unpause the queue.

- [ ] **Step 8: Verify Plex is untouched**

Open Plex. Confirm libraries show their full item counts, nothing is flagged unavailable,
and watch history is intact. No rescan should be necessary or triggered.

**Rollback:** Full rollback at this point is: `docker compose down`, reverse the Task 5
renames, restore the Task 3 cold-backup databases, `git checkout` the compose files,
restore the Task 7 and Task 8 configs, `docker compose up -d`.

---

## Task 11: Prove hardlinks work

This is the entire point of the migration. Everything before this is setup.

**Files:** None modified.

- [ ] **Step 1: Hardlink across the download and media trees**

```bash
docker exec sonarr sh -c '
  set -e
  touch /data/torrents/tv/.hltest
  ln /data/torrents/tv/.hltest /data/media/tv/.hltest
  echo "HARDLINK OK  links=$(stat -c %h /data/torrents/tv/.hltest)"
  rm -f /data/torrents/tv/.hltest /data/media/tv/.hltest
'
```

Expected: `HARDLINK OK  links=2`.

A failure with `Invalid cross-device link` means the mounts are still split — recheck
Task 10 Step 2.

- [ ] **Step 2: Repeat for Radarr and Lidarr**

```bash
docker exec radarr sh -c '
  set -e
  touch /data/torrents/movies/.hltest
  ln /data/torrents/movies/.hltest /data/media/movies/.hltest
  echo "RADARR HARDLINK OK  links=$(stat -c %h /data/torrents/movies/.hltest)"
  rm -f /data/torrents/movies/.hltest /data/media/movies/.hltest
'
docker exec lidarr sh -c '
  set -e
  touch /data/torrents/music/.hltest
  ln /data/torrents/music/.hltest /data/media/music/.hltest
  echo "LIDARR HARDLINK OK  links=$(stat -c %h /data/torrents/music/.hltest)"
  rm -f /data/torrents/music/.hltest /data/media/music/.hltest
'
```

Expected: both report `links=2`.

- [ ] **Step 3: Confirm the legacy folder also hardlinks**

Existing torrents still live in `/data/complete`, so imports from there must hardlink too.

```bash
docker exec sonarr sh -c '
  set -e
  touch /data/complete/.hltest
  ln /data/complete/.hltest /data/media/tv/.hltest
  echo "LEGACY HARDLINK OK  links=$(stat -c %h /data/complete/.hltest)"
  rm -f /data/complete/.hltest /data/media/tv/.hltest
'
```

Expected: `LEGACY HARDLINK OK  links=2`.

- [ ] **Step 4: Enable Auto Torrent Management for new torrents**

Only now, with everything verified. In the qBittorrent WebUI at
`http://192.168.20.14:9091`, go to **Tools → Options → Downloads** and set these four
options exactly:

| Option | Set to |
|---|---|
| Default Torrent Management Mode | `Automatic` |
| When Torrent Category changed | `Switch torrent to Manual Mode` |
| When Default Save Path changed | `Switch affected torrents to Manual Mode` |
| When Category Save Path changed | `Switch affected torrents to Manual Mode` |

Only the first is being changed; the other three are defaults being confirmed. Every one
of them offers a `Relocate torrent` alternative — **do not select it**. Relocation moves
the 24 existing torrents out of `/data/complete` and breaks every one of them.

- [ ] **Step 5: Verify the existing torrents did not move**

```bash
python3 - <<'PY'
import glob, re, collections, os
c = collections.Counter()
for p in glob.glob(os.environ['CONFIG'] + '/qbittorrent/qBittorrent/BT_backup/*.fastresume'):
    d = open(p, 'rb').read()
    for m in re.finditer(rb'save_path(\d+):', d):
        n = int(m.group(1))
        c[d[m.end():m.end()+n].decode('utf8', 'replace')] += 1
for k, v in c.most_common():
    print(f"{v:5d}  {k}")
PY
```

Expected: still 24 entries at `/data/complete`, matching the baseline. If any have moved,
one of the relocation triggers was enabled — turn it off and restore from
`$WORK/config-backup/`.

- [ ] **Step 6: Prove an end-to-end import hardlinks rather than copies**

Grab any completed item and run a manual import through the Sonarr or Radarr UI
(**Wanted → Manual Import**, point it at `/data/complete`). Then:

```bash
docker logs sonarr --tail 200 | grep -iE 'hardlink|copied|moved|import' | tail -20
```

Expected: log lines showing a hardlink or instant move. The word `Copied` in an import
line means hardlinks are still not working — stop and recheck.

Confirm the disk did not lose space to a duplicate:

```bash
df -h "$STORAGE" | tail -1
```

**Rollback:** N/A — verification only. Any failure sends you back to Task 10 rollback.

---

## Task 12: Point the *arrs at internal download client addresses

Sonarr and Lidarr currently reach the download clients over public hostnames, hairpinning
out to the internet and back through nginx-proxy-manager to containers on the same host.

**Files:** None on disk — changes are made through each app's UI.

- [ ] **Step 1: Record the current client settings**

```bash
for pair in "8989 v3 $SONARR_KEY" "7878 v3 $RADARR_KEY"; do
  set -- $pair
  echo "--- port $1 ---"
  curl -s -H "X-Api-Key: $3" "http://localhost:$1/api/$2/downloadclient" \
    | python3 -c 'import json,sys; [print(d["name"],d["enable"],{f["name"]:f.get("value") for f in d["fields"] if f["name"] in ("host","port","useSsl")}) for d in json.load(sys.stdin)]'
done
curl -s -H "X-Api-Key: $LIDARR_KEY" http://localhost:8686/api/v1/downloadclient \
  | python3 -c 'import json,sys; [print(d["name"],d["enable"],{f["name"]:f.get("value") for f in d["fields"] if f["name"] in ("host","port","useSsl")}) for d in json.load(sys.stdin)]'
```

- [ ] **Step 2: Update each client through the UI**

In Sonarr, Radarr and Lidarr, under **Settings → Download Clients**, set:

| Client | Host | Port | SSL |
|---|---|---|---|
| qBittorrent | `192.168.20.14` | `9091` | off |
| NZBGet | `192.168.20.14` | `6789` | off |

This addressing is already proven — Radarr reaches NZBGet this way today.

Use **Test** on each client before saving. A green result is required.

- [ ] **Step 3: Delete the dead Transmission entries**

Sonarr has a disabled `Transmission-OpenVPN` client and Radarr has a disabled
`Transmission`. Both are leftovers from a previous setup. Remove them.

- [ ] **Step 4: Verify no client still uses a public hostname**

```bash
for pair in "8989 v3 $SONARR_KEY" "7878 v3 $RADARR_KEY"; do
  set -- $pair
  curl -s -H "X-Api-Key: $3" "http://localhost:$1/api/$2/downloadclient" \
    | python3 -c 'import json,sys; [print(d["name"],[f.get("value") for f in d["fields"] if f["name"]=="host"]) for d in json.load(sys.stdin)]'
done
curl -s -H "X-Api-Key: $LIDARR_KEY" http://localhost:8686/api/v1/downloadclient \
  | python3 -c 'import json,sys; [print(d["name"],[f.get("value") for f in d["fields"] if f["name"]=="host"]) for d in json.load(sys.stdin)]'
```

Expected: every host is `192.168.20.14`. No `.merle.io` anywhere.

- [ ] **Step 5 (optional): Switch to compose service names**

Only attempt this after Step 4 is verified working. qBittorrent and NZBGet share the VPN
container's network namespace, so they are reachable as `vpn:8080` and `vpn:6789` from
other services on `docker-everything-on-it_default` (172.19.0.0/16). The WireGuard
killswitch must be told to allow that subnet, or return traffic is dropped.

In `docker-compose.yml`, in the `vpn` service environment:

```yaml
            - LOCAL_NETWORK=192.168.20.0/24,172.19.0.0/16
```

Then `docker compose up -d vpn` and test connectivity before changing any client:

```bash
docker exec sonarr sh -c 'wget -qO- --timeout=5 http://vpn:6789 >/dev/null && echo "nzbget reachable" || echo "unreachable — keep host IP"'
```

If unreachable, revert the `LOCAL_NETWORK` change and stay on host IPs. This is a
convenience improvement, not a requirement.

**Rollback:** Restore the hostnames recorded in Step 1 through the UI.

---

## Task 13: Import Bluey Minisodes

Deferred and fully decoupled — the migration is complete and verified without this.

**Files:** None modified directly.

- [ ] **Step 1: Confirm the staged copy is in place**

```bash
find "$STORAGE/data/torrents/tv/Bluey Minisodes.manual" -type f -name '*.mkv' | wc -l
```

Expected: a non-zero count (Season 1 episodes).

- [ ] **Step 2: Run a manual import in Sonarr**

In Sonarr, go to **Wanted → Manual Import** and point it at
`/data/torrents/tv/Bluey Minisodes.manual`.

Sonarr re-parses each file and maps it to the correct TVDB episode. This is required
because the staged copy numbers episodes differently from the tracked copy — `Butlers` is
`S01E17` in the staged files but `S01E15` in the library, and `Goldilocks` is `S01E19`
versus `S01E17`.

Review every proposed mapping before importing. Where the staged WEBDL file matches an
episode currently held as HDTV, it is a genuine quality upgrade and should be imported.

- [ ] **Step 3: Verify and clean up**

```bash
curl -s -H "X-Api-Key: $SONARR_KEY" http://localhost:8989/api/v3/series \
  | python3 -c 'import json,sys; s=[x for x in json.load(sys.stdin) if x["title"]=="Bluey Minisodes"][0]; st=s["statistics"]; print("path:",s["path"]); print("episodes:",st["episodeFileCount"],"of",st["totalEpisodeCount"]); print("size:",round(st["sizeOnDisk"]/1e9,2),"GB")'
```

Expected: `path: /data/media/tv/Bluey Minisodes`, an episode count at or above the
baseline 27 of 31, and a larger size on disk reflecting the WEBDL upgrades.

Once satisfied:

```bash
rm -rf "$STORAGE/data/torrents/tv/Bluey Minisodes.manual"
```

**Rollback:** Nothing is destroyed until the final `rm`. Leave the staging directory in
place if the import is inconclusive.

---

## Task 14: Finalise

**Files:**
- Modify: `docs/superpowers/plans/2026-08-01-data-restructure.md`

- [ ] **Step 1: Confirm the full verification checklist passed**

- [ ] All containers up, `wireguard-pia` healthy
- [ ] Library counts match baseline (140 / 906 / 288)
- [ ] Zero paths outside the new roots in all three apps
- [ ] Root folders accessible, ~3.6 TB free reported
- [ ] No path-related health warnings
- [ ] 24 torrents present, zero errored, all still at `/data/complete`
- [ ] NZBGet queue and history intact, queue unpaused
- [ ] Plex libraries intact, no rescan triggered, watch history preserved
- [ ] Hardlink test passes in sonarr, radarr and lidarr
- [ ] Legacy `/data/complete` hardlink test passes
- [ ] A real import logs a hardlink, not a copy
- [ ] No download client uses a `.merle.io` hostname
- [ ] `nzbget.log` is small and not regrowing

- [ ] **Step 2: Check the log is not regrowing**

Let the stack run through a few downloads first.

```bash
ls -la "$STORAGE/data/nzbget/nzbget.log"
```

Expected: kilobytes to a few megabytes, not gigabytes. If it is growing fast again,
recheck `DetailTarget` in `nzbget.conf`.

- [ ] **Step 3: Commit the completed plan**

```bash
git add docs/superpowers/plans/2026-08-01-data-restructure.md
git commit -m "Mark /data restructure plan complete

All verification gates passed: hardlinks confirmed working across
torrents, usenet and legacy download trees; libraries and torrents
intact; Plex untouched."
```

- [ ] **Step 4: Clean up the working directory**

Keep the database backups for at least a week of clean running.

```bash
echo "keeping: $WORK"
du -sh "$WORK"
```

Delete only once the stack has run clean for a week:

```bash
rm -rf "$WORK"
```

---

## Notes and observations

Recorded during planning; not part of this plan's scope.

**qBittorrent share limits are effectively zero.** `Session\GlobalMaxRatio=0.01`,
`GlobalMaxSeedingMinutes=1` and `GlobalMaxInactiveSeedingMinutes=1` with
`ShareLimitAction=Stop` mean torrents stop seeding almost immediately after completing.
On private trackers this is hit-and-run behaviour and risks a ban. Worth a deliberate
decision, separately from this work.

**`.env` is a tracked file in a public repo** and the working copy contains live PIA
credentials. Git history holds only placeholders, so nothing has leaked, but a single
`git add -A` would publish them. Handle in the repo hygiene branch.

**Follow-on branches**, in suggested order: repo hygiene; Overseerr → Seerr; small fixes
(restart policies, `PIA_USER`/`PIA_PASS` rename, Tautulli's broken `/logs` mount,
Maintainerr image path, FlareSolverr → Byparr); additions (Recyclarr, Unpackerr, a queue
cleaner). None of them depend on this branch and it does not depend on them.
