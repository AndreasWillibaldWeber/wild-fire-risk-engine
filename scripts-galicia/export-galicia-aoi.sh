#!/usr/bin/env bash
# Export the Galicia region polygon (and its bbox) from PostGIS.
#
# Produces:
#   INPUT/AOI/galicia.geojson  -- WGS84 polygon, used as a gdalwarp cutline
#   INPUT/AOI/galicia.bbox     -- MIN_LON/MIN_LAT/MAX_LON/MAX_LAT, sourced by downloads
#
# Idempotent: safe to re-run; always refreshes from the DB boundary table.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

AOI_BBOX_FILE="${REPO_ROOT}/INPUT/AOI/galicia.bbox"

log "Exporting ${ACOM_NAME} polygon -> ${AOI_GEOJSON_HOST}"
geotools ogr2ogr -f GeoJSON "${AOI_GEOJSON_CONTAINER}" \
    PG:"host=${PGHOST_IN} dbname=${PGDATABASE} user=${PGUSER} password=${PGPASSWORD}" \
    -sql "SELECT ST_Union(geom) AS geom FROM spain_autonomous_communities WHERE acom_name='${ACOM_NAME}'" \
    -nln galicia_aoi -nlt PROMOTE_TO_MULTI -lco RFC7946=YES -overwrite

[[ -s "${AOI_GEOJSON_HOST}" ]] || die "AOI export produced no file at ${AOI_GEOJSON_HOST}"

log "Computing ${ACOM_NAME} bbox"
extent="$(psql_in -tA -c \
    "SELECT ST_XMin(e),ST_YMin(e),ST_XMax(e),ST_YMax(e)
       FROM (SELECT ST_Extent(geom) e
               FROM spain_autonomous_communities
              WHERE acom_name='${ACOM_NAME}') s;")"

IFS='|' read -r MIN_LON MIN_LAT MAX_LON MAX_LAT <<<"${extent}"
[[ -n "${MAX_LAT:-}" ]] || die "Could not derive bbox for ${ACOM_NAME} (got '${extent}')"

cat > "${AOI_BBOX_FILE}" <<EOF
MIN_LON=${MIN_LON}
MIN_LAT=${MIN_LAT}
MAX_LON=${MAX_LON}
MAX_LAT=${MAX_LAT}
EOF

log "AOI ready: bbox=[${MIN_LON}, ${MIN_LAT}, ${MAX_LON}, ${MAX_LAT}]"
