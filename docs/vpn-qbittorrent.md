# VPN (wireguard-pia) + qBittorrent / NZBGet

## What was wrong before (old server, confirmed from logs on 2026-10-17)
- No `depends_on`: qBittorrent started 0.2 s after the vpn container, before `wg0` existed, and
  bound its listen sockets to the bridge IP only. Torrent traffic left with the wrong source
  address and was dropped by the kill-switch, so it "ran but did nothing".
- No restart policy on `vpn`/`qbittorrent`: after a reboot the vpn never came back and nzbget
  failed to join its network namespace.
- PIA US regions have no port forwarding, so qBittorrent was never connectable.

## How it is wired now
- `vpn` is `restart: unless-stopped` with `ACTIVE_HEALTHCHECKS=1` (pings over wg0 once a minute)
  and `RECONNECT=1`.
- `qbittorrent` and `nzbget` use `network_mode: service:vpn` and
  `depends_on: vpn: {condition: service_healthy, restart: true}`. They start only once the
  tunnel is up and are restarted whenever the vpn container is recreated or restarted via compose.
- qBittorrent is bound to the tunnel interface (`Session\Interface=wg0`,
  `Session\InterfaceName=wg0` in `qBittorrent.conf`). This is the kill switch: with wg0 absent
  libtorrent cannot bind and nothing leaves via eth0.
- `WebUI\LocalHostAuth=false`: only vpn/qbittorrent/nzbget share 127.0.0.1 in that namespace, so
  localhost API calls (healthcheck, port script) need no credentials. The WebUI is still
  password-protected from the LAN/NPM.
- Port forwarding: `PIA_PORT_FORWARDING=1` with a PF-capable region (`PIA_LOC=ca_toronto,ca_ontario,mexico`).
  On every (re)connect the vpn container runs `scripts/set_qbt_port.sh <port>`, which pushes the
  forwarded port into qBittorrent via its API. The port is also in `/pia-shared/port.dat` inside
  the vpn container. `PORT_PERSIST=1` tries to keep the same port across restarts.
- To go back to a US exit (no port forwarding): set `PIA_LOC=us_california,us_chicago` and
  `PIA_PORT_FORWARDING=0` in `.env`, then `docker compose up -d`.

## Rules
- **Never `docker restart wireguard-pia`.** Docker does not restart the containers that joined its
  network namespace; they keep a dead namespace. Use `docker compose restart vpn` or
  `docker compose up -d`.
- Run compose as `c0re`, never with `sudo` (sudo's `USER` env overrides `.env`).
- Update routine: `docker compose pull && docker compose up -d && docker image prune -f`.

## Checks
```bash
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'pia|qbit|nzbget'   # vpn healthy, others Up
docker logs wireguard-pia 2>&1 | grep -E 'Adding route|Port forwarding|set_qbt_port' | tail
grep 'Successfully listening on IP' config/qbittorrent/qBittorrent/logs/qbittorrent.log | tail -4   # 10.x only
docker exec wireguard-pia cat /pia-shared/port.dat
docker exec qbittorrent sh -c 'wget -qO- --timeout=5 https://ipinfo.io/ip; echo'   # PIA address
```
