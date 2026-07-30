#!/usr/bin/env bash
# osi-cdn.sh - talk to Blizzard's modern CDN (NGDP/TACT) for Diablo II: Resurrected.
#
# Pure curl. Resolves the version service, dumps build/cdn configs, lists data
# archives, and fetches raw blobs by content hash. It stops at raw (BLTE-framed)
# bytes - decoding encoding/root/BLTE into named files is a library job (see README).
#
# Env overrides:
#   PRODUCT   TACT product code   (default osi;  osib=beta, osit=test)
#   REGION    region row to use   (default us;   eu, kr, cn)
#   PATCHHOST version service host (default <region>.patch.battle.net)
#   CDNHOST   CDN host             (default: first host from /cdns)
set -euo pipefail

PRODUCT="${PRODUCT:-osi}"
REGION="${REGION:-us}"
PATCHHOST="${PATCHHOST:-${REGION}.patch.battle.net}"
PORT=1119
CURL=(curl -sfL -m 30)

# --- version service ------------------------------------------------------------

vs() { # vs <endpoint>  -> raw text from the patch service
  "${CURL[@]}" "http://${PATCHHOST}:${PORT}/${PRODUCT}/$1"
}

# pick the data row for $REGION from a pipe-table (skips header + ## seqn lines)
row() { awk -F'|' -v r="$REGION" '/^#/||/!/{next} $1==r{print;exit}'; }

resolve() { # sets BUILDCONFIG CDNCONFIG BUILDID VERSNAME from /versions
  local line; line="$(vs versions | row)"
  BUILDCONFIG="$(echo "$line" | cut -d'|' -f2)"
  CDNCONFIG="$(echo "$line" | cut -d'|' -f3)"
  BUILDID="$(echo "$line" | cut -d'|' -f5)"
  VERSNAME="$(echo "$line" | cut -d'|' -f6)"
}

cdnbase() { # echoes http://<host>/<path> from /cdns
  local line; line="$(vs cdns | row)"
  local path host
  path="$(echo "$line" | cut -d'|' -f2)"
  host="${CDNHOST:-$(echo "$line" | cut -d'|' -f3 | awk '{print $1}')}"
  echo "http://${host}/${path}"
}

# hash -> sharded CDN url:  <base>/<kind>/<ab>/<cd>/<hash>
url() { # url <kind> <hash>
  local base; base="$(cdnbase)"
  local h="$2"
  echo "${base}/$1/${h:0:2}/${h:2:2}/${h}"
}

get() { "${CURL[@]}" "$(url "$1" "$2")"; } # get <kind> <hash>

# --- commands -------------------------------------------------------------------

case "${1:-info}" in
  versions) vs versions ;;
  cdns)     vs cdns ;;
  bgdl)     vs bgdl ;;

  config)   get config "$2" ;;
  data)     get data "$2" ;;

  buildconfig) resolve; get config "$BUILDCONFIG" ;;
  cdnconfig)   resolve; get config "$CDNCONFIG" ;;

  archives)
    resolve
    get config "$CDNCONFIG" | grep '^archives =' | sed 's/archives = //' | tr ' ' '\n'
    ;;

  info)
    resolve
    base="$(cdnbase)"
    echo "product     : $PRODUCT   (region $REGION)"
    echo "version     : $VERSNAME  (build $BUILDID)"
    echo "build config: $BUILDCONFIG"
    echo "cdn config  : $CDNCONFIG"
    echo "cdn base    : $base"
    narchives="$(get config "$CDNCONFIG" | grep '^archives =' | sed 's/archives = //' | wc -w | tr -d ' ')"
    echo "archives    : $narchives  (~256MB each)"
    bp="$(get config "$BUILDCONFIG" | grep -E '^build-(product|comments|name)' || true)"
    echo "$bp" | sed 's/^/build       : /'
    ;;

  *)
    echo "usage: $0 {info|versions|cdns|bgdl|buildconfig|cdnconfig|archives|config <hash>|data <hash>}" >&2
    echo "env: PRODUCT=$PRODUCT REGION=$REGION (osib=beta, osit=test; eu/kr/cn regions)" >&2
    exit 2
    ;;
esac
