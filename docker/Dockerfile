# Poller: watches every D2R product channel and captures new builds into a shared
# content-addressed pool on the mounted volume, alerting on Discord.
# Build from the repo root:  docker build -f docker/Dockerfile -t d2r-scraper .
FROM alpine:3.20
RUN apk add --no-cache bash curl coreutils tzdata
WORKDIR /app
COPY scripts/mirror.sh scripts/scrape.sh ./
RUN chmod +x mirror.sh scrape.sh
ENV INTERVAL=60 DATA=1
VOLUME ["/data"]
ENTRYPOINT ["/app/scrape.sh", "/data"]
