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

    local last="" lastenc=""
    [ -f "$STATE/$p" ] && last=$(cat "$STATE/$p")
    [ -f "$STATE/$p.enc" ] && lastenc=$(cat "$STATE/$p.enc")

    # THE ALARM: a channel that was encrypted is now readable = likely internal leak.
    if [ "$lastenc" = 1 ] && [ "$enc" = 0 ]; then
      alert "@@@ D2R $p WENT PLAINTEXT (was encrypted) - $ver - POSSIBLE INTERNAL LEAK @@@"
    fi
    echo "$enc" > "$STATE/$p.enc"

    if [ "$bc" = "$last" ]; then continue; fi
    if [ -z "$last" ]; then alert "D2R NEW PRODUCT: $p  $ver  [$tag]  ($region)"
    else alert "D2R $p NEW BUILD: $ver  [$tag]  ($region)"; fi

    local capdir="$DEST/manifests/$p/$ver"; mkdir -p "$capdir"
    [ -n "${DATA:-}" ] && PRODUCT="$p" REGION="$region" CDNHOST=level3.blizzard.com "$HERE/mirror.sh" "$DEST/data/$p" >/dev/null 2>&1
    if MANIFESTS=1 PRODUCT="$p" REGION="$region" CDNHOST=level3.blizzard.com "$HERE/mirror.sh" "$capdir" >"$capdir/capture.log" 2>&1; then
      echo "$bc" > "$STATE/$p"
      echo "     captured -> $capdir ($(du -sh "$capdir" 2>/dev/null | cut -f1)) [$tag]"
    else
      alert "D2R $p CAPTURE FAILED for $ver (will retry)"
    fi
  done
}

echo "scrape $(echo "$PRODUCTS" | wc -w | tr -d ' ') candidate products -> $DEST"
if [ -n "${INTERVAL:-}" ]; then
  while true; do echo "--- scan $(date -u +%H:%M:%S) ---"; scan_once; sleep "$INTERVAL"; done
else
  scan_once
fi
