"""
Feature: el-defect-detection, Property 1: 模型加载往返一致性
**Validates: Requirements 1.1, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.12**

属性定义:
对于任何有效的模型配置（包含模型路径、标签、输入尺寸、输出布局等参数），
加载模型后查询运行时状态应该返回与输入配置等价的参数。

测试策略:
- 使用 Hypothesis 生成随机的有效模型配置参数（标签列表、输入尺寸、输出布局、预处理参数、阈值参数）
- 创建一个临时的有效 ONNX 模型文件
- 调用 engine.load_model() 加载模型
- 调用 engine.describe() 获取运行时状态
- 验证运行时状态中的参数与输入配置一致
"""
from __future__ import annotations

from pathlib import Path

import pytest
from hypothesis import given, settings, assume
import hypothesis.strategies as st

from app.detector import DefectDetectionEngine, ModelLoadConfig, VALID_OUTPUT_LAYOUTS


# ---------------------------------------------------------------------------
# 辅助：创建最小有效 ONNX 模型文件
# ---------------------------------------------------------------------------

def _create_minimal_onnx(path: Path) -> None:
    """使用 onnx 库创建一个简单的 Identity 模型。"""
    import onnx
    from onnx import TensorProto, helper

    X = helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, 64, 64])
    Y = helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3, 64, 64])
    node = helper.make_node("Identity", inputs=["input"], outputs=["output"])
    graph = helper.make_graph([node], "test_graph", [X], [Y])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 11)])
    model.ir_version = 7
    onnx.save(model, str(path))


@pytest.fixture(scope="module")
def onnx_model_path(tmp_path_factory) -> Path:
    """创建一个模块级别的临时 ONNX 模型文件，所有测试共享。"""
    tmp_dir = tmp_path_factory.mktemp("models")
    model_path = tmp_dir / "test_model.onnx"
    _create_minimal_onnx(model_path)
    return model_path


# ---------------------------------------------------------------------------
# Hypothesis 策略：生成有效的模型配置参数
# ---------------------------------------------------------------------------

# 标签策略：生成非空字符串列表（至少1个标签，最多20个）
label_st = st.text(
    alphabet=st.characters(whitelist_categories=("L", "N", "P")),
    min_size=1,
    max_size=20,
)
labels_st = st.lists(label_st, min_size=1, max_size=20)

# 输入尺寸策略：合理的模型输入尺寸范围
dimension_st = st.integers(min_value=64, max_value=2048)

# 输出布局策略：从三种有效布局中选择
layout_st = st.sampled_from(sorted(VALID_OUTPUT_LAYOUTS))

# 阈值策略：[0.0, 1.0] 范围内的浮点数
threshold_st = st.floats(min_value=0.0, max_value=1.0, allow_nan=False)

# 预处理参数策略
normalize_st = st.booleans()
swap_rb_st = st.booleans()

# 推理引擎偏好策略
backend_pref_st = st.sampled_from(["onnxruntime", "opencv_dnn"])


# ---------------------------------------------------------------------------
# 属性测试
# ---------------------------------------------------------------------------

class TestProperty1ModelLoadRoundtrip:
    """
    Feature: el-defect-detection, Property 1: 模型加载往返一致性
    **Validates: Requirements 1.1, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.12**
    """

    @settings(max_examples=100)
    @given(
        labels=labels_st,
        input_width=dimension_st,
        input_height=dimension_st,
        output_layout=layout_st,
        normalize=normalize_st,
        swap_rb=swap_rb_st,
        confidence_threshold=threshold_st,
        iou_threshold=threshold_st,
        backend_preference=backend_pref_st,
    )
    def test_model_load_roundtrip(
        self,
        onnx_model_path: Path,
        labels: list[str],
        input_width: int,
        input_height: int,
        output_layout: str,
        normalize: bool,
        swap_rb: bool,
        confidence_threshold: float,
        iou_threshold: float,
        backend_preference: str,
    ):
        """
        Feature: el-defect-detection, Property 1: 模型加载往返一致性
        **Validates: Requirements 1.1, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.12**

        对于任何有效的模型配置，加载模型后查询运行时状态应该返回与输入配置等价的参数。
        """
        engine = DefectDetectionEngine()

        # 加载模型
        config = ModelLoadConfig(
            model_path=str(onnx_model_path),
            labels=labels,
            input_width=input_width,
            input_height=input_height,
            output_layout=output_layout,
            normalize=normalize,
            swap_rb=swap_rb,
            confidence_threshold=confidence_threshold,
            iou_threshold=iou_threshold,
            backend_preference=backend_preference,
        )
        result = engine.load_model(config)

        # 需求 1.1: 模型加载成功
        assert result["model_loaded"] is True

        # 需求 1.12: 返回运行时配置信息
        assert result["backend"] in ("onnxruntime", "opencv_dnn")

        # 通过 describe() 获取运行时状态
        state = engine.describe()

        # 需求 1.12: describe() 也应返回一致的状态
        assert state["model_loaded"] is True

        # 需求 1.5: 标签列表往返一致
        assert state["labels"] == labels

        # 需求 1.4: 输入尺寸往返一致
        assert state["input_size"] == [input_width, input_height]

        # 需求 1.6: 输出布局往返一致
        assert state["output_layout"] == output_layout

        # 需求 1.8: 阈值参数往返一致
        assert state["default_confidence"] == confidence_threshold
        assert state["default_iou"] == iou_threshold

        # 需求 1.1: 模型路径应为解析后的绝对路径
        assert state["model_path"] == onnx_model_path.resolve().as_posix()

        # load_model() 返回值与 describe() 返回值应一致
        assert result["labels"] == state["labels"]
        assert result["input_size"] == state["input_size"]
        assert result["output_layout"] == state["output_layout"]
        assert result["default_confidence"] == state["default_confidence"]
        assert result["default_iou"] == state["default_iou"]
        assert result["model_path"] == state["model_path"]
        assert result["backend"] == state["backend"]
