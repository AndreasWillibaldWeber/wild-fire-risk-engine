#!/usr/bin/env bash
# Daily Galicia meteo refresh (cron entrypoint).
#
# Downloads one day of MeteoGalicia WRF and loads it into the fwi_* tables
# tagged with region + fdate.
#
# Usage:
#   scripts-galicia/galicia-meteo-daily.sh                 # yesterday (UTC)
#   scripts-galicia/galicia-meteo-daily.sh 2026-06-23      # explicit date
#   TARGET_DATE=2026-06-23 scripts-galicia/galicia-meteo-daily.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Date precedence: $1 > $TARGET_DATE > yesterday (UTC).
TARGET_DATE="${1:-${TARGET_DATE:-$(date -u -d 'yesterday' '+%Y-%m-%d')}}"
export TARGET_DATE

log "=== Daily meteo refresh: ${REGION} ${TARGET_DATE} ==="
"${GALICIA_DIR}/download-galicia-meteo.sh"
"${GALICIA_DIR}/load-galicia-meteo.sh"
log "=== Daily meteo refresh done ==="
