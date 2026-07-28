#!/usr/bin/env bash
# scrape.sh - watch every D2R product channel and capture any new build the moment
# it appears. Meant to catch accidental internal/dev/staging uploads that get pulled
# fast: on a change it grabs the ~30MB manifest fingerprint (configs + encoding +
# install/download/size + ALL archive indices) so the build is preserved even if the
# version pointer is yanked minutes later.
#
#   ./scrape.sh <dest-dir>              # one scan pass (cron-friendly)
#   INTERVAL=60 ./scrape.sh <dir>       # loop every 60s
#   DATA=1 ./scrape.sh <dir>            # also mirror full 37GB data on a hit
#   DISCORD_WEBHOOK=... ./scrape.sh <dir>
#
# Enumeration is brute-force over HTTP (no /summary there). On a host with raw-TCP
# egress, Ribbit `v1/summary` would additionally reveal brand-new product codes.
set -uo pipefail
export LC_ALL=C

DEST="${1:?usage: scrape.sh <dest-dir>}"
STATE="$DEST/state"; mkdir -p "$STATE"
PATCHHOST="${PATCHHOST:-us.patch.battle.net}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# known D2R codes (wowdev.wiki: retail/test/china/beta/alpha/dev + vendor 1-6) plus
# a brute space to catch any brand-new code Blizzard adds.
BASE_CODES="osi osit osic osib osia osidev osiv1 osiv2 osiv3 osiv4 osiv5 osiv6"
BRUTE="$(for c in {a..z}; do echo "osi$c"; done) $(for n in 1 2 3 4 5 6 7 8 9; do echo "osiv$n osidev$n"; done) osiqa osistage osiptr osiinternal osicert osivendor osidemo osilive osipatch"
PRODUCTS="${PRODUCTS:-$BASE_CODES $BRUTE}"

alert() { # alert <text>
  echo "  >> $1"
  [ -n "${DISCORD_WEBHOOK:-}" ] && curl -sf -H 'Content-Type: application/json' \
    -d "$(printf '{"content":"%s"}' "$1")" "$DISCORD_WEBHOOK" >/dev/null || true
}

scan_once() {
  local seen=""
  for p in $PRODUCTS; do
    case " $seen " in *" $p "*) continue;; esac; seen="$seen $p"
    local V
    V=$(curl -sf -m 8 "http://$PATCHHOST:1119/$p/versions" 2>/dev/null \
        | awk -F'|' '!/!/&&!/^#/&&$2{print;exit}') || continue
    [ -z "$V" ] && continue
    local region bc ver P enc=1
    region=$(echo "$V" | cut -d'|' -f1)
    bc=$(echo "$V" | cut -d'|' -f2)
    ver=$(echo "$V" | cut -d'|' -f6)
    [ -z "$bc" ] && continue
    P=$(curl -sf -m 8 "http://$PATCHHOST:1119/$p/cdns" | awk -F'|' '!/!/&&!/^#/&&$2{print $2;exit}')
    # plaintext vs encrypted: can we read the build config as text?
    curl -sf -m 8 "http://level3.blizzard.com/$P/config/${bc:0:2}/${bc:2:2}/$bc" 2>/dev/null \
      | grep -q 'build-name\|^root' && enc=0
    local tag=ENCRYPTED; [ "$enc" = 0 ] && tag=PLAINTEXT

    # for encrypted channels, learn WHICH key it needs (Armadillo: productconfig
    # carries decryption_key_name). We can't decrypt without it, but we record what
    # to watch for - if that key ever leaks, our captured blobs become readable.
    local keyname=""
    if [ "$enc" = 1 ]; then
      local pc cp
      pc=$(echo "$V" | cut -d'|' -f7)
      cp=$(curl -sf -m 8 "http://$PATCHHOST:1119/$p/cdns" | awk -F'|' '!/!/&&!/^#/&&$5{print $5;exit}')
      [ -z "$cp" ] && cp="tpr/configs/data"
      keyname=$(curl -sf -m 8 "http://level3.blizzard.com/$cp/${pc:0:2}/${pc:2:2}/$pc" 2>/dev/null \
                | grep -oE '"decryption_key_name":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    local keymsg=""; [ -n "$keyname" ] && keymsg=" needs-key=$keyname"

    local last="" lastenc=""
    [ -f "$STATE/$p" ] && last=$(cat "$STATE/$p")
    [ -f "$STATE/$p.enc" ] && lastenc=$(cat "$STATE/$p.enc")

    # THE ALARM: a channel that was encrypted is now readable = likely internal leak.
    if [ "$lastenc" = 1 ] && [ "$enc" = 0 ]; then
      alert "@@@ D2R $p WENT PLAINTEXT (was encrypted) - $ver - POSSIBLE INTERNAL LEAK @@@"
    fi
    echo "$enc" > "$STATE/$p.enc"

    local pool="$DEST/pool"; mkdir -p "$pool"

    # new build detected (fast - just the version check above) -> alert + record it.
    if [ "$bc" != "$last" ]; then
      if [ -z "$last" ]; then alert "D2R NEW PRODUCT: $p  $ver  [$tag]$keymsg  ($region)"
      else alert "D2R $p NEW BUILD: $ver  [$tag]$keymsg  ($region)"; fi
      mkdir -p "$DEST/builds/$p"
      printf '{"product":"%s","version":"%s","region":"%s","build_config":"%s","encrypted":%s,"key_name":"%s","ts":"%s"}\n' \
        "$p" "$ver" "$region" "$bc" "$([ "$enc" = 1 ] && echo true || echo false)" "$keyname" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$DEST/builds/$p/$ver.json"
      echo "$bc" > "$STATE/$p"
    fi

    # Download the whole build (configs + indices + data) into the pool. ONE download
    # at a time across ALL products (a single global lock), in the background, so
    # nothing competes for the uplink and the poll keeps detecting. Plaintext only
    # (encrypted channels have no readable archive list). Retries each scan until
    # $STATE/$p.data == this build. mirror.sh is resumable.
    if [ -n "${DATA:-}" ] && [ "$enc" = 0 ]; then
      local ddone=""; [ -f "$STATE/$p.data" ] && ddone=$(cat "$STATE/$p.data")
      if [ "$bc" != "$ddone" ] && mkdir "$pool/.lock" 2>/dev/null; then
        alert "D2R $p DOWNLOADING $ver ..."
        ( if PRODUCT="$p" REGION="$region" CDNHOST=level3.blizzard.com "$HERE/mirror.sh" "$pool" >>"$pool/data.log" 2>&1; then
            echo "$bc" > "$STATE/$p.data"
            alert "D2R $p DONE $ver (pool $(du -sh "$pool" 2>/dev/null | cut -f1))"
          else
            alert "D2R $p download FAILED $ver (will retry)"
          fi
          rmdir "$pool/.lock" 2>/dev/null ) &
      fi
    fi
  done
}

rm -rf "$DEST/pool/.lock" "$DEST/pool/.lock-"* 2>/dev/null  # clear stale download lock from a prior run
echo "scrape $(echo "$PRODUCTS" | wc -w | tr -d ' ') candidate products -> $DEST"
if [ -n "${INTERVAL:-}" ]; then
  while true; do echo "--- scan $(date -u +%H:%M:%S) ---"; scan_once; sleep "$INTERVAL"; done
else
  scan_once
fi
