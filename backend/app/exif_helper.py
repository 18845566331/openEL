import logging
import cv2

logger = logging.getLogger(__name__)

# 常见全画幅/APS-C 传感器尺寸 (mm)，按等效 35mm 焦距倍率反推
_SENSOR_PRESETS = {
    1.0: (35.6, 23.8),   # Full-frame (Sony A7, Canon R5, etc.)
    1.5: (23.5, 15.6),   # APS-C (Sony, Nikon DX)
    1.6: (22.2, 14.8),   # APS-C (Canon)
    2.0: (17.3, 13.0),   # Micro 4/3
}


class _ExifGpsHelper:
    """从原图 EXIF 提取 GPS + 相机参数，为每个裁剪子图计算独立的经纬度坐标。"""

    def __init__(self, image_path: str, img_w: int, img_h: int):
        self.image_path = image_path
        self.img_w = img_w
        self.img_h = img_h
        self.exif_dict = None
        self.has_gps = False
        self.cam_lat = 0.0      # 相机纬度 (°)
        self.cam_lon = 0.0      # 相机经度 (°)
        self.cam_alt = 0.0      # GPS 海拔 (m)
        self.focal_mm = 0.0     # 实际焦距 (mm)
        self.sensor_w_mm = 0.0  # 传感器宽 (mm)
        self.sensor_h_mm = 0.0  # 传感器高 (mm)
        self.gsd = 0.0          # 地面采样距离 (m/pixel)
        self.can_compute_offset = False
        self._parse(image_path)

    def _parse(self, image_path: str):
        try:
            import piexif
            with open(image_path, 'rb') as f:
                if f.read(2) != b'\xff\xd8':
                    return
            self.exif_dict = piexif.load(image_path)
        except Exception as e:
            logger.error(f"[_ExifGpsHelper] piexif.load 失败 ({image_path}): {e}", exc_info=True)
            return

        gps = self.exif_dict.get('GPS', {})
        exif_ifd = self.exif_dict.get('Exif', {})

        # ── 解析 GPS ──
        import piexif as _pf
        try:
            lat_raw = gps[_pf.GPSIFD.GPSLatitude]
            lon_raw = gps[_pf.GPSIFD.GPSLongitude]
            self.cam_lat = (lat_raw[0][0]/lat_raw[0][1]
                           + lat_raw[1][0]/lat_raw[1][1]/60
                           + lat_raw[2][0]/lat_raw[2][1]/3600)
            self.cam_lon = (lon_raw[0][0]/lon_raw[0][1]
                           + lon_raw[1][0]/lon_raw[1][1]/60
                           + lon_raw[2][0]/lon_raw[2][1]/3600)
            if gps.get(_pf.GPSIFD.GPSLatitudeRef, b'N') == b'S':
                self.cam_lat = -self.cam_lat
            if gps.get(_pf.GPSIFD.GPSLongitudeRef, b'E') == b'W':
                self.cam_lon = -self.cam_lon
            alt_raw = gps.get(_pf.GPSIFD.GPSAltitude, (0, 1))
            self.cam_alt = alt_raw[0] / alt_raw[1] if alt_raw[1] else 0
            self.has_gps = True
        except Exception as e:
            logger.error(f"[_ExifGpsHelper] 解析 GPS 数据失败 ({image_path}): {e}, raw_gps: {gps}", exc_info=True)
            return

        # ── 解析焦距与传感器尺寸 ──
        try:
            fl = exif_ifd.get(_pf.ExifIFD.FocalLength, (0, 1))
            self.focal_mm = fl[0] / fl[1] if fl[1] else 0
            fl_35 = exif_ifd.get(_pf.ExifIFD.FocalLengthIn35mmFilm, 0)
            if self.focal_mm > 0 and fl_35 > 0:
                crop_factor = round(fl_35 / self.focal_mm, 1)
                # 匹配最接近的传感器预设
                closest = min(_SENSOR_PRESETS.keys(), key=lambda k: abs(k - crop_factor))
                self.sensor_w_mm, self.sensor_h_mm = _SENSOR_PRESETS[closest]
            elif self.focal_mm > 0:
                # 默认假定全画幅
                self.sensor_w_mm, self.sensor_h_mm = 35.6, 23.8
        except Exception:
            pass

        # ── 估算 GSD（地面采样距离）──
        if self.focal_mm > 0 and self.sensor_w_mm > 0 and self.cam_alt > 0:
            self.gsd = (self.sensor_w_mm * self.cam_alt) / (self.focal_mm * self.img_w)
            if 0.0001 < self.gsd < 10.0:
                self.can_compute_offset = True
                logger.info(
                    "GPS偏移计算已启用: focal=%.1fmm, sensor=%.1fx%.1fmm, alt=%.1fm, GSD=%.4fm/px",
                    self.focal_mm, self.sensor_w_mm, self.sensor_h_mm, self.cam_alt, self.gsd
                )
            else:
                logger.info("GSD=%.4f m/px 超出合理范围，禁用偏移计算", self.gsd)

    def _deg_to_exif_rational(self, deg: float):
        d = int(abs(deg))
        m_full = (abs(deg) - d) * 60
        m = int(m_full)
        s = (m_full - m) * 60
        s_num = int(round(s * 10000))
        s_den = 10000
        return ((d, 1), (m, 1), (s_num, s_den))

    def make_exif_for_crop(self, crop_cx: float, crop_cy: float) -> bytes | None:
        if not self.exif_dict or not self.has_gps:
            return None

        import piexif, copy, math
        exif_copy = copy.deepcopy(self.exif_dict)
        exif_copy.get('Exif', {}).pop(piexif.ExifIFD.PixelXDimension, None)
        exif_copy.get('Exif', {}).pop(piexif.ExifIFD.PixelYDimension, None)
        exif_copy['1st'] = {}
        exif_copy['thumbnail'] = None

        new_lat = self.cam_lat
        new_lon = self.cam_lon

        if self.can_compute_offset:
            dx_px = crop_cx - self.img_w / 2.0
            dy_px = crop_cy - self.img_h / 2.0
            dx_m = dx_px * self.gsd
            dy_m = dy_px * self.gsd
            d_lat = -dy_m / 111320.0
            d_lon = dx_m / (111320.0 * math.cos(math.radians(self.cam_lat)))
            new_lat = self.cam_lat + d_lat
            new_lon = self.cam_lon + d_lon

        gps_ifd = exif_copy.setdefault('GPS', {})
        gps_ifd[piexif.GPSIFD.GPSLatitude] = self._deg_to_exif_rational(abs(new_lat))
        gps_ifd[piexif.GPSIFD.GPSLatitudeRef] = b'N' if new_lat >= 0 else b'S'
        gps_ifd[piexif.GPSIFD.GPSLongitude] = self._deg_to_exif_rational(abs(new_lon))
        gps_ifd[piexif.GPSIFD.GPSLongitudeRef] = b'E' if new_lon >= 0 else b'W'

        try:
            return piexif.dump(exif_copy)
        except Exception as e:
            try:
                safe_gps = {
                    piexif.GPSIFD.GPSLatitude: self._deg_to_exif_rational(abs(new_lat)),
                    piexif.GPSIFD.GPSLatitudeRef: b'N' if new_lat >= 0 else b'S',
                    piexif.GPSIFD.GPSLongitude: self._deg_to_exif_rational(abs(new_lon)),
                    piexif.GPSIFD.GPSLongitudeRef: b'E' if new_lon >= 0 else b'W',
                    piexif.GPSIFD.GPSVersionID: (2, 2, 0, 0)
                }
                safe_exif = {'0th': {}, 'Exif': {}, 'GPS': safe_gps, 'Interop': {}, '1st': {}, 'thumbnail': None}
                return piexif.dump(safe_exif)
            except Exception:
                return None

    def make_base_exif(self) -> bytes | None:
        if not self.exif_dict:
            return None
        import piexif, copy
        exif_copy = copy.deepcopy(self.exif_dict)
        exif_copy.get('Exif', {}).pop(piexif.ExifIFD.PixelXDimension, None)
        exif_copy.get('Exif', {}).pop(piexif.ExifIFD.PixelYDimension, None)
        exif_copy['1st'] = {}
        exif_copy['thumbnail'] = None
        try:
            return piexif.dump(exif_copy)
        except Exception as e:
            try:
                safe_gps = {}
                if self.has_gps:
                    safe_gps = {
                        piexif.GPSIFD.GPSLatitude: self._deg_to_exif_rational(abs(self.cam_lat)),
                        piexif.GPSIFD.GPSLatitudeRef: b'N' if self.cam_lat >= 0 else b'S',
                        piexif.GPSIFD.GPSLongitude: self._deg_to_exif_rational(abs(self.cam_lon)),
                        piexif.GPSIFD.GPSLongitudeRef: b'E' if self.cam_lon >= 0 else b'W',
                        piexif.GPSIFD.GPSVersionID: (2, 2, 0, 0)
                    }
                safe_exif = {'0th': {}, 'Exif': {}, 'GPS': safe_gps, 'Interop': {}, '1st': {}, 'thumbnail': None}
                return piexif.dump(safe_exif)
            except Exception:
                return None

def _read_exif_bytes(image_path: str) -> bytes | None:
    try:
        import piexif
        with open(image_path, 'rb') as f:
            if f.read(2) != b'\xff\xd8':
                return None
        exif_dict = piexif.load(image_path)
        exif_dict.get('Exif', {}).pop(piexif.ExifIFD.PixelXDimension, None)
        exif_dict.get('Exif', {}).pop(piexif.ExifIFD.PixelYDimension, None)
        exif_dict['1st'] = {}
        exif_dict['thumbnail'] = None
        return piexif.dump(exif_dict)
    except Exception:
        return None


def _save_crop_with_exif(
    cell_region,
    crop_path: str,
    crop_quality: int = 95,
    exif_bytes: bytes | None = None,
) -> None:
    if exif_bytes:
        try:
            from PIL import Image as _PILImage
            rgb = cv2.cvtColor(cell_region, cv2.COLOR_BGR2RGB)
            pil_img = _PILImage.fromarray(rgb)
            pil_img.save(str(crop_path), format='JPEG', quality=crop_quality, exif=exif_bytes)
            return
        except Exception as e:
            logger.debug("EXIF 注入失败，回退: %s", e)
    _, buf = cv2.imencode('.jpg', cell_region, [cv2.IMWRITE_JPEG_QUALITY, crop_quality])
    buf.tofile(str(crop_path))
