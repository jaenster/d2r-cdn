# d2r-cdn

Fetch and extract Diablo II: Resurrected files from Blizzard's CDN (NGDP/TACT/CASC)
in Zig. No dependencies, no game content included. (`osi` is D2R's product code.)

## Library

```
zig fetch --save git+https://github.com/jaenster/d2r-cdn
```

```zig
const tact = @import("tact");

var cdn = try tact.Cdn.open(gpa, io, "osi", "us"); // resolve the current build
defer cdn.close();
const exe = try cdn.extractInstall("D2R.exe");     // decoded file bytes
```

`Cdn` resolves a product's current build (versions → build/cdn config) and exposes
BLTE decode, the encoding CKey↔EKey map, archive-index lookup, and per-file
extraction. Everything is in `src/tact.zig`.

## Build

```
zig build            # library + the d2r-fetch example
zig build test
./zig-out/bin/d2r-fetch
```

## Tools

```
zig run tools/list.zig      # list every file in a build
zig run tools/extract.zig   # extract a full game tree from a local mirror
```

## Scripts

```
scripts/osi-cdn.sh info     # build id, version, cdn hosts (curl only)
scripts/mirror.sh <dir>     # resumable full mirror of a build
scripts/scrape.sh <dir>     # watch every product channel, capture new builds
```

The scraper also runs as a container — see `docker/` and `DEPLOY-synology.md`.

## Format notes

- Content is addressed by MD5: a hash `abcdef…` lives at `<base>/<kind>/ab/cd/abcdef…`.
- Data blobs are BLTE-framed (`N` raw, `Z` zlib, `F` frame, `E` encrypted).
- EKey is the CDN locator; CKey (md5 of the decoded file) is the integrity check.

---

Diablo II: Resurrected is a trademark of Blizzard Entertainment. This project is
unaffiliated and ships no game data.
