# Run the watcher on a Synology NAS

Watches every D2R product channel and downloads new builds into a mounted share.
Nothing is built on the NAS: it pulls `ghcr.io/jaenster/d2r-cdn` from the pipeline.

## Container Manager

1. Put `docker/docker-compose.yml` somewhere on the NAS (that one file is enough).
2. Point the volume at a share with room: `- /volume1/<share>/d2r-data:/data`.
3. Optional: create `.env` next to it with `DISCORD_WEBHOOK=...` for alerts.
4. Container Manager → Project → Create → point it at that folder.

Or from a shell with docker:

```
DISCORD_WEBHOOK=... docker compose -f docker/docker-compose.yml up -d
```

To update, pull and recreate — `pull_policy: always` means a restart is enough:

```
docker compose -f docker/docker-compose.yml up -d --pull always
```

## On disk (under the mounted volume)

- `pool/` — shared content-addressed store (`config/` + `data/` by hash); the bulk data.
- `builds/<product>/<version>.json` — one record per build.
- `state/` — last-seen tracking, so nothing re-downloads.

## Tuning the watcher

The container's command is the CLI, so the poll is configured in
`docker-compose.yml`: `command: ["watch", "/data", "--interval", "60", "--data"]`.

- `--interval <s>` — seconds between passes.
- `--data` — mirror the full build when a new one appears; drop it to detect only.
- `--products "osi osib"` — watch specific channels instead of the full brute list.
- `DISCORD_WEBHOOK` — alerts on new builds and on any encrypted → plaintext flip.

First run downloads the current builds in full (tens of GB); after that only changed
data. To skip the baseline, drop an existing mirror's `config/` + `data/` into `pool/`
first — anything already present (matched by hash and size) is skipped.

The same image is the whole toolbox, so the NAS can also extract a real game tree out
of the pool it already has, without re-downloading anything:

```
docker run --rm -v /volume1/<share>/d2r-data:/data ghcr.io/jaenster/d2r-cdn \
  --pool /data/pool extract -o /data/game
```
