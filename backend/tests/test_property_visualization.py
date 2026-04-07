"""
Feature: el-defect-detection
属性 7: 可视化图像生成
属性 8: 可视化内容完整性
属性 9: 可视化图像属性保持
属性 10: 可视化文件命名规则

本文件包含四个可视化相关的属性测试：

属性 7 - 可视化图像生成:
  **Validates: Requirements 2.11, 4.1**
  对于任何检测到缺陷的图像，当 save_visualization 为 true 时，
  系统应该生成可视化图像文件，且该文件应该存在于指定的输出目录中。

属性 8 - 可视化内容完整性:
  **Validates: Requirements 2.12, 4.2, 4.3**
  对于任何生成的可视化图像，图像上应该包含所有检测框
  （可通过比较原始图像和可视化图像的像素差异来验证）。

属性 9 - 可视化图像属性保持:
  **Validates: Requirements 4.5**
  对于任何原始图像，生成的可视化图像应该保持相同的分辨率（宽度和高度）。

属性 10 - 可视化文件命名规则:
  **Validates: Requirements 4.6**
  对于任何原始图像文件，生成的可视化图像文件名应该是原始文件名加上
  "_result" 后缀，保持相同的扩展名。

测试策略:
- 属性 7: 创建图像，调用 detect_image(save_visualization=True)，验证可视化文件存在
- 属性 8: 创建图像和模拟检测结果，调用 _draw_detections()，验证图像被修改（像素差异）
- 属性 9: 创建不同尺寸的图像，调用 _draw_detections()，验证输出图像尺寸不变
- 属性 10: 使用不同文件名的图像，调用 detect_image(save_visualization=True)，验证输出文件名格式
"""
from __future__ import annotations

import tempfile
from pathlib import Path

import cv2
import numpy as np
import pytest
from hypothesis import given, settings, assume
import hypothesis.strategies as st

from app.detector import DefectDetectionEngine, DetectionItem, ModelLoadConfig


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


def _make_detections(
    num: int,
    img_width: int,
    img_height: int,
    rng: np.random.Generator,
) -> list[DetectionItem]:
    """生成合理的检测结果列表，确保框在图像范围内。"""
    labels = ["隐裂", "断栅", "黑斑", "烧结异常"]
    detections = []
    for i in range(num):
        # 确保框至少有 10 像素大小，且在图像范围内
        max_x1 = max(0, img_width - 20)
        max_y1 = max(0, img_height - 20)
        x1 = int(rng.integers(0, max(1, max_x1)))
        y1 = int(rng.integers(0, max(1, max_y1)))
        x2 = int(rng.integers(x1 + 10, min(x1 + 200, img_width)))
        y2 = int(rng.integers(y1 + 10, min(y1 + 200, img_height)))
        class_id = int(rng.integers(0, len(labels)))
        score = float(rng.uniform(0.5, 1.0))
        detections.append(
            DetectionItem(
                class_id=class_id,
                class_name=labels[class_id],
                score=score,
                x1=x1,
                y1=y1,
                x2=x2,
                y2=y2,
            )
        )
    return detections


# ---------------------------------------------------------------------------
# 共享 Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def onnx_model_path(tmp_path_factory) -> Path:
    """模块级别的临时 ONNX 模型文件。"""
    tmp_dir = tmp_path_factory.mktemp("vis_models")
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

# 图像尺寸（确保足够大以容纳检测框）
image_width_st = st.integers(min_value=100, max_value=800)
image_height_st = st.integers(min_value=100, max_value=800)

# 检测框数量
num_detections_st = st.integers(min_value=1, max_value=10)

# 随机种子
seed_st = st.integers(min_value=0, max_value=2**31)

# 支持的图像格式
SUPPORTED_FORMATS = ["jpg", "jpeg", "png", "bmp", "tif", "tiff"]
image_format_st = st.sampled_from(SUPPORTED_FORMATS)

# 文件名策略：只使用安全的 ASCII 字母和数字
filename_st = st.text(
    alphabet="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
    min_size=1,
    max_size=20,
).filter(lambda s: s[0].isascii() and s[0].isalpha())


# ===========================================================================
# 属性 7: 可视化图像生成
# ===========================================================================

class TestProperty7VisualizationImageGeneration:
    """
    Feature: el-defect-detection, Property 7: 可视化图像生成
    **Validates: Requirements 2.11, 4.1**

    对于任何检测到缺陷的图像，当 save_visualization 为 true 时，
    系统应该生成可视化图像文件，且该文件应该存在于指定的输出目录中。
    """

    @settings(max_examples=100)
    @given(
        img_width=image_width_st,
        img_height=image_height_st,
        fmt=image_format_st,
    )
    def test_visualization_file_created_when_save_enabled(
        self,
        loaded_engine: DefectDetectionEngine,
        img_width: int,
        img_height: int,
        fmt: str,
    ):
        """
        Feature: el-defect-detection, Property 7: 可视化图像生成
        **Validates: Requirements 2.11, 4.1**

        当 save_visualization=True 且 visualization_dir 指定时，
        系统应该在输出目录中生成可视化图像文件。
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)

            # 创建测试图像
            img_path = tmp_path / f"test_image.{fmt}"
            _create_test_image(img_path, img_width, img_height)

            # 创建可视化输出目录
            vis_dir = tmp_path / "vis_output"

            # 调用 detect_image
            result = loaded_engine.detect_image(
                str(img_path),
                save_visualization=True,
                visualization_dir=str(vis_dir),
            )

            # 验证：可视化目录已创建
            assert vis_dir.exists(), "可视化输出目录应该被自动创建"

            # 验证：可视化文件路径已返回
            vis_path = result.get("visualization_path")
            assert vis_path is not None, (
                "当 save_visualization=True 时，应该返回 visualization_path"
            )

            # 验证：可视化文件存在
            assert Path(vis_path).exists(), (
                f"可视化文件应该存在于指定路径: {vis_path}"
            )

            # 验证：可视化文件在指定的输出目录中
            assert Path(vis_path).parent == vis_dir, (
                f"可视化文件应该在指定的输出目录中: {vis_dir}"
            )

            # 验证：可视化文件是有效的图像
            vis_image = cv2.imread(vis_path)
            assert vis_image is not None, (
                f"可视化文件应该是可读取的有效图像: {vis_path}"
            )


# ===========================================================================
# 属性 8: 可视化内容完整性
# ===========================================================================

class TestProperty8VisualizationContentIntegrity:
    """
    Feature: el-defect-detection, Property 8: 可视化内容完整性
    **Validates: Requirements 2.12, 4.2, 4.3**

    对于任何生成的可视化图像，图像上应该包含所有检测框
    （可通过比较原始图像和可视化图像的像素差异来验证）。
    """

    @settings(max_examples=100)
    @given(
        img_width=image_width_st,
        img_height=image_height_st,
        num_dets=num_detections_st,
        seed=seed_st,
    )
    def test_draw_detections_modifies_image(
        self,
        img_width: int,
        img_height: int,
        num_dets: int,
        seed: int,
    ):
        """
        Feature: el-defect-detection, Property 8: 可视化内容完整性
        **Validates: Requirements 2.12, 4.2, 4.3**

        对于任何有检测结果的图像，调用 _draw_detections() 后，
        图像应该被修改（像素差异 > 0），说明检测框已被绘制。
        """
        rng = np.random.default_rng(seed)

        # 创建原始图像
        original = np.random.randint(0, 256, (img_height, img_width, 3), dtype=np.uint8)
        image = original.copy()

        # 生成检测结果
        detections = _make_detections(num_dets, img_width, img_height, rng)

        # 调用 _draw_detections（原地修改）
        DefectDetectionEngine._draw_detections(image, detections)

        # 验证：图像已被修改（存在像素差异）
        diff = np.abs(image.astype(np.int16) - original.astype(np.int16))
        total_diff = diff.sum()
        assert total_diff > 0, (
            f"绘制 {num_dets} 个检测框后，图像应该有像素差异，"
            f"但差异为 0"
        )

    @settings(max_examples=100)
    @given(
        img_width=image_width_st,
        img_height=image_height_st,
        num_dets=num_detections_st,
        seed=seed_st,
    )
    def test_each_detection_box_drawn(
        self,
        img_width: int,
        img_height: int,
        num_dets: int,
        seed: int,
    ):
        """
        Feature: el-defect-detection, Property 8: 可视化内容完整性
        **Validates: Requirements 2.12, 4.2, 4.3**

        对于每个检测框，其边界区域应该有像素变化，
        验证每个检测框都被绘制了。
        """
        rng = np.random.default_rng(seed)

        # 创建纯色图像（便于检测像素变化）
        original = np.full((img_height, img_width, 3), 128, dtype=np.uint8)
        image = original.copy()

        # 生成检测结果
        detections = _make_detections(num_dets, img_width, img_height, rng)

        # 调用 _draw_detections
        DefectDetectionEngine._draw_detections(image, detections)

        # 验证：每个检测框的边界区域有像素变化
        for det in detections:
            # 检查矩形框的四条边是否有像素变化
            # 取框区域的像素差异
            x1, y1, x2, y2 = det.x1, det.y1, det.x2, det.y2
            # 扩展区域以包含标签文本（标签在框上方）
            region_y1 = max(0, y1 - 20)
            region_y2 = min(img_height, y2 + 2)
            region_x1 = max(0, x1 - 2)
            region_x2 = min(img_width, x2 + 2)

            original_region = original[region_y1:region_y2, region_x1:region_x2]
            drawn_region = image[region_y1:region_y2, region_x1:region_x2]

            region_diff = np.abs(
                drawn_region.astype(np.int16) - original_region.astype(np.int16)
            ).sum()
            assert region_diff > 0, (
                f"检测框 ({x1},{y1})-({x2},{y2}) 区域应该有像素变化，"
                f"说明该检测框已被绘制"
            )


# ===========================================================================
# 属性 9: 可视化图像属性保持
# ===========================================================================

class TestProperty9VisualizationImageAttributePreservation:
    """
    Feature: el-defect-detection, Property 9: 可视化图像属性保持
    **Validates: Requirements 4.5**

    对于任何原始图像，生成的可视化图像应该保持相同的分辨率（宽度和高度）。
    """

    @settings(max_examples=100)
    @given(
        img_width=image_width_st,
        img_height=image_height_st,
        num_dets=num_detections_st,
        seed=seed_st,
    )
    def test_draw_detections_preserves_resolution(
        self,
        img_width: int,
        img_height: int,
        num_dets: int,
        seed: int,
    ):
        """
        Feature: el-defect-detection, Property 9: 可视化图像属性保持
        **Validates: Requirements 4.5**

        调用 _draw_detections() 后，图像的宽度和高度应该保持不变。
        """
        rng = np.random.default_rng(seed)

        # 创建原始图像
        image = np.random.randint(0, 256, (img_height, img_width, 3), dtype=np.uint8)
        original_shape = image.shape

        # 生成检测结果
        detections = _make_detections(num_dets, img_width, img_height, rng)

        # 调用 _draw_detections（原地修改）
        DefectDetectionEngine._draw_detections(image, detections)

        # 验证：图像尺寸不变
        assert image.shape == original_shape, (
            f"可视化图像尺寸应该保持不变: "
            f"原始 {original_shape} vs 可视化后 {image.shape}"
        )
        assert image.shape[1] == img_width, (
            f"可视化图像宽度应该保持 {img_width}，实际为 {image.shape[1]}"
        )
        assert image.shape[0] == img_height, (
            f"可视化图像高度应该保持 {img_height}，实际为 {image.shape[0]}"
        )


# ===========================================================================
# 属性 10: 可视化文件命名规则
# ===========================================================================

class TestProperty10VisualizationFileNamingConvention:
    """
    Feature: el-defect-detection, Property 10: 可视化文件命名规则
    **Validates: Requirements 4.6**

    对于任何原始图像文件，生成的可视化图像文件名应该是
    原始文件名加上 "_result" 后缀，保持相同的扩展名。
    """

    @settings(max_examples=100)
    @given(
        filename=filename_st,
        fmt=image_format_st,
        img_width=st.integers(min_value=100, max_value=300),
        img_height=st.integers(min_value=100, max_value=300),
    )
    def test_visualization_filename_follows_convention(
        self,
        loaded_engine: DefectDetectionEngine,
        filename: str,
        fmt: str,
        img_width: int,
        img_height: int,
    ):
        """
        Feature: el-defect-detection, Property 10: 可视化文件命名规则
        **Validates: Requirements 4.6**

        可视化文件名应该是 "{原始文件名}_result{原始扩展名}"。
        例如: image.jpg -> image_result.jpg
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)

            # 创建测试图像
            img_path = tmp_path / f"{filename}.{fmt}"
            _create_test_image(img_path, img_width, img_height)

            # 创建可视化输出目录
            vis_dir = tmp_path / "vis_output"

            # 调用 detect_image
            result = loaded_engine.detect_image(
                str(img_path),
                save_visualization=True,
                visualization_dir=str(vis_dir),
            )

            vis_path_str = result.get("visualization_path")
            assert vis_path_str is not None, (
                "当 save_visualization=True 时，应该返回 visualization_path"
            )

            vis_path = Path(vis_path_str)

            # 验证：文件名 = 原始文件名 + "_result"
            expected_stem = f"{filename}_result"
            assert vis_path.stem == expected_stem, (
                f"可视化文件名的 stem 应该是 '{expected_stem}'，"
                f"实际为 '{vis_path.stem}'"
            )

            # 验证：扩展名与原始文件相同
            expected_suffix = f".{fmt}"
            assert vis_path.suffix == expected_suffix, (
                f"可视化文件扩展名应该是 '{expected_suffix}'，"
                f"实际为 '{vis_path.suffix}'"
            )

            # 验证：完整文件名格式正确
            expected_name = f"{filename}_result.{fmt}"
            assert vis_path.name == expected_name, (
                f"可视化文件名应该是 '{expected_name}'，"
                f"实际为 '{vis_path.name}'"
            )
