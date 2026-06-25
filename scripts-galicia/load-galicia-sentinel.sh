#!/usr/bin/env bash
# Load the clipped Galicia Sentinel bands into the existing s2_<band> raster
# tables, tagged with region + acquisition date range.
#
# Reuses the existing whole-Spain tables (per project decision), so the
# alignment/scale/extent raster constraints are dropped first to allow the
# Galicia-clipped (differently-aligned) rasters to be appended. Spain rows are
# left untouched; the two are distinguished by the `region` column.
#
# Inputs (env, set by galicia-sentinel-weekly.sh):
#   DATE_FROM, DATE_TO   YYYY-MM-DD (required)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

: "${DATE_FROM:?Set DATE_FROM (YYYY-MM-DD)}"
: "${DATE_TO:?Set DATE_TO (YYYY-MM-DD)}"

FROM_TOKEN="${DATE_FROM//-/}"
TO_TOKEN="${DATE_TO//-/}"

for band in B04 B08 B8A B11; do
    band_lc="${band,,}"
    table="s2_${band_lc}"
    fname="galicia_${band_lc}_${FROM_TOKEN}_${TO_TOKEN}.tif"
    host_tif="${REPO_ROOT}/INPUT/NDXI/galicia/${fname}"
    [[ -s "${host_tif}" ]] || die "Clipped band missing: ${host_tif} (run download first)"
    require_table "${table}"

    log "Preparing ${table} (drop constraints, add metadata cols, clear prior ${REGION} ${DATE_FROM}..${DATE_TO})"
    psql_in <<SQL
-- Drop all raster constraints (12 booleans = unambiguous overload) so the
-- differently-aligned Galicia raster can be appended alongside the Spain rows.
SELECT DropRasterConstraints('public', '${table}', 'rast',
    TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE);
ALTER TABLE public.${table}
    ADD COLUMN IF NOT EXISTS region    text,
    ADD COLUMN IF NOT EXISTS date_from date,
    ADD COLUMN IF NOT EXISTS date_to   date;
DELETE FROM public.${table}
    WHERE region = '${REGION}'
      AND date_from = DATE '${DATE_FROM}'
      AND date_to   = DATE '${DATE_TO}';
SQL

    log "Appending ${fname} -> public.${table}"
    geotools raster2pgsql -s 4326 -a -F -t 256x256 \
        "/data/INPUT/NDXI/galicia/${fname}" "public.${table}" \
        | psql_in

    log "Tagging new rows + ensuring index on ${table}"
    psql_in <<SQL
UPDATE public.${table}
    SET region = '${REGION}', date_from = DATE '${DATE_FROM}', date_to = DATE '${DATE_TO}'
    WHERE region IS NULL AND filename = '${fname}';
CREATE INDEX IF NOT EXISTS ${table}_rast_gist ON public.${table} USING gist (ST_ConvexHull(rast));
CREATE INDEX IF NOT EXISTS ${table}_region_idx ON public.${table} (region);
SQL
done

log "Sentinel load complete (${REGION} ${DATE_FROM}..${DATE_TO})"
