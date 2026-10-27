# Docker With Everything on It

## Getting Started

### Clone this repository
```
git clone https://github.com/0xc0re/docker-everything-on-it docker
```

### Modify as needed

The docker-compose.yml and .env files need to be modified. The .env file contains environment variables
that define the timezone, storage directory, PUID, and PGID used by the
containers. It also holds `QBT_USER` and `QBT_PASS`, which `script.sh` reads to
log in to qBittorrent (`QBT_PORT` is optional and defaults to 9091).


### Modify the '.env' file with your PIA credentials.

Replace the placeholders with your info.

```
USER=PIA_USERNAME
PASS=PIA_PASSWORD
```


### Set your qBittorrent credentials

`script.sh` reads these from the environment (or from the `.env` file next to it).
Replace the placeholders with your qBittorrent login.

```
QBT_USER=admin
QBT_PASS=QBITTORRENT_PASSWORD
```


### Run docker-compose 

Run in background:

``` 
docker-compose up -d
```

Run in foreground (useful for first launch):

```
docker-compose up
```


### View logs to ensure everything works.

```
docker logs plex -f
```
