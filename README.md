# d2r-cdn

How Diablo II: Resurrected is distributed over Blizzard's modern content-delivery
system, and how to talk to it yourself with nothing but `curl`.

This documents the protocol (NGDP / TACT / CASC) and the D2R-specific coordinates.
It does not distribute, mirror, or decrypt any game content - every value shown
here is public distribution metadata (build strings and content hashes) served
openly by Blizzard's version service and CDN.

Classic Diablo II (1.14d and earlier) does NOT use this system - it stays on the
legacy BNFTP file service. The two are complementary, not overlapping.

## The layers

Blizzard's stack has three named pieces:

- NGDP (Next Generation Distribution Pipeline) - the umbrella.
- TACT (The Application/Archive Content Toolkit) - the on-CDN format: config
  files, archives, indices, and the BLTE block framing.
- CASC (Content Addressable Storage Container) - the local installed-game store.
  For fetching from the CDN you only care about TACT.

Everything on the CDN is addressed by content hash (MD5, 16 bytes / 32 hex chars).
A hash `abcdef...` lives at `<path>/<ab>/<cd>/abcdef...` - the first two byte-pairs
shard the directory tree.

## Products

D2R ships under these TACT product codes:

| code | what |
|-|-|
| `osi` | D2R retail (live) |
| `osib` | D2R beta |
| `osit` | D2R test/PTR |

Internal build metadata calls the game **Fenway** (`build-product = Fenway`),
stream `//diablo2_stream`.

## Step 1 - the version service

Two transports, same data:

- Ribbit over TCP: connect to `us.version.battle.net:1119`, send `v1/products/osi/versions\n`, read a MIME message.
- HTTP on the same port (simpler): `http://us.patch.battle.net:1119/osi/versions`

Regions: `us`, `eu`, `kr`, `cn` (each has its own patch host, e.g. `eu.patch.battle.net`).

Useful endpoints (append to `.../osi/`):

| endpoint | returns |
|-|-|
| `versions` | build-config + cdn-config hashes per region + BuildId |
| `cdns` | CDN hosts + path per region |
| `bgdl` | background-download config (may be empty) |
| `blobs` / `blob/game` | product install/launch config blobs |

### versions

```
GET http://us.patch.battle.net:1119/osi/versions

Region!STRING:0|BuildConfig!HEX:16|CDNConfig!HEX:16|KeyRing!HEX:16|BuildId!DEC:4|VersionsName!String:0|ProductConfig!HEX:16
## seqn = 3758661
us|3afa9806f33475daee9b317a21d55d09|68ffefcce9175faac284daab4f0b725f||92777|3.2.92777|e5d0a3feb55588a5da2ede452171d0fc
```

Format notes:

- First line is a header: `Name!TYPE:width` columns, pipe-delimited.
- `## seqn = N` is a monotonic sequence number (cache-busting).
- One data row per region.
- Empty `KeyRing` field means this build needs no extra TACT decryption keys - a
  convenience; many WoW builds do require them.

From the `us` row you get:

- BuildConfig = `3afa9806f33475daee9b317a21d55d09`
- CDNConfig = `68ffefcce9175faac284daab4f0b725f`

### cdns

```
GET http://us.patch.battle.net:1119/osi/cdns

Name!STRING:0|Path!STRING:0|Hosts!STRING:0|Servers!STRING:0|ConfigPath!STRING:0
us|tpr/osi|level3.blizzard.com us.cdn.blizzard.com|...|tpr/configs/data
```

- Path = `tpr/osi` - the base path for `config/`, `data/`, `patch/`.
- Hosts = space-separated CDN hosts. `level3.blizzard.com` is the plain-HTTP
  Level3 mirror; `*.cdn.blizzard.com` are the fastly/edge mirrors.

So the CDN base URL is: `http://level3.blizzard.com/tpr/osi`

## Step 2 - config files

Config files live under `<base>/config/<ab>/<cd>/<hash>` and are plain text.

### build config

```
GET http://level3.blizzard.com/tpr/osi/config/3a/fa/3afa9806f33475daee9b317a21d55d09

root = 14e9f96b033198cd604b7265b58f9611
install = <ckey> <ekey>
install-size = 350 376
download = <ckey> <ekey>
encoding = <ckey> <ekey>
encoding-size = 10778382 10778546
size = <ckey> <ekey>
patch = ...
build-name = 92777
build-uid = osi
build-product = Fenway
build-comments = 3.2.0 RC 5 ...
```

Each system manifest is listed as `CKey EKey` (content key then encoding key) plus
a `*-size` line giving `decoded encoded` byte sizes. The manifests:

| field | what it maps |
|-|-|
| `root` | filename / FileDataID -> CKey (the file catalog) |
| `encoding` | CKey <-> EKey (how to turn a content hash into a downloadable one) |
| `install` | files the installer must lay down first |
| `download` | priority/order hints for streaming installs |
| `size` | per-file installed sizes |

### cdn config

```
GET http://level3.blizzard.com/tpr/osi/config/68/ff/68ffefcce9175faac284daab4f0b725f

archives = <hash> <hash> ...        # ~146 data-archive indices
archive-group = <hash>              # merged index over all archives
patch-archives = <hash> ...         # ~7 patch archives
file-index = <hash>                 # loose-file index
```

`archives` is the list of ~256 MB data archives. Each archive `H` has a companion
index at `data/<ab>/<cd>/H.index` mapping the EKeys packed inside it to
(offset, size). `archive-group` is a single merged index over all of them.

## Step 3 - fetching bytes

Two ways a file reaches you:

1. Loose: small/standalone files sit directly at `data/<ab>/<cd>/<ekey>`.
2. Archived: most files are packed into a `~256MB` archive. Look the EKey up in an
   archive `.index` to get (archive-hash, offset, length), then HTTP range-request
   that slice: `curl -r offset-offset+len-1 <base>/data/<ab>/<cd>/<archive>`.

Either way the bytes you get are **BLTE**-framed:

```
$ curl -s -r 0-7 <base>/data/00/54/005402ecf8a897d68ffd21033c126c6a | xxd
00000000: 424c 5445 0000 021c                      BLTE....
```

A BLTE file is a header (chunk table) followed by chunks, each with a 1-byte mode:

| mode | meaning |
|-|-|
| `N` | not compressed, raw |
| `Z` | zlib/deflate |
| `4` | frame (recursive BLTE) |
| `E` | encrypted (Salsa20; needs a TACT key by keyname - not needed for empty-KeyRing builds) |

Decode BLTE -> you have the raw file content.

## Full resolution flow

```
versions            -> BuildConfig, CDNConfig hashes
  build config      -> root, encoding, install (CKey+EKey each)
  cdn config        -> archives[], archive-group, file-index
encoding manifest   -> CKey -> EKey lookups
root manifest       -> "data/global/excel/..." (or FileDataID) -> CKey
archive .index      -> EKey -> (archive, offset, length)
range GET + BLTE    -> raw file bytes
```

Only steps 1-2 are needed to enumerate what a build contains; steps 3+ (encoding,
root, BLTE) are needed to pull a specific named file, and are where a real library
earns its keep.

### Gotcha: EKey is a locator, not a checksum of the blob

Intuition says the file served at `data/<ab>/<cd>/<EKey>` should md5 to `EKey`. It
does NOT. Verified on live D2R: the encoding blob at `data/b3/d7/b3d7bdad...` md5s
to `c3db7fc7...`, not its EKey. Config files ARE content-addressed (a build config
md5s to its own name), but BLTE data blobs are not addressed by md5-of-blob.

The real integrity check is on the DECODED side: **CKey = md5 of the decoded
file**. Fetch by EKey (the locator), BLTE-decode, then `md5(decoded) == CKey`. This
is confirmed in `tact.zig`: the decoded encoding table md5s to exactly the CKey
listed in the build config. So treat EKey as an opaque address and verify with CKey.

## The reference tool

`osi-cdn.sh` does everything reachable with pure `curl` - resolve the version
service, dump the configs, list archives, fetch a blob by hash, and hexdump the
BLTE header:

```
./osi-cdn.sh versions            # raw versions table
./osi-cdn.sh cdns                # raw cdns table
./osi-cdn.sh buildconfig         # resolve + print build config
./osi-cdn.sh cdnconfig           # resolve + print cdn config
./osi-cdn.sh archives            # list data-archive hashes
./osi-cdn.sh config <hash>       # GET a config blob
./osi-cdn.sh data   <hash>       # GET a data blob (raw BLTE)
./osi-cdn.sh info                # one-shot summary (build id, name, hosts)

# point it at beta / another region:
PRODUCT=osib REGION=eu ./osi-cdn.sh info
```

It intentionally stops at raw blobs - decoding encoding/root/BLTE is a library job.

## The native fetcher (tact.zig)

`tact.zig` is a from-scratch Zig 0.16 client (pure std: `std.http.Client`,
`std.compress.flate`, `std.crypto.hash.Md5` - no external deps) that goes all the
way to real file bytes. Run it:

```
zig run tact.zig
```

It, against the live `osi` product:

- resolves versions -> build/cdn config,
- fetches the encoding manifest, BLTE-decodes it, and verifies `md5(decoded) == CKey`,
- parses a data archive's `.index` (EKey -> size, offset within the archive),
- byte-range-fetches the smallest file out of that ~256MB archive and BLTE-decodes it.

Sample run:

```
D2R 3.2.92777 (build 92777)   cdn http://level3.blizzard.com/tpr/osi
cdn config: 146 data archives (~256MB each)
encoding  CKey=6aef7e01...  EKey=b3d7bdad...  decoded-size 10778382
BLTE-decoded: 10778382 bytes, magic EN
md5(decoded)=6aef7e01630b49301d82ad1d88bd0e24  == CKey? true
archive 005402ec....index: 489 entries, key=16 size=4 off=4 bytes/page=4096
smallest file: EKey=a833783f...  offset=268434804  size=640  -> range-fetched 640 bytes
BLTE-decoded file: 780 bytes
```

### The `.index` binary format (per-archive)

Each `<archive>.index` is 4096-byte pages of sorted entries, then a TOC, then a
28-byte footer. Footer fields (from the end): `blockSizeKB`, `offsetBytes`,
`sizeBytes`, `keySizeBytes`, `checksumSize`, then `numElements` (uint32 LE). Each
entry is `EKey[keySize] | size[sizeBytes] BE | offset[offsetBytes] BE`, sorted by
EKey (so files are scattered by offset). For D2R: page 4096, key 16, size 4, off 4
-> 24-byte entries, 170 per page. The offset/size point straight into the archive
blob (offset 0, 1225478, 2337190 ... are all real BLTE starts - verified).

## Going further - existing decoders

Don't reimplement BLTE + encoding + root by hand unless you want to. Mature tools:

- CASCLib (Ladislav Zezula) - C++, reads both online (TACT) and installed (CASC).
- TACT.Net / BuildBackup - C#, full online pipeline incl. archive assembly.
- keg (Ribbit/TACT client) and casc-tools - Go.
- blizzget (d07RiV) - compact C++ NGDP downloader; its `ngdp.cpp` (BLTE decode,
  encoding table, index-entry layout) is a clear, readable reference.
- wowdev.wiki - the canonical protocol reference (TACT, CASC, BLTE, Ribbit pages).

## Note

This repository is documentation and a metadata client. It ships no Blizzard game
data and performs no decryption of protected content. Diablo II: Resurrected is a
trademark of Blizzard Entertainment; this project is unaffiliated.
