#!/usr/bin/env bash
# Download one day of MeteoGalicia WRF-ARW 1km history (the FWI meteo inputs)
# for the Galicia area, as a NetCDF file.
#
# Keeps the SAME bbox/grid as scripts/download-fwi.sh so the daily file aligns
# with the existing fwi_* raster tables (no cutline clipping).
#
# Inputs (env):
#   TARGET_DATE   YYYY-MM-DD (required; normally set by galicia-meteo-daily.sh)
#
# Output: INPUT/FWI/galicia/wrf_arw_YYYYMMDD.nc
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

command -v curl >/dev/null 2>&1 || die "required command not found on host: curl"
: "${TARGET_DATE:?Set TARGET_DATE (YYYY-MM-DD)}"

# Galicia WRF window (same grid as the existing fwi_* tables / scripts/download-fwi.sh).
FWI_NORTH="${FWI_NORTH:-44.636}"
FWI_SOUTH="${FWI_SOUTH:-41.348}"
FWI_WEST="${FWI_WEST:--10.293}"
FWI_EAST="${FWI_EAST:--5.749}"

path_day="$(date -u -d "${TARGET_DATE}" '+%Y%m%d')"
time_start="$(date -u -d "${TARGET_DATE} +1 hour" '+%Y-%m-%dT%H:%M:%SZ')"
time_end="$(date -u -d "${TARGET_DATE} +4 days" '+%Y-%m-%dT00:00:00Z')"

out="${REPO_ROOT}/INPUT/FWI/galicia/wrf_arw_${path_day}.nc"
url="https://thredds.meteogalicia.gal/thredds/ncss/grid/modelos/WRF_ARW_1KM_HIST/${path_day}/wrf_arw_det_history_d02_${path_day}_0000.nc4?var=prec&var=mod&var=dir&var=u&var=v&var=temp&var=rh&var=lon&var=lat&north=${FWI_NORTH}&west=${FWI_WEST}&east=${FWI_EAST}&south=${FWI_SOUTH}&horizStride=1&time_start=${time_start}&time_end=${time_end}&accept=netcdf3"

log "Downloading MeteoGalicia WRF for ${REGION} ${TARGET_DATE} -> $(basename "${out}")"
curl -fL --retry 3 -o "${out}" "${url}"
[[ -s "${out}" ]] || die "Download produced no data: ${out}"
log "Meteo download complete: ${out}"
