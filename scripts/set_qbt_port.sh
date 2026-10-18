#!/bin/bash
# PORT_SCRIPT for thrnz/docker-wireguard-pia: run inside the vpn container with the
# forwarded port as $1 whenever PIA assigns (or changes) it. qBittorrent shares this
# network namespace, so its WebUI is 127.0.0.1:9091 (WEBUI_PORT). Needs curl + jq (present in the image).
# Auth: none needed when qBittorrent.conf has WebUI\LocalHostAuth=false; otherwise set
# QBT_USER/QBT_PASS in the vpn service environment.
set -euo pipefail
PORT="${1:?forwarded port required as \$1}"
QBT_URL="${QBT_URL:-http://127.0.0.1:9091}"
COOKIES="$(mktemp)"; trap 'rm -f "$COOKIES"' EXIT
log() { echo "[set_qbt_port] $(date -Is) $*"; }

# qbittorrent starts only after this container is healthy, so the WebUI may lag: wait up to 3 min.
code=""
for _ in $(seq 1 90); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$QBT_URL/api/v2/app/version" || true)"
  [[ "$code" == "200" || "$code" == "403" ]] && break
  sleep 2
done
[[ "$code" == "200" || "$code" == "403" ]] || { log "ERROR: qBittorrent WebUI not reachable at $QBT_URL (last http $code)"; exit 1; }

if [[ -n "${QBT_USER:-}" && -n "${QBT_PASS:-}" ]]; then
  resp="$(curl -fsS -c "$COOKIES" --data-urlencode "username=$QBT_USER" --data-urlencode "password=$QBT_PASS" "$QBT_URL/api/v2/auth/login")"
  [[ "$resp" == "Ok." ]] || { log "ERROR: login failed: $resp"; exit 1; }
fi

curl -fsS -b "$COOKIES" --data-urlencode "json={\"listen_port\":$PORT,\"upnp\":false,\"random_port\":false}" \
  "$QBT_URL/api/v2/app/setPreferences"
current="$(curl -fsS -b "$COOKIES" "$QBT_URL/api/v2/app/preferences" | jq -r .listen_port)"
if [[ "$current" == "$PORT" ]]; then
  log "qBittorrent listen_port set to $PORT"
else
  log "ERROR: listen_port is '$current', expected $PORT"; exit 1
fi
