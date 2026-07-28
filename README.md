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

Or poke around by hand with `curl`:

```
./osi-cdn.sh info          # build, version, cdn hosts
./osi-cdn.sh archives      # list data archives
./osi-cdn.sh data <hash>   # download a blob
```

## How it works

`versions → build/cdn config → encoding (CKey↔EKey) → .index (EKey→archive+offset)
→ byte-range fetch → BLTE decode`.

The details (BLTE framing, the `.index` binary layout, the EKey-is-a-locator
gotcha) live as comments in [`tact.zig`](tact.zig).

---

*Metadata client only; ships no game data. D2R is a trademark of Blizzard
Entertainment; unaffiliated.*
