# Run the scraper on a Synology NAS

Polls every D2R product every 60s, captures new builds, downloads full data of new
plaintext builds into the big Media share. Alerts to Discord.

## Steps (Container Manager)

1. Copy this whole `d2r-cdn` folder onto the NAS (e.g. into `/volume1/Media/`), so
   `Dockerfile`, `docker-compose.yml`, `scrape.sh`, `mirror.sh` sit together.
2. Confirm the download path in `docker-compose.yml`:
   `- /volume1/Media/d2r-cdn:/data`  (change `Media` if your share is named
   differently; Synology shares are `/volume1/<ShareName>`).
3. (optional) create a `.env` next to the compose file:
   `DISCORD_WEBHOOK=https://discord.com/api/webhooks/....`
4. Container Manager -> Project -> Create -> Path = the folder from step 1 ->
   it reads `docker-compose.yml` -> Build + run.
5. Watch it: Container Manager -> Container `d2r-scraper` -> Logs. You'll see
   `fingerprint captured` / `DOWNLOADING` / `DATA COMPLETE` lines, mirrored to Discord.

## What lands on disk (`/volume1/Media/d2r-cdn/`)

- `pool/` — one shared content-addressed store for ALL products/builds. Identical
  blobs (configs, encoding, unchanged archives) are stored once. This is where the
  bulk data goes.
- `builds/<product>/<version>.json` — a small record per build (config hash,
  encrypted flag, needs-key).
- `state/` — last-seen tracking (so nothing re-downloads).

## First run

On first run every product is "new", so it downloads the current builds in full
(~37 GB for `osi`, plus small deltas for `osit`/`osic` which share most archives).
That baseline is slow over a home line but only happens once; after that only
changed archives download.

Optional shortcut: if you already have a full mirror (e.g. the ~36 GB `d2r-mirror`),
copy its `config/` + `data/` into `pool/` first - the scraper skips anything already
present (matched by hash), so it won't re-download the baseline.

## Tuning

- `INTERVAL` — seconds between polls (default 60). Lower = more aggressive.
- `DATA=1` — download full data on new plaintext builds. Unset = fingerprints only.
- Encrypted channels (dev/vendor) only ever yield their encrypted config bytes +
  a `needs-key=...` note; their data can't be enumerated without the key.
