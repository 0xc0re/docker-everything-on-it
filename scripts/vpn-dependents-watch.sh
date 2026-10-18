#!/bin/bash
# Host-side watchdog for the containers that share wireguard-pia's network namespace.
# Docker's restart policy ignores compose depends_on, so after a reboot, a dockerd restart or a
# vpn crash qbittorrent/nzbget can be left exited or stuck in a dead namespace. Every 2 minutes:
# if the vpn is healthy and a dependent is not running+healthy, bring it back through compose
# (which re-joins the vpn's current namespace). Runs as c0re via arr-vpn-watch.timer.
set -u
cd /mnt/flash/docker-everything-on-it || exit 1
vpn=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' wireguard-pia 2>/dev/null)
[ "$vpn" = "running healthy" ] || { echo "vpn: ${vpn:-absent}; nothing to do"; exit 0; }
fix=()
for c in qbittorrent nzbget; do
  st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null)
  case "$st" in "running healthy"|"running starting") ;; *) fix+=("$c"); echo "$c: $st";; esac
done
[ ${#fix[@]} -eq 0 ] && exit 0
echo "restarting: ${fix[*]}"
docker compose up -d --no-recreate "${fix[@]}" >/dev/null 2>&1   # starts exited ones (waits for vpn healthy)
docker compose restart "${fix[@]}"                                # re-joins the vpn namespace for stuck ones
