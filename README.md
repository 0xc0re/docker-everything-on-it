# Docker With Everything on It

### Jackett, Sonarr, Radarr, Plex, Tautulli, Transmission, OpenVPN


The Plex image includes a 'hack' to enable NVDEC support and also removes Plex Relay. 



## Getting Started



### Checkout this repository
```
git checkout https://github.com/0xc0re/docker-everything-on-it docker
```


### Modify as needed

The docker-compose.yml and .env files need to be modified. The .env file contains environment variables
that define the timezone, storage directory, PUID, and PGID used by the
containers.


### Modify the 'config/pia/auth.conf' file with your PIA credentials.

Replace the placeholders with your info.

```
YourUserName
YourPassword
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
