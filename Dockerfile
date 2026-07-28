# Aggressive D2R CDN poller for a Synology NAS (Container Manager / docker).
# Polls every D2R product channel every INTERVAL seconds, captures new builds into
# a shared content-addressed pool on the mounted volume, alerts on Discord.
FROM alpine:3.20
RUN apk add --no-cache bash curl coreutils tzdata
WORKDIR /app
COPY mirror.sh scrape.sh ./
RUN chmod +x mirror.sh scrape.sh
# every 60s, download full data on any new plaintext build, into /data (a NAS mount)
ENV INTERVAL=60 DATA=1
VOLUME ["/data"]
ENTRYPOINT ["/app/scrape.sh", "/data"]
