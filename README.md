# d2r-cdn

[![Discord](https://img.shields.io/badge/Discord-join%20the%20chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/MHK2Dg9)

Fetch and extract Diablo II: Resurrected files from Blizzard's CDN (NGDP/TACT/CASC)
in Zig. No dependencies, no game content included. (`osi` is D2R's product code.)

It is a library, `tact`, and a CLI that does everything the library can. Nothing to
install if you have docker:

```
docker run --rm ghcr.io/jaenster/d2r-cdn info            # what is live right now
docker run --rm ghcr.io/jaenster/d2r-cdn list --root     # every file in that build
docker run --rm -v $PWD:/data ghcr.io/jaenster/d2r-cdn fetch D2R.exe -o /data
```

The image is the CLI, so every command below works the same way behind
`docker run --rm ghcr.io/jaenster/d2r-cdn`. It is amd64 + arm64, published by CI on
every push to main.

## CLI

```
zig build          # -> zig-out/bin/d2r-cdn
zig build test
```

```
d2r-cdn info                              # build id, version, configs, cdn host
d2r-cdn versions | cdns | bgdl            # raw version-service tables
d2r-cdn config [build|cdn|<hash>]         # a config blob as text
d2r-cdn archives                          # the data archives of this build
d2r-cdn blob <hash> [--raw]               # one blob, BLTE-decoded unless --raw
d2r-cdn list [pattern] [--root]           # install manifest, or the full catalog
d2r-cdn fetch D2R.exe -o ./bin            # install files (exe/dll), md5-verified
d2r-cdn extract 'data:*/excel/*' -o ./out # game files by root path
d2r-cdn mirror /data/pool --indices       # resumable blob mirror of a build
d2r-cdn watch /data --interval 60 --data  # poll every channel, capture new builds
d2r-cdn steam                             # what Steam is serving (no login needed)
```

Options worth knowing (`--help` has the rest):

- `-p osib` / `-r eu` — another product (osib=beta, osit=test) or region.
- `--pool <dir>` — read blobs from a mirror before touching the network.
- `--cache` — write whatever it did fetch back into that pool.

Extraction is resumable and verified: files already on disk are skipped, and every
decoded file is checked against its CKey.

### Mirroring to object storage

Anywhere a pool is taken — `--pool`, and the destination of `mirror` and `watch` — it
may be `s3://<bucket>/<prefix>` instead of a directory. The same binary then mirrors
to a disk or to a bucket; nothing else changes. Blobs stream straight from the CDN
into the bucket, so a 256MB archive needs no local disk and no memory to match.

Credentials come from the environment, never the command line:

```
S3_ENDPOINT=fsn1.your-objectstorage.com   # or AWS_ENDPOINT_URL
S3_REGION=fsn1                            # or AWS_REGION (default us-east-1)
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...

d2r-cdn watch s3://my-bucket/d2r --interval 60 --data
d2r-cdn --pool s3://my-bucket/d2r/pool list     # reads blobs back out of the bucket
```

Signing is SigV4 over `std.http`, path-style addressing, no SDK.

### Steam

D2R also ships on Steam (appid 2536520), and `steam` reports what it is serving:

```
d2r-cdn steam                                   # print the branch table and depots
d2r-cdn steam s3://my-bucket/d2r --interval 900 # record it, alert on any change
```

The branch table comes from PICS app-info over plain HTTP with **no account**, which
is enough to see a branch appear, a build move, or a branch lose its password — the
way an internal build reaches the public. Depot *bytes* are a different matter: those
need a logged-in account that owns the app.

Two things Steam gives that the TACT path does not: a manifest id stays fetchable long
after its build has rotated out (a delisted TACT config just returns 403), and the
`privatebranches` flag tells you when there are branches you cannot see.

`steam-capture` takes the bytes, with an owning account logged in once through
DepotDownloader (it keeps the token under `$HOME`):

```
d2r-cdn steam-capture s3://my-bucket/d2r --interval 20 \
  --files '.*\.(exe|dll|pdb|map|sym)$' --scratch /scratch
```

Every pass it reads the branch table and, for every branch, every depot's manifest:

- **Listing** — each manifest's file list (names and sizes) is stored once, under
  `steam/<app>/listings/<depot>/<manifest>.txt`, and compared with that branch's
  previous manifest and with what public serves. A `.pdb`, an executable that was not
  there before, or one that grew by half is a loud alert; any other file added,
  removed or resized by a fifth (or 5MB) is one quiet message per manifest, with the
  diff stored beside the listing.
- **Capture** — depots smaller than `--whole-under` (512MB) are taken whole, bigger
  ones only for the files `--files` names. The capture marker records the manifest and
  the mode, so widening the filter captures the build again.
- **Refused** — a manifest Steam will not serve this account (a `local` branch needs a
  Local Content Server entitlement, not just ownership) is recorded, alerted once, and
  asked for again every 15 minutes. If it is ever served, that is the loudest alert
  there is.

A depot it has seen through costs nothing on later passes, so a 20s loop is cheap.
`--app 2536520,2344520@300:public` polls the second app at most every 300s and only
on `public`; apps after the first also get one DepotDownloader run a pass, so their new
builds never hold up the first one's cadence.

## Library

```
zig fetch --save git+https://github.com/jaenster/d2r-cdn
```

```zig
const tact = @import("tact");

const cdn = try tact.Cdn.open(gpa, io, .{});   // product osi, region us, current build
defer cdn.close();
const exe = try cdn.extractInstall("D2R.exe"); // decoded file bytes, CKey-verified
```

`Cdn` resolves a product's current build (versions → build/cdn config); everything
after that is pulled on demand and cached until `close`:

- the version service, and the raw config/data blobs behind it
- BLTE decode and the encoding CKey↔EKey map
- the install and root manifests, and archive-index lookup for either
- per-file extraction by CKey, install name or root path
- whether a channel is encrypted, and which Armadillo key it wants
- blob mirroring into a pool — a directory or a bucket — resumable

`src/tact.zig` is the CDN itself; `src/store.zig` is where a pool lives (directory or
bucket, decided internally), `src/s3.zig` is the SigV4 client under it, and
`src/steam.zig` reads Steam's branch table. `example/fetch.zig` is the smallest thing
that uses any of it.

## Docker

`ghcr.io/jaenster/d2r-cdn` is the CLI on a static musl build (~28MB), so anything the
CLI does is one `docker run` away. Mount a volume on `/data` when you want files back:

```
docker run --rm ghcr.io/jaenster/d2r-cdn -p osib info          # the beta channel
docker run --rm -v $PWD/data:/data ghcr.io/jaenster/d2r-cdn \
  extract 'data:*/excel/*' -o /data/game
DISCORD_WEBHOOK=... docker compose -f docker/docker-compose.yml up -d   # the watcher
```

CI builds it for amd64 and arm64 on every push to main (zig cross-compiles, so neither
arch needs emulation) and tags `:latest`, `:<sha>`, and any `v*` tag. To build the
working tree instead: `docker build -f docker/Dockerfile -t d2r-cdn .`

Compose runs the same image as the channel watcher — see `DEPLOY-synology.md`.

## Scripts

Curl-only equivalents, useful where nothing can be built:

```
scripts/osi-cdn.sh info     # build id, version, cdn hosts
scripts/mirror.sh <dir>     # resumable full mirror of a build
scripts/scrape.sh <dir>     # watch every product channel, capture new builds
```

They predate the CLI and only write to a directory; `mirror` and `watch` cover both
targets and are what the deployments run.

## Format notes

- Content is addressed by MD5: a hash `abcdef…` lives at `<base>/<kind>/ab/cd/abcdef…`.
- Data blobs are BLTE-framed (`N` raw, `Z` zlib, `F` frame, `E` encrypted).
- EKey is the CDN locator; CKey (md5 of the decoded file) is the integrity check.
- D2R's root manifest is text: `path|CKey|platform|basename` per line.
- A range request that starts at EOF comes back as the whole blob with a 200, not a
  416 — resumable downloads have to check the length they got. A bucket never resumes
  (an object is all-or-nothing), so only a directory mirror has to care.

---

Diablo II: Resurrected is a trademark of Blizzard Entertainment. This project is
unaffiliated and ships no game data.

## See also

[**blizzard-legacy-dl**](https://github.com/jaenster/blizzard-legacy-dl) — the same idea for the
legacy games. Diablo II, StarCraft and Warcraft III are still served by the old BitTorrent-stub
downloader, which fetches one numbered file per piece over HTTP rather than anything NGDP, so it
is a separate tool.
