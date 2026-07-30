# d2r-cdn

Fetch and extract Diablo II: Resurrected files from Blizzard's CDN (NGDP/TACT/CASC)
in Zig. No dependencies, no game content included. (`osi` is D2R's product code.)

A library (`tact`) plus a CLI that exposes all of it.

## CLI

```
zig build                      # -> zig-out/bin/d2r-cdn
```

```
d2r-cdn info                                    # build id, version, configs, cdn host
d2r-cdn versions | cdns | bgdl                  # raw version-service tables
d2r-cdn config [build|cdn|<hash>]               # a config blob as text
d2r-cdn archives                                # the data archives of this build
d2r-cdn blob <hash> [--raw]                     # one blob, BLTE-decoded unless --raw
d2r-cdn list [pattern] [--root]                 # install manifest, or the full catalog
d2r-cdn fetch D2R.exe -o ./bin                  # install files (exe/dll), md5-verified
d2r-cdn extract 'data:data/global/excel/*' -o ./out   # game files by root path
d2r-cdn mirror /data/pool [--indices] [--max n] # resumable blob mirror of a build
d2r-cdn watch /data --interval 60 --data        # poll every channel, capture new builds
```

Global options: `-p/--product` (osib=beta, osit=test, …), `-r/--region`, `--cdn-host`,
`--pool <dir>` to read blobs from a local mirror before touching the network,
`--cache` to write what it did fetch back into that pool, `-o/--out`, `-q`.
`d2r-cdn --help` prints the rest.

Extraction is resumable and verified: files already on disk are skipped, and every
decoded file is checked against its CKey.

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

`Cdn` resolves a product's current build (versions → build/cdn config) and exposes the
version service, BLTE decode, the encoding CKey↔EKey map, archive-index lookup, the
install and root manifests, per-file extraction, encryption state (plus the Armadillo
key name a locked channel wants), and blob mirroring. Everything is in `src/tact.zig`;
`example/fetch.zig` is the smallest possible user of it.

## Docker

```
docker build -f docker/Dockerfile -t d2r-cdn .
docker run --rm d2r-cdn info
docker run --rm -v $PWD/data:/data d2r-cdn --pool /data/pool extract -o /data/game
DISCORD_WEBHOOK=... docker compose -f docker/docker-compose.yml up -d   # the watcher
```

The image is the CLI (~28MB, static musl build); compose runs it as the channel
watcher — see `DEPLOY-synology.md`.

## Scripts

Curl-only equivalents, useful where nothing can be built:

```
scripts/osi-cdn.sh info     # build id, version, cdn hosts
scripts/mirror.sh <dir>     # resumable full mirror of a build
scripts/scrape.sh <dir>     # watch every product channel, capture new builds
```

## Format notes

- Content is addressed by MD5: a hash `abcdef…` lives at `<base>/<kind>/ab/cd/abcdef…`.
- Data blobs are BLTE-framed (`N` raw, `Z` zlib, `F` frame, `E` encrypted).
- EKey is the CDN locator; CKey (md5 of the decoded file) is the integrity check.
- D2R's root manifest is text: `path|CKey|platform|basename` per line.

---

Diablo II: Resurrected is a trademark of Blizzard Entertainment. This project is
unaffiliated and ships no game data.
