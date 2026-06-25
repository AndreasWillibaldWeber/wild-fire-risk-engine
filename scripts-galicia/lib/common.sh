#!/usr/bin/env bash
# Shared helpers for the Galicia recurring data pipeline.
#
# Source this from every scripts-galicia/* script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# It resolves the repo root, loads scripts-galicia/.env.galicia (credentials and
# overrides), and exposes the docker-compose helpers + region/AOI settings used
# by the download/load scripts.
set -Eeuo pipefail
IFS=$'\n\t'

# --- repo root (two levels up from this file) -------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
export REPO_ROOT

GALICIA_DIR="${REPO_ROOT}/scripts-galicia"

# --- environment / credentials ---------------------------------------------
# .env.galicia is gitignored; copy .env.galicia.example and fill in the creds.
if [[ -f "${GALICIA_DIR}/.env.galicia" ]]; then
    # shellcheck disable=SC1091
    set -a; source "${GALICIA_DIR}/.env.galicia"; set +a
fi

# --- region + AOI -----------------------------------------------------------
REGION="${REGION:-Galicia}"
# Name of the autonomous community to clip to (matches spain_autonomous_communities.acom_name).
ACOM_NAME="${ACOM_NAME:-Galicia}"
# AOI polygon exported from the DB (mounted into the containers at /data/...).
AOI_GEOJSON_HOST="${REPO_ROOT}/INPUT/AOI/galicia.geojson"
AOI_GEOJSON_CONTAINER="/data/INPUT/AOI/galicia.geojson"

# --- docker compose helpers -------------------------------------------------
# The cron user may not be in the docker group; set DOCKER="sudo docker" in
# .env.galicia in that case. SERVICE names match docker-compose.yml.
DOCKER="${DOCKER:-docker}"
COMPOSE_CMD="${COMPOSE_CMD:-${DOCKER} compose}"
GEOTOOLS_SVC="${GEOTOOLS_SVC:-geotools}"
POSTGIS_SVC="${POSTGIS_SVC:-postgis}"
# Build a word array (IFS here excludes space, so split COMPOSE_CMD explicitly).
IFS=' ' read -r -a COMPOSE_ARR <<<"${COMPOSE_CMD}"

# PG connection (inside the docker network the host is the service name).
PGHOST_IN="${PGHOST_IN:-postgis}"
PGDATABASE="${PGDATABASE:-gis}"
PGUSER="${PGUSER:-gis}"
PGPASSWORD="${PGPASSWORD:-gis}"

# Run a command inside the geotools container (has GDAL/raster2pgsql/ogr2ogr).
geotools() { ( cd "${REPO_ROOT}" && "${COMPOSE_ARR[@]}" exec -T "${GEOTOOLS_SVC}" "$@" ); }

# Pipe SQL on stdin into psql inside the postgis container.
psql_in() {
    ( cd "${REPO_ROOT}" && "${COMPOSE_ARR[@]}" exec -T "${POSTGIS_SVC}" \
        psql -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 "$@" )
}

# --- logging ----------------------------------------------------------------
log() { printf '%s [galicia] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { printf '%s [galicia][ERROR] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

trap 'die "command failed at ${BASH_SOURCE[0]}:${LINENO}"' ERR

mkdir -p "${REPO_ROOT}/OUTPUT/logs" \
         "${REPO_ROOT}/INPUT/AOI" \
         "${REPO_ROOT}/INPUT/NDXI/galicia" \
         "${REPO_ROOT}/INPUT/FWI/galicia"
