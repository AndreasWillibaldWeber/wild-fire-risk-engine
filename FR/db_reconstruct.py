"""Reconstruct engine input files from the PostGIS database.

The risk engines (FFRM_static.py / FFRM_dinamic.py / FFRM_estatic_aoi.py) read a
fixed ``INPUT/`` tree of GeoTIFFs and shapefiles. This module materialises that
tree, per request, from the PostGIS tables that were loaded with raster2pgsql /
ogr2ogr, optionally clipping every dataset to a request boundary.

Postgres is reached through GDAL/OGR's built-in PG drivers (which use libpq
directly) because the conda environment ships no Python Postgres driver. The
``gdalwarp`` / ``gdal_translate`` / ``ogr2ogr`` CLIs are used for robustness and
parity with how the data was loaded.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from shapely.geometry import mapping
from shapely.geometry.base import BaseGeometry

import FR.FWI as Fwi

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_FWI_DIR = REPO_ROOT / "INPUT" / "FWI"


# ---------------------------------------------------------------------------
# Connection strings (built from the PG* environment variables)
# ---------------------------------------------------------------------------
def _pg_params() -> dict[str, str]:
    return {
        "host": os.environ.get("PGHOST", "postgis"),
        "port": os.environ.get("PGPORT", "5432"),
        "dbname": os.environ.get("PGDATABASE", "gis"),
        "user": os.environ.get("PGUSER", "gis"),
        "password": os.environ.get("PGPASSWORD", "gis"),
    }


def _ogr_dsn() -> str:
    """OGR/vector PG connection string."""
    p = _pg_params()
    return "PG:" + " ".join(f"{k}={v}" for k, v in p.items())


def _gdal_raster_dsn(table: str, *, schema: str = "public") -> str:
    """GDAL PostGISRaster connection string (mode=2 = one coverage per table)."""
    p = _pg_params()
    parts = [f"{k}={v}" for k, v in p.items()]
    parts += [f"schema='{schema}'", f"table='{table}'", "mode='2'"]
    return "PG:" + " ".join(parts)


# ---------------------------------------------------------------------------
# Cutline helper
# ---------------------------------------------------------------------------
def _write_cutline(geometry: BaseGeometry, crs: str, dest_dir: Path) -> Path:
    """Write a clip geometry to a GeoJSON file usable as a gdal/ogr cutline.

    No explicit ``crs`` member is written: GeoJSON implies WGS84 (lon/lat), which
    OGR reads as the layer SRS, so gdalwarp/ogr2ogr reproject the cutline to each
    dataset's CRS automatically. ``clip_geom`` is therefore expected in WGS84.
    """
    if crs not in ("EPSG:4326", "EPSG:CRS84", "OGC:CRS84"):
        raise ValueError(
            f"Cutline geometry must be WGS84 (got {crs}); reproject before clipping."
        )
    dest_dir.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(suffix=".geojson", dir=dest_dir)
    os.close(fd)
    path = Path(name)
    feature_collection = {
        "type": "FeatureCollection",
        "features": [
            {"type": "Feature", "properties": {}, "geometry": mapping(geometry)}
        ],
    }
    path.write_text(json.dumps(feature_collection))
    return path


def _run(cmd: list[str]) -> None:
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"Command failed ({result.returncode}): {' '.join(cmd[:3])} ...\n"
            f"stderr: {result.stderr.strip()[:2000]}"
        )


# ---------------------------------------------------------------------------
# Exporters
# ---------------------------------------------------------------------------
def export_raster_table(
    table: str,
    dest_tif: str | Path,
    *,
    clip_geom: BaseGeometry | None = None,
    clip_geom_crs: str = "EPSG:4326",
    target_srs: str | None = None,
) -> Path:
    """Export a PostGIS raster table to a GeoTIFF, optionally clipped/reprojected.

    When ``clip_geom`` is given it is used as a gdalwarp cutline (GDAL reprojects
    it to the raster CRS), so the geometry may be supplied in any CRS (default
    WGS84). When ``target_srs`` is given the output is reprojected to that CRS;
    otherwise it keeps the source raster's CRS.
    """
    dest_tif = Path(dest_tif)
    dest_tif.parent.mkdir(parents=True, exist_ok=True)
    src = _gdal_raster_dsn(table)

    if clip_geom is None:
        if target_srs is None:
            _run(["gdal_translate", "-of", "GTiff", src, str(dest_tif)])
        else:
            _run(["gdalwarp", "-of", "GTiff", "-t_srs", target_srs,
                  "-overwrite", src, str(dest_tif)])
        return dest_tif

    cutline = _write_cutline(clip_geom, clip_geom_crs, dest_tif.parent)
    try:
        cmd = ["gdalwarp", "-of", "GTiff",
               "-cutline", str(cutline), "-crop_to_cutline", "-overwrite"]
        if target_srs is not None:
            cmd += ["-t_srs", target_srs]
        cmd += [src, str(dest_tif)]
        _run(cmd)
    finally:
        cutline.unlink(missing_ok=True)
    return dest_tif


def export_vector_table(
    table: str,
    dest_shp: str | Path,
    *,
    clip_geom: BaseGeometry | None = None,
    clip_geom_crs: str = "EPSG:4326",
    t_srs: str | None = None,
    select_sql: str | None = None,
) -> Path:
    """Export a PostGIS vector table to an ESRI Shapefile, optionally clipped.

    ``select_sql`` is an optional OGR SQL statement (must include the ``geom``
    column) used instead of the whole table -- e.g. to re-alias columns to the
    casing the engine expects, since PostgreSQL lowercases identifiers on import.
    """
    dest_shp = Path(dest_shp)
    dest_shp.parent.mkdir(parents=True, exist_ok=True)
    src = _ogr_dsn()

    cmd = ["ogr2ogr", "-f", "ESRI Shapefile", "-overwrite"]
    if t_srs is not None:
        cmd += ["-t_srs", t_srs]

    cutline: Path | None = None
    if clip_geom is not None:
        cutline = _write_cutline(clip_geom, clip_geom_crs, dest_shp.parent)
        # -clipsrc with a datasource clips to its geometries (both in clip_geom_crs).
        cmd += ["-clipsrc", str(cutline)]

    if select_sql is not None:
        cmd += ["-sql", select_sql, str(dest_shp), src]
    else:
        cmd += [str(dest_shp), src, table]
    try:
        _run(cmd)
    finally:
        if cutline is not None:
            cutline.unlink(missing_ok=True)
    return dest_shp


def reconstruct_fwi(target_date, dest_fwi_dir: str | Path) -> list[Path]:
    """Copy the date-selected FWI NetCDF files from the on-disk INPUT/FWI folder.

    FWI is not round-tripped through PostGIS: the engines select the multi-variable
    WRF NetCDF files by date and accumulate the indices sequentially, so the
    original files are copied verbatim (all dates <= target_date).
    """
    dest_fwi_dir = Path(dest_fwi_dir)
    dest_fwi_dir.mkdir(parents=True, exist_ok=True)
    selected = Fwi._select_fwi_files(SOURCE_FWI_DIR, target_date)
    copied: list[Path] = []
    for src in selected:
        dst = dest_fwi_dir / src.name
        shutil.copy2(src, dst)
        copied.append(dst)
    return copied


# ---------------------------------------------------------------------------
# Per-engine reconstruction plan
# ---------------------------------------------------------------------------
# Each entry: (kind, table, relative destination path under INPUT/)
_RASTER = "raster"
_VECTOR = "vector"

# The whole-region engines work in a projected (metric) CRS -- FR.infra computes
# pixel counts as extent/25 m and FR.cropped reprojects to EPSG:32629. The stored
# rasters are geographic (dtm/s2_* = 4326) or a different projection (fuels =
# 25830), so reconstructed rasters are reprojected to this CRS for the engine.
ENGINE_RASTER_SRS = "EPSG:32629"

# PostgreSQL lowercases identifiers on import, but the engine modules expect the
# original shapefile column casing. Re-alias on export (the SELECT must include
# the geometry column so OGR carries it through).
_VECTOR_SELECT_SQL: dict[str, str] = {
    "wui_u2018_clc2018_v2020_20u1": 'SELECT geom, code_18 AS "Code_18" FROM wui_u2018_clc2018_v2020_20u1',
}

_ENGINE_PLANS: dict[str, list[tuple[str, str, str]]] = {
    "static": [
        (_RASTER, "dtm", "DTM/DTM.tif"),
        (_RASTER, "s2_b04", "Sentinel/B4.tiff"),
        (_RASTER, "s2_b08", "Sentinel/B8.tiff"),
        (_RASTER, "mfe_00_r", "FUELS/FUELS.tif"),
        (_VECTOR, "spain_canary_transport", "INFRA/galicia_entera.shp"),
        (_VECTOR, "wui_u2018_clc2018_v2020_20u1", "IUF/CLC_galicia.shp"),
    ],
    "dynamic": [
        (_RASTER, "dtm", "DTM/DTM.tif"),
        (_RASTER, "s2_b04", "Sentinel/B4.tiff"),
        (_RASTER, "s2_b08", "Sentinel/B8.tiff"),
        (_RASTER, "s2_b11", "Sentinel/B11.tiff"),
        (_RASTER, "mfe_00_r", "FUELS/FMT_NationalScenario_2019.tif"),
        (_VECTOR, "spain_canary_transport", "INFRA/galicia_solo_vehiculos.shp"),
        (_VECTOR, "wui_u2018_clc2018_v2020_20u1", "IUF/CLC_galicia.shp"),
    ],
}


def reconstruct_inputs(
    dest_input_dir: str | Path,
    *,
    engine: str,
    target_date,
    clip_geom: BaseGeometry | None = None,
    clip_geom_crs: str = "EPSG:4326",
) -> dict[str, object]:
    """Materialise the engine-expected INPUT/ tree from PostGIS (+ FWI copy).

    Returns a dict with the produced file paths keyed by their INPUT-relative path,
    plus the list of FWI files copied.
    """
    if engine not in _ENGINE_PLANS:
        raise ValueError(f"Unknown engine '{engine}'. Expected one of {sorted(_ENGINE_PLANS)}.")

    dest_input_dir = Path(dest_input_dir)
    produced: dict[str, str] = {}

    # FWI first: it is a cheap file-copy and validates the requested date before
    # the heavier DB raster/vector exports run.
    fwi_files = reconstruct_fwi(target_date, dest_input_dir / "FWI")

    for kind, table, rel in _ENGINE_PLANS[engine]:
        dest = dest_input_dir / rel
        if kind == _RASTER:
            export_raster_table(table, dest, clip_geom=clip_geom,
                                clip_geom_crs=clip_geom_crs, target_srs=ENGINE_RASTER_SRS)
        else:
            export_vector_table(table, dest, clip_geom=clip_geom, clip_geom_crs=clip_geom_crs,
                                select_sql=_VECTOR_SELECT_SQL.get(table))
        produced[rel] = str(dest)

    return {
        "input_dir": str(dest_input_dir),
        "produced": produced,
        "fwi_files": [str(p) for p in fwi_files],
        "skipped_layers": ["LST", "TWI", "HIST"],
    }
