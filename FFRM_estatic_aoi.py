from __future__ import annotations

import json
import shutil
from datetime import date, datetime, timezone
from pathlib import Path
from uuid import uuid4

import matplotlib

matplotlib.use("Agg")
from shapely.geometry.base import BaseGeometry

import FR.FHIST as Fhist
import FR.FMT_eu as Fmt
import FR.FWI as Fwi
import FR.IUF as Wui
import FR.MDT as Mdt
import FR.NDVI as Ndvi
import FR.infra as Infra
from FR.aoi import DEFAULT_PROJECTED_CRS, build_point_aoi, crop_raster_to_geometry, write_aoi_geojson
from FR.combine import _combine_layers, _resolve_active_top_levels

BASE_DIR = Path(__file__).resolve().parent
INPUT_DIR = BASE_DIR / "INPUT"


def _find_fire_history_risk_map(base_output_dir: Path) -> Path:
    matches = sorted((base_output_dir / "TIFs").glob("Fire_History_*(Risk_Map)_*.tif"))
    if not matches:
        matches = sorted((base_output_dir / "TIFs").glob("Fire_History_*.tif"))
    for match in matches:
        if "(Risk_Map)" in match.name:
            return match
    raise FileNotFoundError("Unable to find exported historical fire risk map.")


def run_static_aoi_for_geometry(
    output_aoi: BaseGeometry,
    target_date: date | str,
    *,
    context_buffer_m: float = 3000,
    output_root: str | Path = BASE_DIR / "OUTPUT" / "aoi",
    keep_intermediate: bool = False,
    request_metadata: dict | None = None,
    optional_layers: dict[str, bool] | None = None,
) -> dict[str, str]:
    """Run the static workflow for one projected AOI geometry and one selected FWI date."""
    active_top_levels = _resolve_active_top_levels(optional_layers)

    if isinstance(target_date, str):
        target_date = date.fromisoformat(target_date)

    if "meteo" in active_top_levels:
        available_dates = Fwi.available_fwi_dates(INPUT_DIR / "FWI")
        if target_date not in available_dates:
            available = ", ".join(day.isoformat() for day in available_dates)
            raise ValueError(f"FWI date {target_date.isoformat()} is not available. Available dates: {available}")

    request_id = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}_{uuid4().hex[:8]}"
    job_dir = Path(output_root) / request_id
    inputs_dir = job_dir / "inputs"
    base_output_dir = job_dir / "base"
    layers_dir = job_dir / "layers"
    inputs_dir.mkdir(parents=True, exist_ok=True)
    base_output_dir.mkdir(parents=True, exist_ok=True)
    layers_dir.mkdir(parents=True, exist_ok=True)

    processing_aoi = output_aoi.buffer(context_buffer_m)
    write_aoi_geojson(output_aoi, job_dir / "aoi.geojson")
    write_aoi_geojson(processing_aoi, job_dir / "processing_aoi.geojson")

    cropped_dtm = crop_raster_to_geometry(INPUT_DIR / "DTM" / "DTM.tif", inputs_dir / "DTM.tif", processing_aoi)
    cropped_b4 = crop_raster_to_geometry(INPUT_DIR / "Sentinel" / "B4.tiff", inputs_dir / "B4.tiff", processing_aoi)
    cropped_b8 = crop_raster_to_geometry(INPUT_DIR / "Sentinel" / "B8.tiff", inputs_dir / "B8.tiff", processing_aoi)
    cropped_fuels = crop_raster_to_geometry(INPUT_DIR / "FUELS" / "FUELS.tif", inputs_dir / "FUELS.tif", processing_aoi)

    Mdt.mdt(cropped_dtm, output_folder=base_output_dir, export_image=True, show_plots=False)
    Ndvi.ndvi(cropped_b4, cropped_b8, output_folder=base_output_dir, export_image=True)
    if "fhist" in active_top_levels:
        Fhist.fire_history(input_folder=INPUT_DIR / "HIST", output_folder=base_output_dir, export_image=True, show_plots=False)
    Fmt.fmt(cropped_fuels, output_folder=base_output_dir, export_image=True, show_plots=False)

    processing_reference = base_output_dir / "TIFs" / "MDT_RISK_MAP.tif"
    Infra.infrastructure(
        INPUT_DIR / "INFRA" / "galicia_entera.shp",
        output_folder=base_output_dir,
        ref_raster=processing_reference,
        export_image=True,
        show_plots=False,
        aoi_geometry=processing_aoi,
        aoi_crs=DEFAULT_PROJECTED_CRS,
    )
    Wui.wui(
        INPUT_DIR / "INFRA" / "galicia_entera.shp",
        INPUT_DIR / "IUF" / "CLC_galicia.shp",
        output_folder=base_output_dir,
        reference_file=processing_reference,
        export_image=True,
        show_plots=False,
        aoi_geometry=processing_aoi,
        aoi_crs=DEFAULT_PROJECTED_CRS,
    )
    if "meteo" in active_top_levels:
        Fwi.f_w_index(
            INPUT_DIR / "FWI",
            output_folder=base_output_dir,
            export_image=True,
            show_plots=False,
            target_date=target_date,
        )

    output_reference = crop_raster_to_geometry(
        processing_reference,
        layers_dir / "reference_mdt.tif",
        output_aoi,
    )

    raw_layer_paths: dict[str, Path] = {
        "ftm": base_output_dir / "TIFs" / "FMT.tif",
        "ndvi": base_output_dir / "TIFs" / "estatic_(NDVI_Risk_Map).tif",
        "wui": base_output_dir / "TIFs" / "IUF_Risk_Map.tif",
        "infra": base_output_dir / "TIFs" / "galicia_entera_(INFRA Risk_Map).tif",
    }
    if "topo" in active_top_levels:
        raw_layer_paths["mdt"] = processing_reference
        raw_layer_paths["slope"] = base_output_dir / "TIFs" / "SLOPE_RISK_MAP.tif"
        raw_layer_paths["aspect"] = base_output_dir / "TIFs" / "ASPECT_RISK_MAP.tif"
    if "fhist" in active_top_levels:
        raw_layer_paths["fhist"] = _find_fire_history_risk_map(base_output_dir)
    if "meteo" in active_top_levels:
        raw_layer_paths["meteo"] = base_output_dir / "TIFs" / "FWI_Risk_Map.tif"

    outputs = _combine_layers(
        raw_layer_paths,
        output_reference,
        layers_dir,
        job_dir / "forest_fire_risk_map.tif",
        job_dir / "forest_fire_risk_map.png",
        active_top_levels=active_top_levels,
    )

    metadata = {
        "request_id": request_id,
        "context_buffer_m": context_buffer_m,
        "fwi_date": target_date.isoformat(),
        "crs": DEFAULT_PROJECTED_CRS,
        "keep_intermediate": keep_intermediate,
        "active_top_levels": sorted(active_top_levels),
        "optional_layers": optional_layers or {},
    }
    if request_metadata:
        metadata.update(request_metadata)
    request_path = job_dir / "request.json"
    request_path.write_text(json.dumps(metadata, indent=2))
    outputs["request"] = request_path
    outputs["job_dir"] = job_dir

    if not keep_intermediate:
        shutil.rmtree(base_output_dir)

    return {key: str(value) for key, value in outputs.items()}


def run_static_aoi(
    longitude: float,
    latitude: float,
    target_date: date | str,
    *,
    buffer_m: float = 3000,
    context_buffer_m: float = 3000,
    output_root: str | Path = BASE_DIR / "OUTPUT" / "aoi",
    keep_intermediate: bool = False,
    optional_layers: dict[str, bool] | None = None,
) -> dict[str, str]:
    """Run the static workflow for one point-buffer AOI and one selected FWI date."""
    output_aoi = build_point_aoi(longitude, latitude, buffer_m)
    return run_static_aoi_for_geometry(
        output_aoi,
        target_date,
        context_buffer_m=context_buffer_m,
        output_root=output_root,
        keep_intermediate=keep_intermediate,
        optional_layers=optional_layers,
        request_metadata={
            "request_type": "point",
            "longitude": longitude,
            "latitude": latitude,
            "buffer_m": buffer_m,
        },
    )


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Run AOI-limited static forest-fire risk workflow.")
    parser.add_argument("--lon", type=float, required=True, help="Longitude in EPSG:4326.")
    parser.add_argument("--lat", type=float, required=True, help="Latitude in EPSG:4326.")
    parser.add_argument("--date", required=True, help="FWI target date in YYYY-MM-DD format.")
    parser.add_argument("--buffer-m", type=float, default=3000, help="Output AOI radius in meters.")
    parser.add_argument("--context-buffer-m", type=float, default=3000, help="Extra processing margin in meters.")
    args = parser.parse_args()

    result = run_static_aoi(
        args.lon,
        args.lat,
        args.date,
        buffer_m=args.buffer_m,
        context_buffer_m=args.context_buffer_m,
    )
    print(json.dumps(result, indent=2))
