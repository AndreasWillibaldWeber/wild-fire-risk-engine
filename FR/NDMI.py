import numpy as np
import rasterio

from pathlib import Path

from FR.rutinas.setup import default_imshow, save_file


def Ndmi(
    input_band8: str | Path,
    input_band11: str | Path,
    output_folder: str | Path = "OUTPUT",
    export_image: bool = False,
) -> tuple[np.ndarray, np.ndarray]:
    """Calculate NDMI (Normalized Difference Moisture Index) from Sentinel-2 bands.

    Args:
        input_band8: Path to Band 8 (NIR) raster file
        input_band11: Path to Band 11 (SWIR) raster file
        output_folder: Output directory for exported files. Defaults to 'OUTPUT'
        export_image: Whether to save results as GeoTIFF/PNG. Defaults to False

    Returns:
        Tuple of (ndmi_array, reclassified_risk_array) where risk is scaled 1-5
    """
    print('NDMI Layer processing...')

    with rasterio.open(input_band8) as b8_src:
        nir_band = b8_src.read(1).astype('float32')
        meta_ref = b8_src.meta.copy()

    with rasterio.open(input_band11) as b11_src:
        swir_band = b11_src.read(1).astype('float32')

    np.seterr(divide='ignore', invalid='ignore')
    ndmi = (nir_band - swir_band) / (nir_band + swir_band)

    # Reclassification: assign values 1-5 for risk levels
    reclasificado = np.zeros_like(ndmi, dtype='int32')
    reclasificado[ndmi <= -0.20] = 5
    reclasificado[(ndmi > -0.20) & (ndmi <= 0.00)] = 4
    reclasificado[(ndmi > 0.00) & (ndmi <= 0.20)] = 3
    reclasificado[(ndmi > 0.20) & (ndmi <= 0.40)] = 2
    reclasificado[ndmi > 0.40] = 1

    fig1, _ = default_imshow(ndmi, 'NDMI')
    fig2, _ = default_imshow(reclasificado, 'NDMI Risk Map')

    if export_image:
        save_file(ndmi, 'estatic', output_folder, meta_ref,
                  'NDMI', extensions=['tif', 'tiff', 'png'], fig=fig1)
        save_file(reclasificado, 'estatic', output_folder, meta_ref,
                  'NDMI_Risk_Map', extensions=['tif', 'tiff', 'png'], fig=fig2)

    print('NDMI Layer completed')
    return ndmi, reclasificado
