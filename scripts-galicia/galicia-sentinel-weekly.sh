#!/usr/bin/env bash
# Weekly Galicia Sentinel-2 refresh (cron entrypoint).
#
# Computes the past 7-day acquisition window, exports the AOI, downloads +
# clips B04/B08/B8A/B11, and loads them into the s2_* tables tagged with the
# region and date range.
#
# Usage:
#   scripts-galicia/galicia-sentinel-weekly.sh                # last 7 days
#   DATE_FROM=2026-06-16 DATE_TO=2026-06-23 scripts-galicia/galicia-sentinel-weekly.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Default window: [today-7d, today] (UTC).
DATE_TO="${DATE_TO:-$(date -u '+%Y-%m-%d')}"
DATE_FROM="${DATE_FROM:-$(date -u -d "${DATE_TO} -7 days" '+%Y-%m-%d')}"
export DATE_FROM DATE_TO
export FROM="${FROM:-${DATE_FROM}T00:00:00Z}"
export TO="${TO:-${DATE_TO}T23:59:59Z}"

log "=== Weekly Sentinel refresh: ${REGION} ${DATE_FROM}..${DATE_TO} ==="
"${GALICIA_DIR}/export-galicia-aoi.sh"
"${GALICIA_DIR}/download-galicia-sentinel.sh"
"${GALICIA_DIR}/load-galicia-sentinel.sh"
log "=== Weekly Sentinel refresh done ==="
