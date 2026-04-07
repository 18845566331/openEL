"""ModelRuntime 数据类单元测试和属性测试。

需求: 1.4, 1.5, 1.6, 1.7, 1.8
"""
from __future__ import annotations

import pytest
from hypothesis import given, settings
import hypothesis.strategies as st

from app.detector import ModelRuntime, VALID_OUTPUT_LAYOUTS


# ---------------------------------------------------------------------------
# 辅助：构建一个合法的 ModelRuntime 实例
# ---------------------------------------------------------------------------

def _make_runtime(**overrides) -> ModelRuntime:
    defaults = {
        "model_path": "/tmp/model.onnx",
        "labels": ["隐裂", "断栅", "黑斑"],
        "input_width": 640,
        "input_height": 640,
        "output_layout": "cxcywh_obj_cls",
        "normalize": True,
        "swap_rb": True,
        "default_confidence": 0.55,
        "default_iou": 0.45,
        "backend": "onnxruntime",
    }
    defaults.update(overrides)
    return ModelRuntime(**defaults)


# ---------------------------------------------------------------------------
# 单元测试
# ---------------------------------------------------------------------------

class TestModelRuntimeFields:
    """验证 ModelRuntime 各字段的存储和访问。"""

    def test_basic_creation(self):
        rt = _make_runtime()
        assert rt.model_path == "/tmp/model.onnx"
        assert rt.labels == ["隐裂", "断栅", "黑斑"]
        assert rt.backend == "onnxruntime"

    def test_input_size_property(self):
        """需求 1.4: 支持配置模型输入尺寸。"""
        rt = _make_runtime(input_width=320, input_height=480)
        assert rt.input_size == (320, 480)

    def test_labels_stored(self):
        """需求 1.5: 支持配置缺陷类别标签列表。"""
        labels = ["A", "B", "C", "D"]
        rt = _make_runtime(labels=labels)
        assert rt.labels == labels

    def test_empty_labels(self):
        """需求 1.5: 空标签列表也应被接受。"""
        rt = _make_runtime(labels=[])
        assert rt.labels == []

    def test_output_layout_valid_values(self):
        """需求 1.6: 支持三种输出布局格式。"""
        for layout in VALID_OUTPUT_LAYOUTS:
            rt = _make_runtime(output_layout=layout)
            assert rt.output_layout == layout

    def test_output_layout_invalid_raises(self):
        """需求 1.6: 无效布局应抛出 ValueError。"""
        with pytest.raises(ValueError, match="无效的输出布局"):
            _make_runtime(output_layout="invalid_layout")

    def test_preprocessing_params(self):
        """需求 1.7: 支持配置图像预处理参数。"""
        rt = _make_runtime(normalize=False, swap_rb=False)
        assert rt.normalize is False
        assert rt.swap_rb is False

    def test_threshold_params(self):
        """需求 1.8: 支持配置默认置信度阈值和IOU阈值。"""
        rt = _make_runtime(default_confidence=0.7, default_iou=0.3)
        assert rt.default_confidence == 0.7
        assert rt.default_iou == 0.3

    def test_threshold_boundary_zero(self):
        """需求 1.8: 阈值边界值 0.0 应被接受。"""
        rt = _make_runtime(default_confidence=0.0, default_iou=0.0)
        assert rt.default_confidence == 0.0
        assert rt.default_iou == 0.0

    def test_threshold_boundary_one(self):
        """需求 1.8: 阈值边界值 1.0 应被接受。"""
        rt = _make_runtime(default_confidence=1.0, default_iou=1.0)
        assert rt.default_confidence == 1.0
        assert rt.default_iou == 1.0

    def test_confidence_out_of_range_raises(self):
        with pytest.raises(ValueError, match="置信度阈值"):
            _make_runtime(default_confidence=1.5)

    def test_iou_out_of_range_raises(self):
        with pytest.raises(ValueError, match="IOU阈值"):
            _make_runtime(default_iou=-0.1)

    def test_session_and_net_default_none(self):
        rt = _make_runtime()
        assert rt.session is None
        assert rt.net is None


# ---------------------------------------------------------------------------
# 属性测试 (Hypothesis)
# ---------------------------------------------------------------------------

# 策略：生成合法的 ModelRuntime 参数
valid_layout_st = st.sampled_from(sorted(VALID_OUTPUT_LAYOUTS))
threshold_st = st.floats(min_value=0.0, max_value=1.0, allow_nan=False)
dimension_st = st.integers(min_value=64, max_value=4096)
labels_st = st.lists(st.text(min_size=1, max_size=20), min_size=0, max_size=20)


class TestModelRuntimeProperties:
    """基于属性的测试，验证 ModelRuntime 在各种合法输入下的行为。"""

    @settings(max_examples=100)
    @given(
        width=dimension_st,
        height=dimension_st,
    )
    def test_input_size_matches_width_height(self, width: int, height: int):
        """
        **Validates: Requirements 1.4**

        对于任意合法的 input_width 和 input_height，
        input_size 属性应返回 (input_width, input_height)。
        """
        rt = _make_runtime(input_width=width, input_height=height)
        assert rt.input_size == (width, height)

    @settings(max_examples=100)
    @given(labels=labels_st)
    def test_labels_roundtrip(self, labels: list[str]):
        """
        **Validates: Requirements 1.5**

        对于任意标签列表，存入后应能原样取出。
        """
        rt = _make_runtime(labels=labels)
        assert rt.labels == labels

    @settings(max_examples=100)
    @given(layout=valid_layout_st)
    def test_valid_layout_accepted(self, layout: str):
        """
        **Validates: Requirements 1.6**

        对于三种合法输出布局，创建 ModelRuntime 不应抛出异常。
        """
        rt = _make_runtime(output_layout=layout)
        assert rt.output_layout == layout

    @settings(max_examples=100)
    @given(
        normalize=st.booleans(),
        swap_rb=st.booleans(),
    )
    def test_preprocessing_params_roundtrip(self, normalize: bool, swap_rb: bool):
        """
        **Validates: Requirements 1.7**

        对于任意布尔组合的预处理参数，存入后应能原样取出。
        """
        rt = _make_runtime(normalize=normalize, swap_rb=swap_rb)
        assert rt.normalize is normalize
        assert rt.swap_rb is swap_rb

    @settings(max_examples=100)
    @given(
        confidence=threshold_st,
        iou=threshold_st,
    )
    def test_threshold_params_roundtrip(self, confidence: float, iou: float):
        """
        **Validates: Requirements 1.8**

        对于任意 [0.0, 1.0] 范围内的阈值，存入后应能原样取出。
        """
        rt = _make_runtime(default_confidence=confidence, default_iou=iou)
        assert rt.default_confidence == confidence
        assert rt.default_iou == iou
