# docker-everything-on-it

Media automation stack for `asgard`: Sonarr, Radarr, Lidarr, Prowlarr, FlareSolverr, Seerr,
Maintainerr, and qBittorrent + NZBGet behind a PIA WireGuard container.

Plex and Tautulli run as a separate compose project in `/mnt/flash/plex`.

## Setup
1. `cp .env.example .env` and fill in `PIA_USER` / `PIA_PASS` (and the paths if not on asgard).
2. All *arr apps and both download clients see one bind mount, `/mnt/storage/data` -> `/data`
   (`media/{movies,tv,music}`, `torrents/`, `usenet/`), so imports are hardlinks.
3. `docker compose up -d` as a user in the `docker` group. Do not use `sudo`.

See `docs/vpn-qbittorrent.md` for the VPN/port-forwarding design and `docs/removed-services.md`
for what was taken out and where its config was archived.
