# scripts-galicia — Galicia recurring data pipeline

Downloads the two **time-varying** wildfire inputs for the **Galicia** region
only and loads them into the existing PostGIS tables with region + date
metadata:

| Dataset | Source | Cadence | Tables | Metadata added |
|---|---|---|---|---|
| Sentinel-2 B04/B08/B8A/B11 | Copernicus Sentinel Hub Process API | **weekly** | `s2_b04`, `s2_b08`, `s2_b8a`, `s2_b11` | `region`, `date_from`, `date_to` |
| MeteoGalicia WRF (FWI meteo) | MeteoGalicia THREDDS | **daily** | `fwi_<var>` | `region`, `fdate` |

Static layers (DTM, fuels, borders, infrastructure, WUI) are **not** handled
here — they live in `../scripts/` and rarely change.

The region is clipped to the exact **Galicia** polygon (`ST_Union` of
`spain_autonomous_communities WHERE acom_name='Galicia'`); its bbox drives the
download API requests. Sentinel rasters are additionally cut to the polygon;
meteo keeps the WRF grid bbox so it stays aligned with the existing `fwi_*`
tables.

## Layout

```
lib/common.sh                 shared helpers (repo root, env, docker compose, logging)
export-galicia-aoi.sh         DB -> INPUT/AOI/galicia.geojson + galicia.bbox
download-galicia-sentinel.sh  Process API over Galicia bbox + cutline clip
load-galicia-sentinel.sh      append clipped bands into s2_* (+region/date range)
galicia-sentinel-weekly.sh    cron entrypoint (last 7 days)
download-galicia-meteo.sh     WRF nc for a date (Galicia bbox)
load-galicia-meteo.sh         append nc vars into fwi_* (+region/fdate)
galicia-meteo-daily.sh        cron entrypoint (yesterday)
crontab.galicia               schedule
.env.galicia.example          credentials/overrides template
```

## Setup

1. Copy the env template and fill in Copernicus OAuth credentials:
   ```bash
   cp scripts-galicia/.env.galicia.example scripts-galicia/.env.galicia
   # edit SH_CLIENT_ID / SH_CLIENT_SECRET
   # if your user is not in the docker group: set DOCKER="sudo docker"
   ```
   Create an OAuth client at
   <https://shapps.dataspace.copernicus.eu/dashboard/> → User settings → OAuth clients.

2. Make sure the stack is up (`make up`) so `geotools` + `postgis` are running.
   The target tables must already exist (the scripts append into them): run the
   initial bulk load once via `../scripts/load-ndxi.sh` (creates `s2_*`) and
   `../scripts/load-fwi.sh` (creates `fwi_*`) if this is a fresh database.

3. Host tools needed for the **download** step: `curl`, `jq`, `tar`
   (the GDAL/raster2pgsql steps run inside the `geotools` container).

## Manual runs

```bash
# One-off AOI refresh
scripts-galicia/export-galicia-aoi.sh

# Meteo for a specific day
scripts-galicia/galicia-meteo-daily.sh 2026-06-23

# Sentinel for an explicit window
DATE_FROM=2026-06-16 DATE_TO=2026-06-23 scripts-galicia/galicia-sentinel-weekly.sh
```

All scripts are idempotent: re-running a date/window deletes the prior
`region='Galicia'` rows for that date/window before re-loading.

## Scheduling

```bash
# Edit REPO inside the file first, then:
crontab scripts-galicia/crontab.galicia
# or append to your existing crontab:
crontab -l | cat - scripts-galicia/crontab.galicia | crontab -
```
Logs are written to `OUTPUT/logs/galicia-*.log`. The cron user must be able to
run `docker compose` (docker group, or `DOCKER="sudo docker"` in `.env.galicia`
with the matching sudoers rule).

## Querying the results

```sql
-- Latest Galicia Sentinel window present
SELECT region, date_from, date_to, count(*)
FROM s2_b04 WHERE region='Galicia'
GROUP BY 1,2,3 ORDER BY date_to DESC;

-- Galicia meteo dates loaded
SELECT region, min(fdate), max(fdate), count(*)
FROM fwi_temp WHERE region='Galicia' GROUP BY 1;
```

## Notes / caveats

- **Existing tables are reused.** To append the differently-aligned Galicia
  rasters, `DropRasterConstraints` is called on the target tables first. Existing
  whole-Spain rows are left untouched and are distinguished by `region` (NULL for
  the original bulk load, `'Galicia'` for rows loaded here).
- Sentinel history is retained per week (one set of rows per `date_from/date_to`).
  Select the latest with `MAX(date_to)`. Prune old windows manually if needed.
- `FR/db_reconstruct.py` exports these tables clipped to the request geometry, so
  mixed-region rows coexist safely; a future refinement could filter
  `WHERE region='Galicia'`.
- Copernicus Process API quotas apply; MeteoGalicia history has limited
  retention, so run the daily job within that window.
