#!/usr/bin/env bash
# Load one day of Galicia WRF meteo into the existing fwi_<var> raster tables,
# one table per NetCDF variable, tagged with region + source date (fdate).
#
# Mirrors scripts/load-fwi.sh (subdataset -> table, date parsed from filename),
# but appends a single day and adds the region metadata. Raster constraints are
# dropped first so appends never fail on srid/alignment differences; rows are
# distinguished by region/fdate.
#
# Inputs (env):
#   TARGET_DATE   YYYY-MM-DD (required)
#   SRID          override raster SRID (default 4326)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

: "${TARGET_DATE:?Set TARGET_DATE (YYYY-MM-DD)}"
SRID="${SRID:-4326}"

path_day="$(date -u -d "${TARGET_DATE}" '+%Y%m%d')"
nc_container="/data/INPUT/FWI/galicia/wrf_arw_${path_day}.nc"
nc_host="${REPO_ROOT}/INPUT/FWI/galicia/wrf_arw_${path_day}.nc"
[[ -s "${nc_host}" ]] || die "Meteo file missing: ${nc_host} (run download first)"

# Discover the data variables exposed as GDAL subdatasets, e.g.
#   SUBDATASET_1_NAME=NETCDF:"/data/.../wrf_arw_20260623.nc":temp
mapfile -t subs < <(geotools gdalinfo "${nc_container}" 2>/dev/null \
    | grep -oE 'SUBDATASET_[0-9]+_NAME=.*' | cut -d= -f2-)
[[ "${#subs[@]}" -gt 0 ]] || die "No NetCDF subdatasets found in ${nc_host}"

for sd in "${subs[@]}"; do
    sd="${sd%$'\r'}"
    var="$(printf '%s' "${sd}" | sed -E 's/.*:([A-Za-z0-9_]+)$/\1/')"
    var_lc="${var,,}"
    table="fwi_${var_lc}"

    # Skip pure coordinate variables if present as subdatasets.
    case "${var_lc}" in lon|lat|longitude|latitude|x|y) continue ;; esac

    log "Preparing ${table} (drop constraints, add cols, clear prior ${REGION} ${TARGET_DATE})"
    psql_in <<SQL
-- Drop all raster constraints (12 booleans = unambiguous overload) so daily
-- appends never fail on srid/alignment differences.
SELECT DropRasterConstraints('public', '${table}', 'rast',
    TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE);
ALTER TABLE public.${table}
    ADD COLUMN IF NOT EXISTS fdate  date,
    ADD COLUMN IF NOT EXISTS region text;
DELETE FROM public.${table}
    WHERE region = '${REGION}' AND fdate = DATE '${TARGET_DATE}';
SQL

    log "Appending ${var} (${path_day}) -> public.${table}"
    geotools raster2pgsql -s "${SRID}" -a -F -t 256x256 "${sd}" "public.${table}" \
        | psql_in

    log "Tagging new rows + ensuring indexes on ${table}"
    psql_in <<SQL
UPDATE public.${table}
    SET fdate  = to_date(substring(filename from '[0-9]{8}'), 'YYYYMMDD'),
        region = '${REGION}'
    WHERE filename LIKE '%${path_day}%' AND region IS DISTINCT FROM '${REGION}';
CREATE INDEX IF NOT EXISTS ${table}_rast_gist ON public.${table} USING gist (ST_ConvexHull(rast));
CREATE INDEX IF NOT EXISTS ${table}_fdate_idx ON public.${table} (fdate);
CREATE INDEX IF NOT EXISTS ${table}_region_idx ON public.${table} (region);
SQL
done

log "Meteo load complete (${REGION} ${TARGET_DATE})"
