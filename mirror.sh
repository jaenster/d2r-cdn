#!/usr/bin/env bash
# mirror.sh - download the full D2R CDN blob set to a directory. Raw + resumable:
# re-running skips files already complete and resumes partial ones. This mirrors
# the CDN byte-for-byte (configs, system files, all data archives + indices); it
# does NOT extract named files (that needs root/encoding - see tact.zig).
#
#   ./mirror.sh <dest-dir>            # full mirror (~37GB)
#   MAX=1 ./mirror.sh /tmp/d2r        # just the first archive (test)
#   PRODUCT=osib REGION=eu ./mirror.sh <dir>
set -euo pipefail
export LC_ALL=C  # byte-oriented awk; CDN text can carry stray high bytes

DEST="${1:?usage: mirror.sh <dest-dir>  (env: PRODUCT REGION MAX)}"
PRODUCT="${PRODUCT:-osi}"; REGION="${REGION:-us}"
# Always query a reachable patch host; REGION only selects which row we use. (Building
# the host from REGION breaks cn -> cn.patch.battle.net is unreachable outside China.)
PATCHHOST="${PATCHHOST:-us.patch.battle.net}"
PATCH="http://${PATCHHOST}:1119/${PRODUCT}"
row() { awk -F'|' -v r="$REGION" '/^#/||/!/{next} $1==r{print;exit}'; }

first() { awk -F'|' '/^#/||/!/{next} NF>3{print;exit}'; }  # first data row, any region
VR=$(curl -sf "$PATCH/versions"); V=$(echo "$VR" | row); [ -z "$V" ] && V=$(echo "$VR" | first)
CR=$(curl -sf "$PATCH/cdns"); C=$(echo "$CR" | row); [ -z "$C" ] && C=$(echo "$CR" | first)
BC=$(echo "$V" | cut -d'|' -f2); CC=$(echo "$V" | cut -d'|' -f3)
CPATH=$(echo "$C" | cut -d'|' -f2); HOST="${CDNHOST:-$(echo "$C" | cut -d'|' -f3 | awk '{print $1}')}"
BASE="http://$HOST/$CPATH"
echo "mirror $PRODUCT/$REGION build $(echo "$V" | cut -d'|' -f5)  ->  $DEST"
echo "cdn $BASE"

dl() { # dl <kind> <hash> [ext]
  local kind=$1 h=$2 ext=${3:-}
  local sub="${h:0:2}/${h:2:2}"
  local dir="$DEST/$kind/$sub" out url
  mkdir -p "$dir"; out="$dir/$h$ext"; url="$BASE/$kind/$sub/$h$ext"
  local remote
  remote=$(curl -sfI "$url" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r\n')
  if [ -f "$out" ] && [ -n "$remote" ] && [ "$(wc -c <"$out")" = "$remote" ]; then printf 's'; return; fi
  curl -sfL -C - -o "$out" "$url" && printf '.' || printf 'X'
}

echo -n "configs: "; dl config "$BC"; dl config "$CC"; echo
echo -n "system files: "
BUILD=$(curl -sf "$BASE/config/${BC:0:2}/${BC:2:2}/$BC")
for k in encoding root install download size; do
  ek=$(echo "$BUILD" | awk -v k="$k" '$1==k{print $4}')
  [ -n "$ek" ] && dl data "$ek"
done
echo

CDN=$(curl -sf "$BASE/config/${CC:0:2}/${CC:2:2}/$CC")
ARCHES=$(echo "$CDN" | awk '/^archives =/{for(i=3;i<=NF;i++)print $i}')
TOTAL=$(echo "$ARCHES" | wc -w | tr -d ' ')
echo "archives: $TOTAL total  (s=skip . =downloaded X=fail)"
i=0; MAX="${MAX:-0}"
for a in $ARCHES; do
  dl data "$a" .index
  [ -z "${MANIFESTS:-}" ] && dl data "$a"   # MANIFESTS=1 -> indices only, skip 256MB blobs
  i=$((i+1))
  [ $((i % 10)) -eq 0 ] && printf ' [%d/%d]\n' "$i" "$TOTAL"
  [ "$MAX" != 0 ] && [ "$i" -ge "$MAX" ] && break
done
echo; echo "done: $(du -sh "$DEST" 2>/dev/null | cut -f1) in $DEST"
