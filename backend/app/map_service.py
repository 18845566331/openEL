import io
import os
from fastapi import APIRouter, HTTPException, Query, Response

try:
    from rio_tiler.io import Reader
    from rio_tiler.profiles import img_profiles
    HAS_RIO_TILER = True
    RIO_TILER_ERR = ""
except Exception as e:
    HAS_RIO_TILER = False
    RIO_TILER_ERR = str(e)


map_router = APIRouter(prefix="/api/map", tags=["map"])

# _readers_cache is obsolete because sharing Rasterio readers across threadpools crashes GDAL.

@map_router.get("/tile/{z}/{x}/{y}.png")
def get_tile(z: int, x: int, y: int, path: str = Query(..., description="Path to the orthophoto TIF")):
    """
    Serves standard web mercator XYZ tile rendered as PNG from the given TIF path.
    """
    if not HAS_RIO_TILER:
        raise HTTPException(status_code=500, detail="rio-tiler is not installed.")
    
    try:
        # FastAPI threading requires independent Context Managers for Rasterio dataset
        with Reader(path) as reader:
            img = reader.tile(x, y, z, tilesize=512, resampling_method="bilinear") # Enable 512 Retina tiles and smooth rendering
            # Convert rioxarray image output to a PNG 
            img_buffer = img.render(img_format="PNG", **img_profiles.get("png"))
        return Response(content=img_buffer, media_type="image/png")
    
    except Exception as e:
        raise HTTPException(status_code=404, detail=f"Error rendering tile: {str(e)}")

@map_router.get("/info")
def get_bounds(path: str = Query(..., description="Path to the orthophoto TIF")):
    """
    Get bounding box geometry and metadata about the TIF image to initialize the map view.
    """
    if not HAS_RIO_TILER:
        raise HTTPException(status_code=500, detail=f"rio-tiler is not installed: {RIO_TILER_ERR}")
    try:
        with Reader(path) as reader:
            info = reader.info()
            geographic_bounds = reader.get_geographic_bounds("EPSG:4326")
            return {
                "success": True,
                "bounds": [geographic_bounds[0], geographic_bounds[1], geographic_bounds[2], geographic_bounds[3]],            # (minx, miny, maxx, maxy) in WGS84
                "center": [(geographic_bounds[0] + geographic_bounds[2])/2, (geographic_bounds[1] + geographic_bounds[3])/2], # (lon, lat)
                "minzoom": reader.minzoom,
                "maxzoom": reader.maxzoom,
                "dtype": info.dtype,
                "colorinterp": info.colorinterp,
            }
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))
