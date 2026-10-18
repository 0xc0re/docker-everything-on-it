# Removed services (2026-10-18)

Removed from `docker-compose.yml` during the Oct 2026 restructure. Books (readarr,
calibre-web-automated) were removed because nobody uses them; the others had been
commented out since 2024-2025. Config directories were archived to
`/mnt/storage/backup/flash-archive-2026-10/config_<name>.tar.zst` before deletion.

Also moved out (not removed): **plex** and **tautulli** now live in `/mnt/flash/plex`
(own compose project). **overseerr** was replaced by **seerr** (`ghcr.io/seerr-team/seerr`),
config dir `config/overseer/config` -> `config/seerr`.

## Data left in place
- `/mnt/storage/books` (readarr / calibre ingest, 6 MB)
- `/mnt/storage/calibre` (calibre library, <1 MB, root-owned)

## Optional: Prowlarr hotio -> lscr swap
The `/config` layout is identical (`config.xml`, `prowlarr.db` at the root). Guard: the lscr
image's `build_version` label must be >= the running version (`/api/v1/system/status`).
Then change the image line to `lscr.io/linuxserver/prowlarr:latest`, drop `UMASK`,
`docker compose up -d prowlarr`. Rollback = revert the line.

## The removed blocks (verbatim from the old file)
```yaml
    #bazarr:
    #    # Subtitle management for movies and TV (integrates with Radarr/Sonarr)
    #    image: lscr.io/linuxserver/bazarr:latest
    #    container_name: bazarr
    #    environment:
    #        - PUID=${PUID}
    #        - PGID=${PGID}
    #        - TZ=${TZ}
    #    volumes:
    #        - ${CONFIG_DIRECTORY}/bazarr:/config
    #        - ${STORAGE_DIRECTORY}/video/movie:/movies #optional
    #        - ${STORAGE_DIRECTORY}/video/tv:/tv #optional
    #    ports:
    #        - 6767:6767
    #    restart: unless-stopped

#    dispatcharr:
#        # Requests/dispatch management UI for *arr ecosystem
#        image: ghcr.io/dispatcharr/dispatcharr:latest
#        container_name: dispatcharr
#        restart: unless-stopped
#        environment:
#            - PUID=${PUID}
#            - PGID=${PGID}
#            - TZ=${TZ}
#        ports:
#            - 9191:9191
#        volumes:
#            - ${CONFIG_DIRECTORY}/dispatcharr:/data
#        devices:
#              - /dev/dri:/dev/dri
#        deploy:
#            resources:
#                reservations:
#                    devices:
#                        - driver: nvidia
#                          count: all
#                          capabilities: [gpu]
#    #epg:
#    #    # EPG generator by iptv-org; serves guide.xml at port 3000
#    #    image: ghcr.io/iptv-org/epg:master
#    #    container_name: epg
#    #    restart: unless-stopped
#    #    ports:
#    #        - 3000:3000
#    #    environment:
#    #        - CRON_SCHEDULE=0 0 * * *
#    #        - MAX_CONNECTIONS=5
#    #        - DAYS=14
#    #        - TIMEOUT=30000
#    #        - DELAY=2
#    #        - RUN_AT_STARTUP=true
#    #    volumes:
#    #        - ${CONFIG_DIRECTORY}/epg/channels.xml:/epg/channels.xml
#    #        - ${CONFIG_DIRECTORY}/epg/public:/epg/public

    #tdarr:
    #    # Automated transcoding/health checks for media, with GPU acceleration
    #    container_name: tdarr
    #    image: ghcr.io/haveagitgat/tdarr:latest
    #    restart: unless-stopped
    #    network_mode: bridge
    #    ports:
    #        - 8265:8265 # webUI port
    #        - 8266:8266 # server port
    #    environment:
    #        - TZ=${TZ}
    #        - PUID=${PUID}
    #        - PGID=${PGID}
    #        - UMASK_SET=002
    #        - serverIP=0.0.0.0
    #        - serverPort=8266
    #        - webUIPort=8265
    #        - internalNode=true
    #        - inContainer=true
    #        - ffmpegVersion=6
    #        - nodeName=ASGARD
    #        - NVIDIA_DRIVER_CAPABILITIES=all
    #        - NVIDIA_VISIBLE_DEVICES=all
    #    volumes:
    #        - ${CONFIG_DIRECTORY}/tdarr/server:/app/server
    #        - ${CONFIG_DIRECTORY}/tdarr/configs:/app/configs
    #        - ${CONFIG_DIRECTORY}/tdarr/logs:/app/logs
    #        - ${STORAGE_DIRECTORY}/video/movie:/media/video/movie:rw
    #        - ${STORAGE_DIRECTORY}/video/tv:/media/video/tv:rw
    #        - ${STORAGE_DIRECTORY}/tmp/tdarr:/temp
    #    devices:
    #        - /dev/dri:/dev/dri
    #    deploy:
    #        resources:
    #            reservations:
    #                devices:
    #                - driver: nvidia
    #                  count: all
    #                  capabilities: [gpu]

    #readarr:
    #    # E-book/audiobook manager for automated downloads and organization
    #    container_name: readarr
    #    hostname: readarr
    #    image: lscr.io/linuxserver/readarr:develop
    #    restart: unless-stopped
    #    volumes:
    #        - ${CONFIG_DIRECTORY}/readarr:/config
    #        - ${STORAGE_DIRECTORY}/downloads:/data
    #        - ${STORAGE_DIRECTORY}/books:/books
    #        - /etc/localtime:/etc/localtime:ro
    #    ports:
    #        - "8787:8787"
    #    environment:
    #        - PUID=${PUID}
    #        - PGID=${PGID}
    #        - TZ=${TZ}
    #
    #calibre-web-automated:
    #    # Calibre-Web with automated ingestion; web UI for Calibre library
    #    image: crocodilestick/calibre-web-automated:latest
    #    container_name: calibre-web-automated
    #    environment:
    #    - PUID=${PUID}
    #    - PGID=${PGID}
    #    - TZ=America/Chicago
    #    - DOCKER_MODS=lscr.io/linuxserver/mods:universal-calibre-v7.16.0
    #    volumes:
    #    - ${CONFIG_DIRECTORY}/calibre-web-automated:/config
    #    - ${STORAGE_DIRECTORY}/books:/cwa-book-ingest
    #    - ${STORAGE_DIRECTORY}/calibre/library:/calibre-library
    #    ports:
    #    - 8084:8083 # Change the first number to change the port you want to access the Web UI, not the second
    #    restart: unless-stopped
```
