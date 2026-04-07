"""单张图像检测 - 属性测试和单元测试。

包含:
- 属性 3: 图像格式支持通用性 (需求 2.3)
- 属性 4: 检测结果结构完整性 (需求 2.6)
- 属性 6: 自定义参数覆盖 (需求 2.9, 2.10)
- 单元测试: 有效图像检测、无效图像错误处理、模型未加载错误、各种图像格式 (需求 2.1, 2.2, 2.3, 2.13)
"""
from __future__ import annotations

import tempfile
from pathlib import Path

import cv2
import numpy as np
import pytest
from hypothesis import given, settings, assume
import hypothesis.strategies as st

from app.detector import DefectDetectionEngine, ModelLoadConfig


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

def _create_minimal_onnx(path: Path) -> None:
    """创建一个最小的 Identity ONNX 模型。"""
    import onnx
    from onnx import TensorProto, helper

    X = helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, 64, 64])
    Y = helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3, 64, 64])
    node = helper.make_node("Identity", inputs=["input"], outputs=["output"])
    graph = helper.make_graph([node], "test_graph", [X], [Y])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 11)])
    model.ir_version = 7
    onnx.save(model, str(path))


def _create_test_image(path: Path, width: int = 100, height: int = 100) -> None:
    """使用 numpy 随机生成 + cv2.imwrite 创建测试图像。"""
    img = np.random.randint(0, 256, (height, width, 3), dtype=np.uint8)
    cv2.imwrite(str(path), img)


def _load_engine(model_path: Path) -> DefectDetectionEngine:
    """创建并加载模型的引擎实例。"""
    engine = DefectDetectionEngine()
    config = ModelLoadConfig(
        model_path=str(model_path),
        labels=["隐裂", "断栅", "黑斑", "烧结异常"],
        input_width=64,
        input_height=64,
        output_layout="cxcywh_obj_cls",
        normalize=True,
        swap_rb=True,
        confidence_threshold=0.55,
        iou_threshold=0.45,
        backend_preference="onnxruntime",
    )
    engine.load_model(config)
    return engine


# ---------------------------------------------------------------------------
# 共享 Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def onnx_model_path(tmp_path_factory) -> Path:
    """模块级别的临时 ONNX 模型文件。"""
    tmp_dir = tmp_path_factory.mktemp("models")
    model_path = tmp_dir / "test_model.onnx"
    _create_minimal_onnx(model_path)
    return model_path


@pytest.fixture(scope="module")
def loaded_engine(onnx_model_path: Path) -> DefectDetectionEngine:
    """模块级别的已加载模型引擎。"""
    return _load_engine(onnx_model_path)


# ---------------------------------------------------------------------------
# Hypothesis 策略
# ---------------------------------------------------------------------------

SUPPORTED_FORMATS = ["jpg", "jpeg", "png", "bmp", "tif", "tiff"]

image_format_st = st.sampled_from(SUPPORTED_FORMATS)
image_dimension_st = st.integers(min_value=32, max_value=500)
confidence_st = st.floats(min_value=0.01, max_value=1.0, allow_nan=False)
iou_st = st.floats(min_value=0.01, max_value=1.0, allow_nan=False)


# ===========================================================================
# 属性 3: 图像格式支持通用性
# ===========================================================================

class TestProperty3ImageFormatSupport:
    """
    Feature: el-defect-detection, Property 3: 图像格式支持通用性
    **Validates: Requirements 2.3**
    """

    @settings(max_examples=100)
    @given(
        fmt=image_format_st,
        width=image_dimension_st,
        height=image_dimension_st,
    )
    def test_supported_format_detection_succeeds(
        self,
        loaded_engine: DefectDetectionEngine,
        fmt: str,
        width: int,
        height: int,
    ):
        """
        Feature: el-defect-detection, Property 3: 图像格式支持通用性
        **Validates: Requirements 2.3**

        对于任何支持的图像格式的有效图像文件，检测功能应该能够成功处理并返回结果。
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_path = Path(tmp_dir) / f"test_image.{fmt}"
            _create_test_image(img_path, width, height)

            # 验证图像文件已成功创建且可被 OpenCV 读取
            assume(cv2.imread(str(img_path)) is not None)

            # 调用 detect_image 不应抛出异常
            result = loaded_engine.detect_image(image_path=str(img_path))

            # 验证返回了有效结果
            assert isinstance(result, dict)
            assert "image_path" in result
            assert "total" in result
            assert "detections" in result
            assert isinstance(result["total"], int)
            assert result["total"] >= 0
            assert isinstance(result["detections"], list)


# ===========================================================================
# 属性 4: 检测结果结构完整性
# ===========================================================================

class TestProperty4ResultStructureIntegrity:
    """
    Feature: el-defect-detection, Property 4: 检测结果结构完整性
    **Validates: Requirements 2.6**
    """

    @settings(max_examples=100)
    @given(
        width=image_dimension_st,
        height=image_dimension_st,
        conf=confidence_st,
    )
    def test_result_contains_all_required_fields(
        self,
        loaded_engine: DefectDetectionEngine,
        width: int,
        height: int,
        conf: float,
    ):
        """
        Feature: el-defect-detection, Property 4: 检测结果结构完整性
        **Validates: Requirements 2.6**

        对于任何成功的检测操作，返回的结果应该包含所有必需字段。
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_path = Path(tmp_dir) / "test_image.png"
            _create_test_image(img_path, width, height)

            result = loaded_engine.detect_image(
                image_path=str(img_path),
                confidence_threshold=conf,
            )

            # 验证顶层必需字段
            assert "image_path" in result
            assert "total" in result
            assert "detections" in result
            assert isinstance(result["image_path"], str)
            assert isinstance(result["total"], int)
            assert isinstance(result["detections"], list)
            assert result["total"] == len(result["detections"])

            # 验证每个 detection 的结构完整性
            for det in result["detections"]:
                assert "class_id" in det
                assert "class_name" in det
                assert "score" in det
                assert "box" in det

                assert isinstance(det["class_id"], int)
                assert isinstance(det["class_name"], str)
                assert isinstance(det["score"], (int, float))
                assert isinstance(det["box"], dict)

                # 验证 box 坐标字段
                box = det["box"]
                assert "x1" in box
                assert "y1" in box
                assert "x2" in box
                assert "y2" in box
                assert isinstance(box["x1"], int)
                assert isinstance(box["y1"], int)
                assert isinstance(box["x2"], int)
                assert isinstance(box["y2"], int)


# ===========================================================================
# 属性 6: 自定义参数覆盖
# ===========================================================================

class TestProperty6CustomParameterOverride:
    """
    Feature: el-defect-detection, Property 6: 自定义参数覆盖
    **Validates: Requirements 2.9, 2.10**
    """

    @settings(max_examples=100)
    @given(
        custom_conf=confidence_st,
        custom_iou=iou_st,
        width=image_dimension_st,
        height=image_dimension_st,
    )
    def test_custom_thresholds_applied(
        self,
        loaded_engine: DefectDetectionEngine,
        custom_conf: float,
        custom_iou: float,
        width: int,
        height: int,
    ):
        """
        Feature: el-defect-detection, Property 6: 自定义参数覆盖
        **Validates: Requirements 2.9, 2.10**

        如果提供了自定义的 confidence_threshold 或 iou_threshold，
        系统应该使用这些自定义值而不是默认值进行过滤。
        所有返回的检测项 score 应 >= 自定义 confidence_threshold。
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_path = Path(tmp_dir) / "test_image.png"
            _create_test_image(img_path, width, height)

            result = loaded_engine.detect_image(
                image_path=str(img_path),
                confidence_threshold=custom_conf,
                iou_threshold=custom_iou,
            )

            assert isinstance(result, dict)
            assert isinstance(result["detections"], list)

            # 验证所有检测项的 score >= 自定义 confidence_threshold
            for det in result["detections"]:
                assert det["score"] >= custom_conf, (
                    f"检测项 score {det['score']} 低于自定义阈值 {custom_conf}"
                )


# ===========================================================================
# 单元测试: 单张图像检测
# ===========================================================================

class TestDetectImageUnit:
    """单张图像检测单元测试。

    需求: 2.1, 2.2, 2.3, 2.13
    """

    def test_valid_image_detection(self, loaded_engine: DefectDetectionEngine, tmp_path: Path):
        """需求 2.1: 提供有效的图像文件路径时执行缺陷检测。"""
        img_path = tmp_path / "valid.png"
        _create_test_image(img_path, 200, 200)

        result = loaded_engine.detect_image(image_path=str(img_path))

        assert isinstance(result, dict)
        assert "image_path" in result
        assert "total" in result
        assert "detections" in result
        assert result["total"] >= 0
        assert result["total"] == len(result["detections"])

    def test_nonexistent_image_raises(self, loaded_engine: DefectDetectionEngine):
        """需求 2.2: 图像文件不存在时返回明确的错误信息。"""
        with pytest.raises(FileNotFoundError, match="图像文件不存在"):
            loaded_engine.detect_image(image_path="/nonexistent/path/image.png")

    def test_unreadable_image_raises(self, loaded_engine: DefectDetectionEngine, tmp_path: Path):
        """需求 2.2: 图像文件无法读取时返回明确的错误信息。"""
        bad_file = tmp_path / "bad_image.png"
        bad_file.write_bytes(b"not a real image content")

        with pytest.raises(ValueError, match="无法读取图像文件"):
            loaded_engine.detect_image(image_path=str(bad_file))

    def test_model_not_loaded_raises(self):
        """需求 2.13: 模型未加载时拒绝检测请求并返回错误信息。"""
        engine = DefectDetectionEngine()
        with pytest.raises(RuntimeError, match="模型尚未加载"):
            engine.detect_image(image_path="/some/image.png")

    @pytest.mark.parametrize("fmt", SUPPORTED_FORMATS)
    def test_supported_image_formats(
        self, loaded_engine: DefectDetectionEngine, tmp_path: Path, fmt: str
    ):
        """需求 2.3: 支持常见图像格式 (JPG, JPEG, PNG, BMP, TIF, TIFF)。"""
        img_path = tmp_path / f"test_image.{fmt}"
        _create_test_image(img_path, 150, 150)

        # 某些格式可能在特定环境下不被 OpenCV 支持，跳过
        if cv2.imread(str(img_path)) is None:
            pytest.skip(f"当前环境不支持 {fmt} 格式")

        result = loaded_engine.detect_image(image_path=str(img_path))
        assert isinstance(result, dict)
        assert result["total"] >= 0

    def test_result_image_path_is_absolute(
        self, loaded_engine: DefectDetectionEngine, tmp_path: Path
    ):
        """验证返回的 image_path 是解析后的绝对路径。"""
        img_path = tmp_path / "abs_test.png"
        _create_test_image(img_path, 100, 100)

        result = loaded_engine.detect_image(image_path=str(img_path))
        assert Path(result["image_path"]).is_absolute()

    def test_detection_with_custom_confidence(
        self, loaded_engine: DefectDetectionEngine, tmp_path: Path
    ):
        """需求 2.9: 使用自定义置信度阈值。"""
        img_path = tmp_path / "conf_test.png"
        _create_test_image(img_path, 100, 100)

        result = loaded_engine.detect_image(
            image_path=str(img_path),
            confidence_threshold=0.99,
        )
        # 高阈值下检测结果应为空或所有 score >= 0.99
        for det in result["detections"]:
            assert det["score"] >= 0.99

    def test_detection_with_custom_iou(
        self, loaded_engine: DefectDetectionEngine, tmp_path: Path
    ):
        """需求 2.10: 使用自定义 IOU 阈值。"""
        img_path = tmp_path / "iou_test.png"
        _create_test_image(img_path, 100, 100)

        result = loaded_engine.detect_image(
            image_path=str(img_path),
            iou_threshold=0.1,
        )
        assert isinstance(result, dict)
        assert result["total"] >= 0

    def test_visualization_path_none_by_default(
        self, loaded_engine: DefectDetectionEngine, tmp_path: Path
    ):
        """默认不保存可视化时 visualization_path 应为 None。"""
        img_path = tmp_path / "vis_test.png"
        _create_test_image(img_path, 100, 100)

        result = loaded_engine.detect_image(image_path=str(img_path))
        assert result["visualization_path"] is None
