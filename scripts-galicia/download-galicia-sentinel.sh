#!/usr/bin/env bash
# Download Sentinel-2 L2A B04/B08/B8A/B11 for the Galicia bbox from the
# Copernicus Sentinel Hub Process API, then clip each band to the exact Galicia
# polygon (gdalwarp cutline in the geotools container).
#
# Inputs (env, normally set by galicia-sentinel-weekly.sh):
#   FROM, TO         ISO timestamps for the acquisition window (required)
#   DATE_FROM, DATE_TO   YYYY-MM-DD (required; used for output filenames/metadata)
#   SH_CLIENT_ID/SECRET or ACCESS_TOKEN  (Copernicus OAuth)
# Bbox comes from INPUT/AOI/galicia.bbox (export-galicia-aoi.sh) unless
# MIN_LON/MIN_LAT/MAX_LON/MAX_LAT are set in the environment.
#
# Output: INPUT/NDXI/galicia/galicia_<band>_<YYYYMMDD>_<YYYYMMDD>.tif (clipped)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

for cmd in curl jq tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found on host: $cmd"
done

: "${FROM:?Set FROM (ISO timestamp)}"
: "${TO:?Set TO (ISO timestamp)}"
: "${DATE_FROM:?Set DATE_FROM (YYYY-MM-DD)}"
: "${DATE_TO:?Set DATE_TO (YYYY-MM-DD)}"

# Bbox: prefer env override, else the cached AOI bbox file.
AOI_BBOX_FILE="${REPO_ROOT}/INPUT/AOI/galicia.bbox"
if [[ -z "${MIN_LON:-}" ]]; then
    [[ -f "${AOI_BBOX_FILE}" ]] || die "Missing ${AOI_BBOX_FILE}; run export-galicia-aoi.sh first."
    # shellcheck disable=SC1090
    source "${AOI_BBOX_FILE}"
fi
[[ -s "${AOI_GEOJSON_HOST}" ]] || die "Missing ${AOI_GEOJSON_HOST}; run export-galicia-aoi.sh first."

MAX_CLOUD="${MAX_CLOUD:-30}"
WIDTH="${WIDTH:-2048}"
HEIGHT="${HEIGHT:-2048}"
MOSAICKING_ORDER="${MOSAICKING_ORDER:-mostRecent}"

RAW_DIR="${REPO_ROOT}/INPUT/NDXI/galicia/raw"
mkdir -p "${RAW_DIR}"
FROM_TOKEN="${DATE_FROM//-/}"
TO_TOKEN="${DATE_TO//-/}"

TOKEN_URL="https://identity.dataspace.copernicus.eu/auth/realms/CDSE/protocol/openid-connect/token"
PROCESS_URL="https://sh.dataspace.copernicus.eu/process/v1"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- OAuth token ------------------------------------------------------------
if [[ -z "${ACCESS_TOKEN:-}" ]]; then
    : "${SH_CLIENT_ID:?Set SH_CLIENT_ID and SH_CLIENT_SECRET in scripts-galicia/.env.galicia, or provide ACCESS_TOKEN}"
    : "${SH_CLIENT_SECRET:?Set SH_CLIENT_ID and SH_CLIENT_SECRET in scripts-galicia/.env.galicia, or provide ACCESS_TOKEN}"
    log "Requesting Copernicus OAuth token"
    TOKEN_FILE="${TMP_DIR}/token.json"
    status="$(curl -sS -X POST "${TOKEN_URL}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data "grant_type=client_credentials" \
        --data-urlencode "client_id=${SH_CLIENT_ID}" \
        --data-urlencode "client_secret=${SH_CLIENT_SECRET}" \
        -o "${TOKEN_FILE}" -w "%{http_code}")"
    [[ "${status}" =~ ^2 ]] || { cat "${TOKEN_FILE}" >&2; die "OAuth token request failed (HTTP ${status})"; }
    ACCESS_TOKEN="$(jq -er '.access_token' "${TOKEN_FILE}")" || die "No access_token in OAuth response"
fi

# --- Process API request ----------------------------------------------------
EVALSCRIPT="$(cat <<'EVAL'
//VERSION=3
function setup() {
  return {
    input: [{ bands: ["B04","B08","B8A","B11"], units: "DN" }],
    output: [
      { id: "B04", bands: 1, sampleType: "UINT16" },
      { id: "B08", bands: 1, sampleType: "UINT16" },
      { id: "B8A", bands: 1, sampleType: "UINT16" },
      { id: "B11", bands: 1, sampleType: "UINT16" }
    ]
  };
}
function evaluatePixel(s) { return { B04:[s.B04], B08:[s.B08], B8A:[s.B8A], B11:[s.B11] }; }
EVAL
)"

REQUEST_JSON="$(jq -n \
    --arg min_lon "$MIN_LON" --arg min_lat "$MIN_LAT" \
    --arg max_lon "$MAX_LON" --arg max_lat "$MAX_LAT" \
    --arg width "$WIDTH" --arg height "$HEIGHT" \
    --arg max_cloud "$MAX_CLOUD" --arg from "$FROM" --arg to "$TO" \
    --arg mosaicking "$MOSAICKING_ORDER" --arg evalscript "$EVALSCRIPT" '
{
  input: {
    bounds: {
      bbox: [($min_lon|tonumber),($min_lat|tonumber),($max_lon|tonumber),($max_lat|tonumber)],
      properties: { crs: "http://www.opengis.net/def/crs/OGC/1.3/CRS84" }
    },
    data: [{ type: "sentinel-2-l2a",
             dataFilter: { timeRange: { from: $from, to: $to },
                           maxCloudCoverage: ($max_cloud|tonumber),
                           mosaickingOrder: $mosaicking } }]
  },
  output: {
    width: ($width|tonumber), height: ($height|tonumber),
    responses: [
      { identifier: "B04", format: { type: "image/tiff" } },
      { identifier: "B08", format: { type: "image/tiff" } },
      { identifier: "B8A", format: { type: "image/tiff" } },
      { identifier: "B11", format: { type: "image/tiff" } }
    ]
  },
  evalscript: $evalscript
}')"

ARCHIVE="${TMP_DIR}/response.tar"
log "Requesting B04/B08/B8A/B11 for ${REGION} ${DATE_FROM}..${DATE_TO} bbox=[${MIN_LON},${MIN_LAT},${MAX_LON},${MAX_LAT}]"
status="$(curl -sS -X POST "${PROCESS_URL}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/tar" \
    --data-binary "${REQUEST_JSON}" \
    -o "${ARCHIVE}" -w "%{http_code}")"
[[ "${status}" =~ ^2 ]] || { cat "${ARCHIVE}" >&2; die "Process API request failed (HTTP ${status})"; }
tar -tf "${ARCHIVE}" >/dev/null 2>&1 || { cat "${ARCHIVE}" >&2; die "Process API response was not a TAR archive"; }
tar -xf "${ARCHIVE}" -C "${RAW_DIR}"

# --- Clip each band to the exact Galicia polygon ----------------------------
for band in B04 B08 B8A B11; do
    raw="${RAW_DIR}/${band}.tif"
    [[ -s "${raw}" ]] || die "Expected band file missing after extract: ${raw}"
    band_lc="${band,,}"
    out_name="galicia_${band_lc}_${FROM_TOKEN}_${TO_TOKEN}.tif"
    log "Clipping ${band} to ${REGION} polygon -> ${out_name}"
    geotools gdalwarp -overwrite -of GTiff \
        -cutline "${AOI_GEOJSON_CONTAINER}" -crop_to_cutline \
        -co TILED=YES -co COMPRESS=DEFLATE \
        "/data/INPUT/NDXI/galicia/raw/${band}.tif" \
        "/data/INPUT/NDXI/galicia/${out_name}"
done

log "Sentinel download + clip complete (${REGION} ${DATE_FROM}..${DATE_TO})"
