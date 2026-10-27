#!/bin/bash

port="$1"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_user="${QBT_USER:-}"; env_pass="${QBT_PASS:-}"; env_port="${QBT_PORT:-}"
if [ -f "$dir/.env" ]; then
  set -a; . "$dir/.env"; set +a
fi
# The environment wins over .env
[ -n "$env_user" ] && QBT_USER="$env_user"
[ -n "$env_pass" ] && QBT_PASS="$env_pass"
[ -n "$env_port" ] && QBT_PORT="$env_port"
QBT_PORT="${QBT_PORT:-9091}"
if [ -z "${QBT_USER:-}" ] || [ -z "${QBT_PASS:-}" ] || [ "${QBT_PASS}" = "QBITTORRENT_PASSWORD" ]; then
  echo "script.sh: QBT_USER and QBT_PASS must be set (export them or add them to .env)" >&2
  exit 1
fi

echo "Setting qBittorrent port settings ($port)..."
# Very basic retry logic so we don't fail if qBittorrent isn't running yet
 while ! curl --silent --retry 10 --retry-delay 15 --max-time 10 \
  --data "username=${QBT_USER}&password=${QBT_PASS}" \
  --cookie-jar /tmp/qb-cookies.txt \
  https://transmission.merle.io:${QBT_PORT}/api/v2/auth/login
  do
    sleep 10
  done
  
curl --silent --retry 10 --retry-delay 15 --max-time 10 \
  --data 'json={"listen_port": "'"$port"'"}' \
  --cookie /tmp/qb-cookies.txt \
  https://transmission.merle.io:${QBT_PORT}/api/v2/app/setPreferences

echo "Qbittorrent port updated successfully ($port)..."