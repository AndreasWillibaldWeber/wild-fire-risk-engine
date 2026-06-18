-- Enable PostGIS + raster + pgRouting on first database init.
-- Runs automatically via /docker-entrypoint-initdb.d (empty data dir only).

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS pgrouting;

-- Allow loading rasters via out-of-db drivers / GDAL.
SET postgis.enable_outdb_rasters = true;
SET postgis.gdal_enabled_drivers = 'ENABLE_ALL';
