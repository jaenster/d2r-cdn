# d2r-cdn

Fetch Diablo II: Resurrected files straight from Blizzard's CDN (NGDP/TACT), in
pure Zig — no deps, no game content bundled.

## Run it

```
zig run tact.zig
```

Resolves the live D2R build, downloads a real file from a data archive, and
BLTE-decodes it:

```
D2R 3.2.92777 (build 92777)
encoding CKey=6aef7e01...  md5(decoded)==CKey? true
archive file: EKey=a833783f...  640 bytes -> BLTE-decoded 780 bytes
```

List every file in the build (install + root catalog, no big download):

```
zig run list.zig 2>/dev/null | sort -u   # ~175k paths
```

Mirror the whole thing (raw blobs, resumable, ~37GB):

```
./mirror.sh <dir>          # re-run to resume; skips complete files
MAX=1 ./mirror.sh /tmp/d2r # just the first archive (test)
```

Or poke around by hand with `curl`:

```
./osi-cdn.sh info          # build, version, cdn hosts
./osi-cdn.sh archives      # list data archives
./osi-cdn.sh data <hash>   # download a blob
```

## How it works

`versions -> build/cdn config -> encoding (CKey<->EKey) -> .index (EKey->archive+offset)
-> byte-range fetch -> BLTE decode`.

The details (BLTE framing, the `.index` binary layout, the EKey-is-a-locator
gotcha) live as comments in [`tact.zig`](tact.zig).

---

*Metadata client only; ships no game data. D2R is a trademark of Blizzard
Entertainment; unaffiliated.*
