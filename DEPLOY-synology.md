# Run the scraper on a Synology NAS

Watches every D2R product channel and downloads new builds into a mounted share.

## Container Manager

1. Copy the repo onto the NAS (e.g. `/volume1/Media/d2r-cdn`).
2. In `docker/docker-compose.yml`, point the volume at a share with room:
   `- /volume1/<share>/d2r-data:/data`.
3. Optional: create `.env` with `DISCORD_WEBHOOK=...` for alerts.
4. Container Manager → Project → Create → point it at the repo folder.

Or from a shell with docker:

```
DISCORD_WEBHOOK=... docker compose -f docker/docker-compose.yml up -d
```

## On disk (under the mounted volume)

- `pool/` — shared content-addressed store (`config/` + `data/` by hash); the bulk data.
- `builds/<product>/<version>.json` — one record per build.
- `state/` — last-seen tracking, so nothing re-downloads.

## Env

- `INTERVAL` — seconds between polls (default 60).
- `DATA=1` — download full data on new plaintext builds; unset = detect only.

First run downloads the current builds in full (tens of GB); after that only changed
data. To skip the baseline, drop an existing mirror's `config/` + `data/` into `pool/`
first — anything already present (matched by hash) is skipped.
