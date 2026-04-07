from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from threading import RLock
from typing import Any

import cv2
import numpy as np

import os
import sys

import os
import sys

def __inject_nvidia_dlls():
    import site
    try:
        paths_to_add = []
        if os.name == 'nt':
            for sp in site.getsitepackages() + [site.getusersitepackages()]:
                import pathlib
                base = pathlib.Path(sp) / 'nvidia'
                if base.exists():
                    for lib in ['cudnn', 'cublas', 'cufft', 'curand', 'cusparse', 'cusolver', 'cuda_nvrtc', 'cuda_runtime']:
                        bin_path = base / lib / 'bin'
                        if bin_path.is_dir():
                            paths_to_add.append(str(bin_path))
                            if hasattr(os, 'add_dll_directory'):
                                os.add_dll_directory(str(bin_path))
        
        if paths_to_add:
            os.environ['PATH'] = ';'.join(paths_to_add) + ';' + os.environ.get('PATH', '')
    except Exception:
        pass

__inject_nvidia_dlls()

try:
    import onnxruntime as ort
except ImportError:  # pragma: no cover - optional dependency
    ort = None

logger = logging.getLogger(__name__)


def _imread_unicode(path: str) -> np.ndarray | None:
    """读取包含中文/Unicode字符路径的图像文件。

    cv2.imread 在 Windows 上不支持非 ASCII 路径，
    使用 np.fromfile + cv2.imdecode 绕过此限制。
    """
    try:
        data = np.fromfile(path, dtype=np.uint8)
        if data.size == 0:
            return None
        image = cv2.imdecode(data, cv2.IMREAD_COLOR)
        return image
    except (FileNotFoundError, ValueError, IOError):
        return None


def _imwrite_unicode(path: str, image: np.ndarray) -> bool:
    """写入图像到包含中文/Unicode字符的路径。"""
    try:
        ext = Path(path).suffix or ".png"
        success, buf = cv2.imencode(ext, image)
        if not success:
            return False
        buf.tofile(path)
        return True
    except (IOError, ValueError, FileNotFoundError):
        return False


@dataclass
class DetectionItem:
    class_id: int
    class_name: str
    score: float
    x1: int
    y1: int
    x2: int
    y2: int
    lat: float | None = None
    lon: float | None = None

    def to_dict(self) -> dict[str, Any]:
        d = {
            "class_id": self.class_id,
            "class_name": self.class_name,
            "score": round(self.score, 6),
            "box": {"x1": self.x1, "y1": self.y1, "x2": self.x2, "y2": self.y2},
        }
        if self.lat is not None and self.lon is not None:
            d["lat"] = self.lat
            d["lon"] = self.lon
        return d


@dataclass
class SegmentationItem:
    """分割结果条目，包含检测框和实例掩膜。"""
    class_id: int
    class_name: str
    score: float
    x1: int
    y1: int
    x2: int
    y2: int
    mask: np.ndarray  # uint8 二值掩膜，与原始图像同尺寸
    quad: list[list[int]] | None = None  # 拟合的四边形坐标: [[x,y], [x,y], [x,y], [x,y]]
    lat: float | None = None
    lon: float | None = None

    def to_dict(self, *, include_mask_rle: bool = False) -> dict[str, Any]:
        d: dict[str, Any] = {
            "class_id": self.class_id,
            "class_name": self.class_name,
            "score": round(self.score, 6),
            "box": {"x1": self.x1, "y1": self.y1, "x2": self.x2, "y2": self.y2},
        }
        if self.lat is not None and self.lon is not None:
            d["lat"] = self.lat
            d["lon"] = self.lon
        if self.quad is not None:
            d["quad"] = self.quad

        if include_mask_rle:
            contours, _ = cv2.findContours(
                self.mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
            )
            d["contours"] = [
                c.reshape(-1, 2).tolist() for c in contours if c.shape[0] >= 3
            ]
        return d


def _mask_to_quad(points: np.ndarray) -> np.ndarray:
    """将任意形状的 mask 多边形点集拟合为 4 个顶点的四边形（尽量贴合原始轮廓）。"""
    if points.ndim != 2 or points.shape[1] != 2:
        raise ValueError(f"mask_to_quad 期望输入形状为 (N, 2)，但得到 {points.shape}")

    pts = points.astype(np.float32)

    # 1) 先做凸包，保证轮廓顺序 & 去掉噪声点
    hull = cv2.convexHull(pts)
    peri = cv2.arcLength(hull, True)

    # 2) 尝试通过多边形逼近直接得到 4 个点
    for ratio in (0.01, 0.015, 0.02, 0.03, 0.05, 0.08, 0.1):
        epsilon = ratio * peri
        approx = cv2.approxPolyDP(hull, epsilon, True)  # (M, 1, 2)
        if len(approx) == 4:
            quad = approx.reshape(-1, 2)
            return quad.astype(np.int32)

    # 3) 如果始终拿不到 4 点，就退回到最小外接矩形（一定是 4 点矩形）
    rect = cv2.minAreaRect(pts)  # ((cx, cy), (w, h), angle)
    box = cv2.boxPoints(rect)  # (4, 2) float32
    return np.int32(box)


VALID_OUTPUT_LAYOUTS = frozenset(
    {"cxcywh_obj_cls", "xyxy_score_class", "cxcywh_score_class", "cxcywh_cls"}
)


@dataclass
class ModelLoadConfig:
    """模型加载配置参数。"""
    model_path: str
    model_type: str
    labels: list[str]
    input_width: int
    input_height: int
    output_layout: str
    normalize: bool
    swap_rb: bool
    confidence_threshold: float
    iou_threshold: float
    backend_preference: str

    def __post_init__(self) -> None:
        if self.output_layout not in VALID_OUTPUT_LAYOUTS:
            raise ValueError(
                f"无效的输出布局: {self.output_layout!r}，"
                f"支持的布局: {', '.join(sorted(VALID_OUTPUT_LAYOUTS))}"
            )
        if not (0.0 <= self.confidence_threshold <= 1.0):
            raise ValueError(
                f"置信度阈值必须在 0.0 到 1.0 之间，当前值: {self.confidence_threshold}"
            )
        if not (0.0 <= self.iou_threshold <= 1.0):
            raise ValueError(
                f"IOU阈值必须在 0.0 到 1.0 之间，当前值: {self.iou_threshold}"
            )


@dataclass
class ModelRuntime:
    """存储运行时配置：模型路径、推理引擎实例、输入输出配置、默认阈值参数。"""

    model_path: str
    model_type: str
    labels: list[str]
    input_width: int
    input_height: int
    output_layout: str
    normalize: bool
    swap_rb: bool
    default_confidence: float
    default_iou: float
    backend: str
    session: Any | None = None
    net: cv2.dnn_Net | None = None
    is_seg_model: bool = False
    num_masks: int = 32
    mask_height: int = 160
    mask_width: int = 160

    def __post_init__(self) -> None:
        if self.output_layout not in VALID_OUTPUT_LAYOUTS:
            raise ValueError(
                f"无效的输出布局: {self.output_layout!r}，"
                f"支持的布局: {', '.join(sorted(VALID_OUTPUT_LAYOUTS))}"
            )
        if not (0.0 <= self.default_confidence <= 1.0):
            raise ValueError(
                f"置信度阈值必须在 0.0 到 1.0 之间，当前值: {self.default_confidence}"
            )
        if not (0.0 <= self.default_iou <= 1.0):
            raise ValueError(
                f"IOU阈值必须在 0.0 到 1.0 之间，当前值: {self.default_iou}"
            )

    @property
    def input_size(self) -> tuple[int, int]:
        """返回 (input_width, input_height) 元组。"""
        return self.input_width, self.input_height


class DefectDetectionEngine:
    """通用 ONNX 检测引擎，支持 ONNX Runtime 或 OpenCV DNN。"""

    def __init__(self) -> None:
        self._lock = RLock()
        self._runtime: ModelRuntime | None = None

    def describe(self) -> dict[str, Any]:
        """返回当前运行时状态信息。

        需求 1.12: 模型加载成功时，返回运行时配置信息。
        """
        with self._lock:
            if not self._runtime:
                return {
                    "model_loaded": False,
                    "backend": None,
                    "model_path": None,
                    "model_type": "EL",
                    "labels": [],
                    "input_size": None,
                    "output_layout": None,
                    "default_confidence": None,
                    "default_iou": None,
                }
            runtime = self._runtime
            return {
                "model_loaded": True,
                "backend": runtime.backend,
                "model_path": runtime.model_path,
                "model_type": runtime.model_type,
                "labels": list(runtime.labels),
                "input_size": [runtime.input_width, runtime.input_height],
                "output_layout": runtime.output_layout,
                "default_confidence": runtime.default_confidence,
                "default_iou": runtime.default_iou,
                "is_seg_model": runtime.is_seg_model,
            }

    def load_model(
        self,
        config: ModelLoadConfig,
    ) -> dict[str, Any]:
        """加载 ONNX 模型到推理引擎。

        需求 1.1:  加载有效的 ONNX 模型文件到推理引擎。
        需求 1.9:  ONNX Runtime 可用且用户选择时优先使用。
        需求 1.10: OpenCV DNN 被选择或 ONNX Runtime 不可用时使用 OpenCV DNN。
        需求 1.11: CUDA 设备可用时优先使用 GPU 加速。
        需求 1.12: 模型加载成功时返回运行时配置信息。
        需求 12.6: 使用线程锁保证线程安全。
        """
        with self._lock:
            model_file = Path(config.model_path).expanduser().resolve()
            if not model_file.exists():
                raise FileNotFoundError(f"模型文件不存在: {model_file}")

            if model_file.suffix.lower() == '.pt':
                logger.info("检测到 PyTorch .pt 模型，正在校验或导出对应的 .onnx 格式: %s", model_file)
                onnx_path = model_file.with_suffix('.onnx')
                if not onnx_path.exists():
                    logger.info("未找到匹配的 .onnx 缓存，正调用 ultralytics 进行静默转换...")
                    try:
                        from ultralytics import YOLO
                        model_yolo = YOLO(model_file.as_posix())
                        imgsz = [config.input_height, config.input_width]
                        # 导出 onnx，保持同名同路径
                        model_yolo.export(format='onnx', imgsz=imgsz, simplify=True)
                        logger.info("Ultralytics ONNX 导出完成！")
                    except Exception as e:
                        logger.error("转换 .pt 到 .onnx 失败: %s", e, exc_info=True)
                        raise RuntimeError(f"无法将 {model_file} 转换为 ONNX 格式: {e}")
                
                model_file = onnx_path
                if not model_file.exists():
                    raise FileNotFoundError(f"预期导出的 ONNX 模型文件不存在: {model_file}")

            session = None
            net = None
            backend = "opencv_dnn"

            prefer_onnxruntime = config.backend_preference.lower() == "onnxruntime"

            # 需求 1.9: 优先使用 ONNX Runtime
            if prefer_onnxruntime and ort is not None:
                try:
                    providers = self._select_ort_providers()
                    session = ort.InferenceSession(
                        model_file.as_posix(), providers=providers
                    )
                    backend = "onnxruntime"
                    logger.info(
                        "模型已通过 ONNX Runtime 加载: %s (providers=%s)",
                        model_file,
                        providers,
                    )
                except Exception:
                    logger.warning(
                        "ONNX Runtime 加载失败，回退到 OpenCV DNN: %s",
                        model_file,
                        exc_info=True,
                    )
                    session = None

            # 需求 1.10: 回退到 OpenCV DNN
            if session is None:
                net = cv2.dnn.readNetFromONNX(model_file.as_posix())
                self._configure_opencv_backend(net)
                backend = "opencv_dnn"
                logger.info("模型已通过 OpenCV DNN 加载: %s", model_file)

            # 自动检测模型实际输入尺寸（覆盖前端传入的默认值）
            actual_w, actual_h = config.input_width, config.input_height
            if session is not None:
                try:
                    inp = session.get_inputs()[0]
                    shape = inp.shape
                    if len(shape) == 4:
                        h_val, w_val = shape[2], shape[3]
                        if isinstance(h_val, int) and isinstance(w_val, int) and h_val > 0 and w_val > 0:
                            actual_h, actual_w = h_val, w_val
                            logger.info("自动检测模型输入尺寸: %dx%d (前端请求: %dx%d)",
                                        actual_w, actual_h, config.input_width, config.input_height)
                except Exception:
                    logger.warning("无法自动检测模型输入尺寸，使用前端传入值: %dx%d",
                                   config.input_width, config.input_height)

            # 自动从 ONNX 模型元数据提取类别名称
            auto_labels = list(config.labels)
            if session is not None and not auto_labels:
                try:
                    meta = session.get_modelmeta()
                    if meta and meta.custom_metadata_map and 'names' in meta.custom_metadata_map:
                        import ast
                        names_dict = ast.literal_eval(meta.custom_metadata_map['names'])
                        if isinstance(names_dict, dict):
                            max_id = max(names_dict.keys())
                            auto_labels = [""] * (max_id + 1)
                            for idx, name in names_dict.items():
                                auto_labels[int(idx)] = str(name)
                            logger.info("从模型元数据提取到 %d 个类别: %s", len(auto_labels), auto_labels)
                except Exception:
                    logger.debug("无法从模型元数据提取标签", exc_info=True)

            is_seg = False
            nm = 32
            mh, mw = 160, 160
            is_seg, nm, mh, mw = self._detect_seg_model(session=session, net=net)

            self._runtime = ModelRuntime(
                model_path=model_file.as_posix(),
                model_type=config.model_type,
                labels=auto_labels,
                input_width=actual_w,
                input_height=actual_h,
                output_layout=config.output_layout,
                normalize=config.normalize,
                swap_rb=config.swap_rb,
                default_confidence=config.confidence_threshold,
                default_iou=config.iou_threshold,
                backend=backend,
                session=session,
                net=net,
                is_seg_model=is_seg,
                num_masks=nm,
                mask_height=mh,
                mask_width=mw,
            )
            return self.describe()
    def load_model_from_bytes(
        self,
        *,
        model_bytes: bytes,
        labels: list[str],
        input_width: int = 640,
        input_height: int = 640,
        output_layout: str = "cxcywh_obj_cls",
        normalize: bool = True,
        swap_rb: bool = True,
        confidence_threshold: float = 0.55,
        iou_threshold: float = 0.45,
    ) -> dict[str, Any]:
        """从内存字节流加载 ONNX 模型（用于远程模型重组后加载）。

        会自动从 ONNX 模型元数据提取类别名称（names 字段），
        并自动检测模型实际输入尺寸。
        """
        with self._lock:
            session = None
            net = None
            backend = "opencv_dnn"

            # 尝试从 ONNX 元数据提取模型自带的类别名称
            model_labels = self._extract_labels_from_onnx(model_bytes)
            if model_labels:
                labels = model_labels
                logger.info("从模型元数据提取到 %d 个类别: %s", len(labels), labels)

            if ort is not None:
                try:
                    providers = self._select_ort_providers()
                    session = ort.InferenceSession(model_bytes, providers=providers)
                    backend = "onnxruntime"
                    logger.info("内存模型已通过 ONNX Runtime 加载 (%.1fMB)", len(model_bytes) / (1024 * 1024))
                except Exception:
                    logger.warning("ONNX Runtime 内存加载失败，回退到 OpenCV DNN", exc_info=True)
                    session = None

            if session is None:
                import tempfile, os
                tmp = tempfile.NamedTemporaryFile(suffix=".onnx", delete=False, prefix="el_mem_")
                try:
                    tmp.write(model_bytes)
                    tmp.flush()
                    tmp.close()
                    net = cv2.dnn.readNetFromONNX(tmp.name)
                    self._configure_opencv_backend(net)
                    backend = "opencv_dnn"
                    logger.info("内存模型已通过 OpenCV DNN 加载")
                finally:
                    try:
                        os.unlink(tmp.name)
                    except OSError:
                        pass

            # 自动检测模型实际输入尺寸
            actual_w, actual_h = input_width, input_height
            if session is not None:
                try:
                    inp = session.get_inputs()[0]
                    shape = inp.shape
                    if len(shape) == 4:
                        h_val, w_val = shape[2], shape[3]
                        if isinstance(h_val, int) and isinstance(w_val, int) and h_val > 0 and w_val > 0:
                            actual_h, actual_w = h_val, w_val
                            logger.info("自动检测模型输入尺寸: %dx%d (原始请求: %dx%d)", actual_w, actual_h, input_width, input_height)
                except Exception:
                    logger.warning("无法自动检测模型输入尺寸，使用默认值: %dx%d", input_width, input_height)

            is_seg = False
            nm = 32
            mh, mw = 160, 160
            is_seg, nm, mh, mw = self._detect_seg_model(session=session, net=net)

            self._runtime = ModelRuntime(
                model_path="[memory-buffer]",
                model_type="EL",
                labels=list(labels),
                input_width=actual_w,
                input_height=actual_h,
                output_layout=output_layout,
                normalize=normalize,
                swap_rb=swap_rb,
                default_confidence=confidence_threshold,
                default_iou=iou_threshold,
                backend=backend,
                session=session,
                net=net,
                is_seg_model=is_seg,
                num_masks=nm,
                mask_height=mh,
                mask_width=mw,
            )
            return self.describe()
    @staticmethod
    def _extract_labels_from_onnx(model_bytes: bytes) -> list[str] | None:
        """从 ONNX 模型元数据中提取类别名称。

        Ultralytics/ONNX 导出的模型在 metadata_props 中有可能包含 'names' 字段，
        格式为 Python dict 字符串: {0: 'class0', 1: 'class1', ...}
        """
        try:
            import onnx
            model = onnx.load_from_string(model_bytes)
            for prop in model.metadata_props:
                if prop.key == "names":
                    import ast
                    names_dict = ast.literal_eval(prop.value)
                    if isinstance(names_dict, dict):
                        max_id = max(names_dict.keys())
                        labels = [""] * (max_id + 1)
                        for idx, name in names_dict.items():
                            labels[int(idx)] = str(name)
                        return labels
            return None
        except Exception as exc:
            logger.debug("无法从 ONNX 元数据提取标签: %s", exc)
            return None


    @staticmethod
    def _select_ort_providers() -> list[str]:
        """选择 ONNX Runtime 推理 providers，优先 GPU。

        需求 1.11: CUDA 设备可用时优先使用 GPU 加速。
        """
        providers = ["CPUExecutionProvider"]
        try:
            available = ort.get_available_providers()  # type: ignore[union-attr]
            if "CUDAExecutionProvider" in available:
                providers.insert(0, "CUDAExecutionProvider")
                logger.info("ONNX Runtime: 检测到 CUDA，启用 GPU 加速")
        except Exception:  # pragma: no cover
            logger.debug("获取 ONNX Runtime providers 失败", exc_info=True)
        return providers

    @staticmethod
    def _configure_opencv_backend(net: cv2.dnn_Net) -> None:
        """配置 OpenCV DNN 后端，优先 GPU。

        需求 1.11: CUDA 设备可用时优先使用 GPU 加速。
        """
        try:
            if cv2.cuda.getCudaEnabledDeviceCount() > 0:
                net.setPreferableBackend(cv2.dnn.DNN_BACKEND_CUDA)
                net.setPreferableTarget(cv2.dnn.DNN_TARGET_CUDA_FP16)
                logger.info("OpenCV DNN: 检测到 CUDA，启用 GPU 加速")
                return
        except Exception:  # pragma: no cover
            logger.debug("OpenCV CUDA 检测失败", exc_info=True)
        net.setPreferableBackend(cv2.dnn.DNN_BACKEND_OPENCV)
        net.setPreferableTarget(cv2.dnn.DNN_TARGET_CPU)
        logger.info("OpenCV DNN: 使用 CPU 推理")

    @staticmethod
    def _detect_seg_model(
        *, session: Any | None = None, net: cv2.dnn_Net | None = None
    ) -> tuple[bool, int, int, int]:
        """自动检测是否为分割模型 (YOLO-seg)。

        YOLO-seg ONNX 模型有两个输出：
          output0: 检测头 [1, 4+C+nm, N]
          output1: mask 原型 [1, nm, mh, mw]

        Returns: (is_seg, num_masks, mask_height, mask_width)
        """
        is_seg = False
        nm, mh, mw = 32, 160, 160
        try:
            if session is not None:
                outs = session.get_outputs()
                if len(outs) >= 2:
                    shape1 = outs[1].shape  # e.g. [1, 32, 160, 160]
                    if len(shape1) == 4:
                        is_seg = True
                        b, nm_v, mh_v, mw_v = shape1
                        if isinstance(nm_v, int) and nm_v > 0:
                            nm = nm_v
                        if isinstance(mh_v, int) and mh_v > 0:
                            mh = mh_v
                        if isinstance(mw_v, int) and mw_v > 0:
                            mw = mw_v
                        logger.info(
                            "自动检测到分割模型: num_masks=%d, mask_size=%dx%d",
                            nm, mw, mh,
                        )
            elif net is not None:
                layer_names = net.getUnconnectedOutLayersNames()
                if len(layer_names) >= 2:
                    is_seg = True
                    logger.info(
                        "自动检测到分割模型 (OpenCV DNN, %d 个输出层)",
                        len(layer_names),
                    )
        except Exception:
            logger.debug("检测分割模型失败，视为普通检测模型", exc_info=True)
        return is_seg, nm, mh, mw

    def detect_image(
        self,
        image_path: str,
        *,
        confidence_threshold: float | None = None,
        iou_threshold: float | None = None,
        save_visualization: bool = False,
        visualization_dir: str | None = None,
        stroke_width: int = 2,
        font_size: int = 16,
        show_boxes: bool = True,
        show_labels: bool = True,
        show_confidence: bool = True,
    ) -> dict[str, Any]:
        with self._lock:
            if self._runtime is None:
                raise RuntimeError("模型尚未加载，请先调用 /api/model/load")
            runtime = self._runtime

            image_file = Path(image_path).expanduser().resolve()
            if not image_file.exists():
                # 需求 11.6: 提供明确的文件路径和失败原因
                logger.error("图像文件不存在: path=%s", image_file)
                raise FileNotFoundError(f"图像文件不存在: {image_file}")

            image = _imread_unicode(str(image_file))
            if image is None:
                logger.error("无法读取图像文件: path=%s", image_file)
                raise ValueError(f"无法读取图像文件: {image_file}")

            conf = (
                confidence_threshold
                if confidence_threshold is not None
                else runtime.default_confidence
            )
            iou = iou_threshold if iou_threshold is not None else runtime.default_iou

            blob, scale, pad_x, pad_y = self._preprocess(
                image,
                runtime.input_size,
                normalize=runtime.normalize,
                swap_rb=runtime.swap_rb,
            )
            raw_outputs = self._inference(blob, runtime)
            detections, _ = self._decode_output(
                raw_outputs,
                runtime=runtime,
                conf_threshold=conf,
                iou_threshold=iou,
                scale=scale,
                pad_x=pad_x,
                pad_y=pad_y,
                original_width=image.shape[1],
                original_height=image.shape[0],
            )

            # --- GPS Projection ---
            if runtime.model_type == "RGB" and len(detections) > 0:
                try:
                    from app.exif_helper import _ExifGpsHelper
                    import math
                    gps_helper = _ExifGpsHelper(str(image_file), image.shape[1], image.shape[0])
                    if gps_helper.can_compute_offset:
                        for det in detections:
                            cx = (det.x1 + det.x2) / 2.0
                            cy = (det.y1 + det.y2) / 2.0
                            dx_m = (cx - gps_helper.img_w / 2.0) * gps_helper.gsd
                            dy_m = (cy - gps_helper.img_h / 2.0) * gps_helper.gsd
                            d_lat = -dy_m / 111320.0
                            d_lon = dx_m / (111320.0 * math.cos(math.radians(gps_helper.cam_lat)))
                            det.lat = gps_helper.cam_lat + d_lat
                            det.lon = gps_helper.cam_lon + d_lon
                    elif gps_helper.has_gps:
                        for det in detections:
                            det.lat = gps_helper.cam_lat
                            det.lon = gps_helper.cam_lon
                except Exception as e:
                    logger.debug("GPS projection failed: %s", e)
            # ----------------------

            visualization_path = None
            if save_visualization and visualization_dir:
                vis_dir = Path(visualization_dir).expanduser().resolve()
                vis_dir.mkdir(parents=True, exist_ok=True)
                result_image = image.copy()
                self._draw_detections(
                    result_image, detections,
                    stroke_width=stroke_width,
                    font_size=font_size,
                    show_boxes=show_boxes,
                    show_labels=show_labels,
                    show_confidence=show_confidence,
                )
                visualization_path = (
                    vis_dir / f"{image_file.stem}_result{image_file.suffix}"
                ).as_posix()
                _imwrite_unicode(visualization_path, result_image)

            return {
                "image_path": image_file.as_posix(),
                "total": len(detections),
                "detections": [item.to_dict() for item in detections],
                "visualization_path": visualization_path,
            }

    @staticmethod
    def _preprocess(
        image: np.ndarray,
        input_size: tuple[int, int],
        *,
        normalize: bool,
        swap_rb: bool,
    ) -> tuple[np.ndarray, float, float, float]:
        input_w, input_h = input_size
        src_h, src_w = image.shape[:2]
        scale = min(input_w / src_w, input_h / src_h)
        resized_w, resized_h = int(round(src_w * scale)), int(round(src_h * scale))

        resized = cv2.resize(image, (resized_w, resized_h), interpolation=cv2.INTER_LINEAR)
        canvas = np.full((input_h, input_w, 3), 114, dtype=np.uint8)
        pad_x = (input_w - resized_w) // 2
        pad_y = (input_h - resized_h) // 2
        canvas[pad_y : pad_y + resized_h, pad_x : pad_x + resized_w] = resized

        tensor = canvas.astype(np.float32)
        if swap_rb:
            tensor = tensor[:, :, ::-1]
        if normalize:
            tensor /= 255.0
        tensor = np.transpose(tensor, (2, 0, 1))[None, ...]
        return np.ascontiguousarray(tensor), scale, float(pad_x), float(pad_y)

    @staticmethod
    def _inference(blob: np.ndarray, runtime: ModelRuntime) -> list[np.ndarray]:
        if runtime.backend == "onnxruntime" and runtime.session is not None:
            try:
                input_name = runtime.session.get_inputs()[0].name
                outputs = runtime.session.run(None, {input_name: blob})
                return [np.asarray(item) for item in outputs]
            except Exception as exc:
                # 需求 11.7: 提供推理引擎类型和错误详情
                logger.error(
                    "模型推理失败: engine=onnxruntime, model=%s, error=%s",
                    runtime.model_path,
                    exc,
                    exc_info=True,
                )
                raise RuntimeError(
                    f"ONNX Runtime 推理失败: {exc}"
                ) from exc

        if runtime.net is None:
            raise RuntimeError("OpenCV 推理网络未初始化")
        try:
            runtime.net.setInput(blob)
            # 获取所有输出层（分割模型有多个输出）
            out_names = runtime.net.getUnconnectedOutLayersNames()
            raw_list = runtime.net.forward(out_names)
            return [np.asarray(o) for o in raw_list]
        except Exception as exc:
            # 需求 11.7: 提供推理引擎类型和错误详情
            logger.error(
                "模型推理失败: engine=opencv_dnn, model=%s, error=%s",
                runtime.model_path,
                exc,
                exc_info=True,
            )
            raise RuntimeError(
                f"OpenCV DNN 推理失败: {exc}"
            ) from exc

    def _decode_output(
        self,
        raw_outputs: list[np.ndarray],
        *,
        runtime: ModelRuntime,
        conf_threshold: float,
        iou_threshold: float,
        scale: float,
        pad_x: float,
        pad_y: float,
        original_width: int,
        original_height: int,
    ) -> tuple[list[DetectionItem], list[np.ndarray]]:
        """Returns (detections, mask_coefficients_per_detection).

        mask_coefficients_per_detection 为空列表（非 seg 模型时）或与 detections 等长的 mask 系数列表。
        """
        if not raw_outputs:
            return [], []

        prediction_tensor = raw_outputs[0]
        if runtime.is_seg_model and len(raw_outputs) >= 2:
            def _get_eff_ndim(shape: tuple[int, ...]) -> int:
                return len([d for d in shape if d > 1])
            
            ndim0 = _get_eff_ndim(raw_outputs[0].shape)
            ndim1 = _get_eff_ndim(raw_outputs[1].shape)
            if ndim1 < ndim0:
                prediction_tensor = raw_outputs[1]

        prediction = np.asarray(prediction_tensor, dtype=np.float32)
        while prediction.ndim > 2 and prediction.shape[0] == 1:
            prediction = prediction[0]
        if prediction.ndim == 1:
            prediction = prediction.reshape(1, -1)

        layout = runtime.output_layout.lower()

        # 自动检测输出格式
        if prediction.ndim == 2:
            rows, cols = prediction.shape
            num_labels = len(runtime.labels) if runtime.labels else 1

            if cols == 6 and rows <= 1000:
                # 典型的 end2end / NMS 后处理输出: [N, 6] = [x1, y1, x2, y2, score, class_id]
                sample_scores = prediction[:min(10, rows), 4]
                sample_cls = prediction[:min(10, rows), 5]
                scores_in_range = np.all((sample_scores >= -0.1) & (sample_scores <= 1.1))
                cls_are_ints = np.allclose(sample_cls, np.round(sample_cls), atol=0.1)
                if scores_in_range and cls_are_ints:
                    layout = "xyxy_score_class"
                    logger.info("自动检测到 end2end 输出格式: [%d, 6] -> xyxy_score_class", rows)
                else:
                    if rows < cols:
                        prediction = prediction.T
                    layout = "cxcywh_cls"
                    logger.info("6列非end2end，回退 Anchor-Free: [%d, %d] -> cxcywh_cls", rows, cols)
            elif runtime.is_seg_model and cols == (6 + (runtime.num_masks if runtime.num_masks else 32)) and rows <= 1000:
                # 分割模型的 end2end 输出: [N, 6 + 32] = [x1, y1, x2, y2, score, class_id, mask0..31]
                layout = "xyxy_score_class"
                logger.info("自动检测到分割 end2end 输出格式: [%d, %d] -> xyxy_score_class", rows, cols)
            elif cols > 6 and rows < cols:
                # Anchor-Free 原始输出: [4+C, N] 或 [4+C+nm, N] -> 转置为 [N, cols]
                prediction = prediction.T
                layout = "cxcywh_cls"
                logger.info("自动检测到 Anchor-Free 输出格式: [%d, %d] -> cxcywh_cls (转置)", rows, cols)
            elif layout == "cxcywh_cls":
                if rows < cols:
                    prediction = prediction.T
            else:
                if rows < cols:
                    prediction = prediction.T

        boxes_xyxy: list[list[float]] = []
        scores: list[float] = []
        class_ids: list[int] = []
        all_mask_coeffs: list[np.ndarray] = []  # mask 系数（seg 模型时）

        # 对于 seg 模型，需要分离 mask 系数
        nm = runtime.num_masks if runtime.is_seg_model else 0
        debug_scores = []
        
        for row in prediction:
            if runtime.is_seg_model and nm > 0 and row.size > (4 + nm):
                # seg 模型: row = [cx, cy, w, h, cls0..clsC, mask0..mask_nm]
                mask_coeffs = row[-nm:].copy()
                det_row = row[:-nm]  # 只保留 [cx, cy, w, h, cls0..clsC]
            else:
                mask_coeffs = np.array([], dtype=np.float32)
                det_row = row

            parsed = self._parse_row(det_row, layout)
            if parsed is None:
                continue
            x1, y1, x2, y2, score, class_id = parsed
            debug_scores.append(score)
            if score < conf_threshold:
                continue
            boxes_xyxy.append([x1, y1, x2, y2])
            scores.append(float(score))
            class_ids.append(class_id)
            all_mask_coeffs.append(mask_coeffs)

        if debug_scores:
            logger.info("调试信息: 图片中解析出的最高类别分数 = %.4f (当前阈值=%.4f), 找到总框数=%d, 过滤后有效=%d", max(debug_scores), conf_threshold, len(debug_scores), len(boxes_xyxy))
            logger.info("调试信息: layout=%s, pred shape=%s", layout, prediction.shape)

        if not boxes_xyxy:
            return [], []

        # end2end 模型（xyxy_score_class）已在模型内部完成 NMS，跳过
        is_end2end = (layout == "xyxy_score_class")

        if is_end2end:
            keep_indices = list(range(len(boxes_xyxy)))
        else:
            boxes_xywh = [
                [box[0], box[1], max(1.0, box[2] - box[0]), max(1.0, box[3] - box[1])]
                for box in boxes_xyxy
            ]
            keep = cv2.dnn.NMSBoxes(boxes_xywh, scores, conf_threshold, iou_threshold)
            if keep is None or len(keep) == 0:
                return []
            keep_indices = np.array(keep).reshape(-1).tolist()
        result: list[DetectionItem] = []
        result_mask_coeffs: list[np.ndarray] = []
        for idx in keep_indices:
            x1, y1, x2, y2 = boxes_xyxy[idx]
            x1 = int(np.clip((x1 - pad_x) / scale, 0, original_width - 1))
            y1 = int(np.clip((y1 - pad_y) / scale, 0, original_height - 1))
            x2 = int(np.clip((x2 - pad_x) / scale, 0, original_width - 1))
            y2 = int(np.clip((y2 - pad_y) / scale, 0, original_height - 1))

            class_id = class_ids[idx]
            class_name = (
                runtime.labels[class_id]
                if 0 <= class_id < len(runtime.labels)
                else f"缺陷_{class_id}"
            )
            result.append(
                DetectionItem(
                    class_id=class_id,
                    class_name=class_name,
                    score=scores[idx],
                    x1=min(x1, x2),
                    y1=min(y1, y2),
                    x2=max(x1, x2),
                    y2=max(y1, y2),
                )
            )
            if all_mask_coeffs and idx < len(all_mask_coeffs):
                result_mask_coeffs.append(all_mask_coeffs[idx])
        return result, result_mask_coeffs

    @staticmethod
    def _parse_row(row: np.ndarray, layout: str) -> tuple[float, float, float, float, float, int] | None:
        if row.ndim != 1 or row.size < 5:
            return None

        if layout == "xyxy_score_class":
            if row.size < 6:
                return None
            x1, y1, x2, y2, score, class_id = row[:6]
            return float(x1), float(y1), float(x2), float(y2), float(score), int(class_id)

        if layout == "cxcywh_score_class":
            if row.size < 6:
                return None
            cx, cy, w, h, score, class_id = row[:6]
            x1 = float(cx - w / 2.0)
            y1 = float(cy - h / 2.0)
            x2 = float(cx + w / 2.0)
            y2 = float(cy + h / 2.0)
            return x1, y1, x2, y2, float(score), int(class_id)

        if layout == "cxcywh_cls":
            # Anchor-Free 格式: [cx, cy, w, h, cls0_score, cls1_score, ...]
            # 没有 objectness 列，score 直接取类别分数最大值
            cx, cy, w, h = row[:4]
            cls_scores = row[4:]
            if cls_scores.size == 0:
                return None
            cls_scores_flat = cls_scores.ravel()
            class_id = int(np.argmax(cls_scores_flat))
            score = float(cls_scores_flat[class_id])
            x1 = float(cx - w / 2.0)
            y1 = float(cy - h / 2.0)
            x2 = float(cx + w / 2.0)
            y2 = float(cy + h / 2.0)
            return x1, y1, x2, y2, score, class_id

        # 默认布局 (Anchor-Based): cx, cy, w, h, objectness, cls1, cls2, ...
        if row.size < 6:
            return None
        cx, cy, w, h, objectness = row[:5]
        cls_scores = row[5:]
        if cls_scores.size == 0:
            return None
        cls_scores_flat = cls_scores.ravel()
        class_id = int(np.argmax(cls_scores_flat))
        if class_id >= cls_scores_flat.size:
            return None
        score = float(objectness * cls_scores_flat[class_id])
        x1 = float(cx - w / 2.0)
        y1 = float(cy - h / 2.0)
        x2 = float(cx + w / 2.0)
        y2 = float(cy + h / 2.0)
        return x1, y1, x2, y2, score, class_id

    @staticmethod
    def _decode_masks(
        mask_coefficients: list[np.ndarray],
        proto_masks: np.ndarray,
        detections: list[DetectionItem],
        *,
        original_width: int,
        original_height: int,
        scale: float,
        pad_x: float,
        pad_y: float,
        input_width: int,
        input_height: int,
        mask_height: int = 160,
        mask_width: int = 160,
    ) -> list[np.ndarray]:
        """从 mask 原型和系数解码实例分割掩膜。

        算法:
        1. mask = sigmoid(coeffs @ protos)  -> [mh, mw]
        2. 裁剪到 letterbox 中的 bbox 区域
        3. 上采样到原始图像尺寸
        4. 二值化
        """
        if not mask_coefficients or proto_masks is None:
            return []

        # proto_masks: [1, nm, mh, mw] or [nm, mh, mw]
        protos = np.asarray(proto_masks, dtype=np.float32)
        while protos.ndim > 3 and protos.shape[0] == 1:
            protos = protos[0]  # -> [nm, mh, mw]

        if protos.ndim != 3:
            logger.warning("原型掩膜形状异常: %s", protos.shape)
            return []

        nm, pmh, pmw = protos.shape

        # 计算 letterbox -> proto 的缩放比例
        scale_x = pmw / input_width
        scale_y = pmh / input_height

        results: list[np.ndarray] = []
        for i, det in enumerate(detections):
            if i >= len(mask_coefficients):
                results.append(np.zeros((original_height, original_width), dtype=np.uint8))
                continue

            coeffs = mask_coefficients[i].astype(np.float32)
            if coeffs.size != nm:
                results.append(np.zeros((original_height, original_width), dtype=np.uint8))
                continue

            # coeffs @ protos -> [mh, mw]
            proto_flat = protos.reshape(nm, -1)  # [nm, mh*mw]
            mask_flat = coeffs @ proto_flat       # [mh*mw]
            mask_2d = mask_flat.reshape(pmh, pmw)  # [mh, mw]

            # sigmoid
            mask_2d = 1.0 / (1.0 + np.exp(-np.clip(mask_2d, -50, 50)))

            # 裁剪到 letterbox 中的 bbox 区域
            # 注意: detections 的坐标已经是原始图像坐标，需要转化回 letterbox 坐标
            bx1 = (det.x1 * scale + pad_x) * scale_x
            by1 = (det.y1 * scale + pad_y) * scale_y
            bx2 = (det.x2 * scale + pad_x) * scale_x
            by2 = (det.y2 * scale + pad_y) * scale_y

            # 在 proto 尺寸内裁剪
            bx1_i = max(0, int(np.floor(bx1)))
            by1_i = max(0, int(np.floor(by1)))
            bx2_i = min(pmw, int(np.ceil(bx2)))
            by2_i = min(pmh, int(np.ceil(by2)))

            cropped = np.zeros_like(mask_2d)
            if bx2_i > bx1_i and by2_i > by1_i:
                cropped[by1_i:by2_i, bx1_i:bx2_i] = mask_2d[by1_i:by2_i, bx1_i:bx2_i]
            else:
                cropped = mask_2d  # 回退到不裁剪

            # 去除 letterbox padding 并上采样到原始图像尺寸
            # proto 中的有效区域
            px1 = int(pad_x * scale_x)
            py1 = int(pad_y * scale_y)
            px2 = int((input_width - pad_x) * scale_x)
            py2 = int((input_height - pad_y) * scale_y)
            px1 = max(0, min(px1, pmw))
            py1 = max(0, min(py1, pmh))
            px2 = max(px1 + 1, min(px2, pmw))
            py2 = max(py1 + 1, min(py2, pmh))

            content = cropped[py1:py2, px1:px2]
            if content.size == 0:
                results.append(np.zeros((original_height, original_width), dtype=np.uint8))
                continue

            # 上采样到原始图像尺寸
            full_mask = cv2.resize(
                content, (original_width, original_height),
                interpolation=cv2.INTER_LINEAR,
            )

            # 二值化
            binary = (full_mask > 0.5).astype(np.uint8) * 255

            results.append(binary)

        return results

    def detect_image_seg(
        self,
        image_path: str,
        *,
        confidence_threshold: float | None = None,
        iou_threshold: float | None = None,
    ) -> dict[str, Any]:
        """分割模式推理：返回检测结果 + 实例掩膜。

        Returns:
            {
                "image_path": str,
                "total": int,
                "detections": list[dict],           # 与 detect_image 相同
                "segmentation_items": list[SegmentationItem],
                "is_seg_model": bool,
            }
        """
        with self._lock:
            if self._runtime is None:
                raise RuntimeError("模型尚未加载，请先调用 /api/model/load")
            runtime = self._runtime

            image_file = Path(image_path).expanduser().resolve()
            if not image_file.exists():
                raise FileNotFoundError(f"图像文件不存在: {image_file}")

            image = _imread_unicode(str(image_file))
            if image is None:
                raise ValueError(f"无法读取图像文件: {image_file}")

            conf = (
                confidence_threshold
                if confidence_threshold is not None
                else runtime.default_confidence
            )
            iou = iou_threshold if iou_threshold is not None else runtime.default_iou

            blob, scale, pad_x, pad_y = self._preprocess(
                image,
                runtime.input_size,
                normalize=runtime.normalize,
                swap_rb=runtime.swap_rb,
            )
            raw_outputs = self._inference(blob, runtime)
            detections, mask_coeffs = self._decode_output(
                raw_outputs,
                runtime=runtime,
                conf_threshold=conf,
                iou_threshold=iou,
                scale=scale,
                pad_x=pad_x,
                pad_y=pad_y,
                original_width=image.shape[1],
                original_height=image.shape[0],
            )

            # --- GPS Projection ---
            if runtime.model_type == "RGB" and len(detections) > 0:
                try:
                    from app.exif_helper import _ExifGpsHelper
                    import math
                    gps_helper = _ExifGpsHelper(str(image_file), image.shape[1], image.shape[0])
                    if gps_helper.can_compute_offset:
                        for det in detections:
                            cx = (det.x1 + det.x2) / 2.0
                            cy = (det.y1 + det.y2) / 2.0
                            dx_m = (cx - gps_helper.img_w / 2.0) * gps_helper.gsd
                            dy_m = (cy - gps_helper.img_h / 2.0) * gps_helper.gsd
                            d_lat = -dy_m / 111320.0
                            d_lon = dx_m / (111320.0 * math.cos(math.radians(gps_helper.cam_lat)))
                            det.lat = gps_helper.cam_lat + d_lat
                            det.lon = gps_helper.cam_lon + d_lon
                    elif gps_helper.has_gps:
                        for det in detections:
                            det.lat = gps_helper.cam_lat
                            det.lon = gps_helper.cam_lon
                except Exception as e:
                    logger.debug("GPS projection failed: %s", e)
            # ----------------------

            seg_items: list[SegmentationItem] = []

            if runtime.is_seg_model and len(raw_outputs) >= 2 and mask_coeffs:
                def _get_eff_ndim(shape: tuple[int, ...]) -> int:
                    return len([d for d in shape if d > 1])
                
                ndim0 = _get_eff_ndim(raw_outputs[0].shape)
                ndim1 = _get_eff_ndim(raw_outputs[1].shape)
                proto_masks = raw_outputs[0] if ndim0 > ndim1 else raw_outputs[1]

                masks = self._decode_masks(
                    mask_coeffs,
                    proto_masks,
                    detections,
                    original_width=image.shape[1],
                    original_height=image.shape[0],
                    scale=scale,
                    pad_x=pad_x,
                    pad_y=pad_y,
                    input_width=runtime.input_width,
                    input_height=runtime.input_height,
                    mask_height=runtime.mask_height,
                    mask_width=runtime.mask_width,
                )
                from typing import Tuple

                final_seg_items: list[SegmentationItem] = []
                for det, mask in zip(detections, masks):
                    # 5) 从 mask 提取轮廓并拟合四边形
                    contours, _ = cv2.findContours(
                        mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
                    )
                    if not contours:
                        continue

                    # 对所有轮廓按面积过滤，避免只保留最大轮廓导致同图多块组件变成 1 个框
                    contours_with_area = [
                        (cnt, cv2.contourArea(cnt)) for cnt in contours if cnt.shape[0] >= 4
                    ]
                    if not contours_with_area:
                        continue

                    max_area = max(a for _, a in contours_with_area)
                    h0, w0 = image.shape[:2]
                    # 面积阈值（适当放宽，尽量避免漏检正常组件）
                    min_keep_area = max(0.002 * h0 * w0, 0.15 * max_area)

                    quads_for_det = []
                    for cnt, area in contours_with_area:
                        if area < min_keep_area:
                            continue

                        pts = cnt.reshape(-1, 2)  # (N, 2)
                        try:
                            quad = _mask_to_quad(pts)
                            quads_for_det.append(quad.tolist())
                        except Exception as e:
                            logger.warning("轮廓拟合四边形失败: %s", e)
                            continue

                    # 如果这个检测框没有拟合出任何有效的四边形，则跳过
                    if not quads_for_det:
                        continue
                    
                    # 默认取最大的那个四边形作为该实例的 quad
                    # （如果是多个碎片，目前由于 NMS 和 target instance 限制，通常每个目标一个主要 mask）
                    primary_quad = quads_for_det[0]

                    final_seg_items.append(
                        SegmentationItem(
                            class_id=det.class_id,
                            class_name=det.class_name,
                            score=det.score,
                            x1=det.x1,
                            y1=det.y1,
                            x2=det.x2,
                            y2=det.y2,
                            mask=mask,
                            quad=primary_quad,
                        )
                    )
                seg_items = final_seg_items
                logger.info(
                    "分割推理及多边形拟合完成: %s, 检测到 %d 个有效实例",
                    image_file.name,
                    len(seg_items),
                )
            else:
                # 非 seg 模型，回退到普通检测结果
                for det in detections:
                    seg_items.append(
                        SegmentationItem(
                            class_id=det.class_id,
                            class_name=det.class_name,
                            score=det.score,
                            x1=det.x1,
                            y1=det.y1,
                            x2=det.x2,
                            y2=det.y2,
                            mask=np.zeros(
                                (image.shape[0], image.shape[1]), dtype=np.uint8
                            ),
                        )
                    )

            return {
                "image_path": image_file.as_posix(),
                "total": len(seg_items),
                "detections": [item.to_dict() for item in seg_items],
                "segmentation_items": seg_items,
                "is_seg_model": runtime.is_seg_model,
            }

    @staticmethod
    def _draw_detections(
        image: np.ndarray,
        detections: list[DetectionItem],
        *,
        stroke_width: int = 2,
        font_size: int = 16,
        show_boxes: bool = True,
        show_labels: bool = True,
        show_confidence: bool = True,
    ) -> None:
        if not show_boxes or not detections:
            return
        # 颜色列表 (RGB for PIL)
        _colors_rgb = [
            (248, 113, 113), (251, 191, 36), (96, 165, 250), (52, 211, 153),
            (167, 139, 250), (251, 146, 60), (34, 211, 238), (244, 114, 182),
        ]

        from PIL import Image, ImageDraw, ImageFont

        pil_img = Image.fromarray(cv2.cvtColor(image, cv2.COLOR_BGR2RGB))
        draw = ImageDraw.Draw(pil_img)

        # 加载中文字体
        font = None
        need_label = show_labels or show_confidence
        if need_label:
            font_candidates = [
                "msyh.ttc",       # 微软雅黑 (Windows system font path)
                "simhei.ttf",     # 黑体
                "simsun.ttc",     # 宋体
                "msyhbd.ttc",     # 微软雅黑粗体
                "C:/Windows/Fonts/msyh.ttc",
                "C:/Windows/Fonts/simhei.ttf",
                "C:/Windows/Fonts/simsun.ttc",
                "C:/Windows/Fonts/msyhbd.ttc",
            ]
            for fp in font_candidates:
                try:
                    font = ImageFont.truetype(fp, font_size)
                    break
                except Exception:
                    continue
            if font is None:
                try:
                    font = ImageFont.truetype("arial.ttf", font_size)
                except Exception:
                    font = ImageFont.load_default()

        for item in detections:
            idx = abs(hash(item.class_name)) % len(_colors_rgb)
            color = _colors_rgb[idx]

            # 绘制矩形框
            try:
                draw.rectangle(
                    [item.x1, item.y1, item.x2, item.y2],
                    outline=color,
                    width=stroke_width,
                )
            except TypeError:
                # 兼容旧版本不支持 width 参数的情况
                for offset in range(stroke_width):
                    draw.rectangle(
                        [item.x1 + offset, item.y1 + offset, item.x2 - offset, item.y2 - offset],
                        outline=color,
                    )

            # 绘制标签
            if need_label and font is not None:
                parts = []
                if show_labels:
                    parts.append(item.class_name)
                if show_confidence:
                    parts.append(f"{item.score * 100:.0f}%")
                label = " ".join(parts)
                if label:
                    bbox = font.getbbox(label)
                    tw = bbox[2] - bbox[0]
                    th = bbox[3] - bbox[1]
                    lx = item.x1
                    
                    # 动态计算 padding，使其与字体大小成比例
                    pad_x = max(2, int(font_size * 0.15))
                    pad_y = max(1, int(font_size * 0.1))
                    
                    # 背景框的总尺寸 = 文字实际尺寸 + 两侧padding
                    box_w = tw + pad_x * 2
                    box_h = th + pad_y * 2
                    
                    ly = item.y1 - box_h
                    if ly < 0:
                        ly = item.y1 + stroke_width
                    
                    draw.rectangle([lx, ly, lx + box_w, ly + box_h], fill=color)
                    # 文字绘制位置需要补偿 getbbox 返回的 y 偏移
                    draw.text((lx + pad_x, ly + pad_y - bbox[1]), label, fill=(255, 255, 255), font=font)

        # 转回 OpenCV BGR
        result = cv2.cvtColor(np.array(pil_img), cv2.COLOR_RGB2BGR)
        np.copyto(image, result)

