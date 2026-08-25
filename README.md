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
```

Options worth knowing (`--help` has the rest):

- `-p osib` / `-r eu` — another product (osib=beta, osit=test) or region.
- `--pool <dir>` — read blobs from a local mirror before touching the network.
- `--cache` — write whatever it did fetch back into that pool.

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

`Cdn` resolves a product's current build (versions → build/cdn config); everything
after that is pulled on demand and cached until `close`:

- the version service, and the raw config/data blobs behind it
- BLTE decode and the encoding CKey↔EKey map
- the install and root manifests, and archive-index lookup for either
- per-file extraction by CKey, install name or root path
- whether a channel is encrypted, and which Armadillo key it wants
- blob mirroring into a local pool, resumable

It is all in `src/tact.zig`. `example/fetch.zig` is the smallest thing that uses it.

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

## Format notes

- Content is addressed by MD5: a hash `abcdef…` lives at `<base>/<kind>/ab/cd/abcdef…`.
- Data blobs are BLTE-framed (`N` raw, `Z` zlib, `F` frame, `E` encrypted).
- EKey is the CDN locator; CKey (md5 of the decoded file) is the integrity check.
- D2R's root manifest is text: `path|CKey|platform|basename` per line.
- A range request that starts at EOF comes back as the whole blob with a 200, not a
  416 — resumable downloads have to check the length they got.

---

Diablo II: Resurrected is a trademark of Blizzard Entertainment. This project is
unaffiliated and ships no game data.

## See also

[**blizzard-legacy-dl**](https://github.com/jaenster/blizzard-legacy-dl) — the same idea for the
legacy games. Diablo II, StarCraft and Warcraft III are still served by the old BitTorrent-stub
downloader, which fetches one numbered file per piece over HTTP rather than anything NGDP, so it
is a separate tool.
