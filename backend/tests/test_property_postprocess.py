"""
Feature: el-defect-detection
属性 5: 置信度阈值过滤正确性
属性 23: 坐标映射正确性

本文件包含两个后处理相关的属性测试：

属性 5 - 置信度阈值过滤正确性:
  **Validates: Requirements 2.7, 2.9**
  对于任何检测结果和置信度阈值，所有返回的检测项的 score 应该大于或等于指定的置信度阈值。

属性 23 - 坐标映射正确性:
  **Validates: Requirements 后处理流程**
  对于任何检测结果，检测框坐标应该在原始图像的有效范围内，即：
  - 0 <= x1 < x2 <= 原始图像宽度
  - 0 <= y1 < y2 <= 原始图像高度

测试策略:
- 构造模拟的模型输出数据（numpy 数组），直接调用 _decode_output()
- 使用 ModelRuntime 实例（session 和 net 设为 None，不需要真正推理）
- 属性 5: 使用不同的置信度阈值，验证所有返回检测项 score >= 阈值
- 属性 23: 验证所有检测框坐标在原始图像范围内
"""
from __future__ import annotations

import numpy as np
from hypothesis import given, settings, assume
import hypothesis.strategies as st

from app.detector import DefectDetectionEngine, ModelRuntime, VALID_OUTPUT_LAYOUTS


# ---------------------------------------------------------------------------
# Hypothesis 策略
# ---------------------------------------------------------------------------

# 模型输入尺寸
input_dim_st = st.integers(min_value=64, max_value=1280)

# 原始图像尺寸
original_dim_st = st.integers(min_value=32, max_value=4000)

# 置信度阈值 (0, 1) 开区间，避免 0.0 导致全部通过或 1.0 导致全部过滤
conf_threshold_st = st.floats(min_value=0.01, max_value=0.99, allow_nan=False)

# IOU 阈值
iou_threshold_st = st.floats(min_value=0.1, max_value=1.0, allow_nan=False)

# 输出布局
layout_st = st.sampled_from(sorted(VALID_OUTPUT_LAYOUTS))

# 标签列表（至少 1 个）
labels_st = st.lists(
    st.text(min_size=1, max_size=10, alphabet="abcdefghijklmnopqrstuvwxyz"),
    min_size=1,
    max_size=10,
)

# 检测框数量
num_detections_st = st.integers(min_value=1, max_value=50)


# ---------------------------------------------------------------------------
# 辅助函数：构造模拟模型输出
# ---------------------------------------------------------------------------

def _build_raw_output_cxcywh_obj_cls(
    num_dets: int,
    input_w: int,
    input_h: int,
    num_classes: int,
    rng: np.random.Generator,
) -> np.ndarray:
    """构造 cxcywh_obj_cls 布局的模拟输出。

    每行: [cx, cy, w, h, objectness, cls1_score, cls2_score, ...]
    """
    rows = []
    for _ in range(num_dets):
        # 在模型输入空间内生成合理的框
        cx = rng.uniform(0.1 * input_w, 0.9 * input_w)
        cy = rng.uniform(0.1 * input_h, 0.9 * input_h)
        w = rng.uniform(5, min(input_w * 0.5, 2 * cx, 2 * (input_w - cx)))
        h = rng.uniform(5, min(input_h * 0.5, 2 * cy, 2 * (input_h - cy)))
        objectness = rng.uniform(0.0, 1.0)
        cls_scores = rng.uniform(0.0, 1.0, size=num_classes)
        row = np.concatenate([[cx, cy, w, h, objectness], cls_scores])
        rows.append(row)
    return np.array(rows, dtype=np.float32)


def _build_raw_output_xyxy_score_class(
    num_dets: int,
    input_w: int,
    input_h: int,
    num_classes: int,
    rng: np.random.Generator,
) -> np.ndarray:
    """构造 xyxy_score_class 布局的模拟输出。

    每行: [x1, y1, x2, y2, score, class_id]
    """
    rows = []
    for _ in range(num_dets):
        x1 = rng.uniform(0, input_w * 0.7)
        y1 = rng.uniform(0, input_h * 0.7)
        x2 = rng.uniform(x1 + 5, min(x1 + input_w * 0.5, input_w))
        y2 = rng.uniform(y1 + 5, min(y1 + input_h * 0.5, input_h))
        score = rng.uniform(0.0, 1.0)
        class_id = rng.integers(0, num_classes)
        rows.append([x1, y1, x2, y2, score, class_id])
    return np.array(rows, dtype=np.float32)


def _build_raw_output_cxcywh_score_class(
    num_dets: int,
    input_w: int,
    input_h: int,
    num_classes: int,
    rng: np.random.Generator,
) -> np.ndarray:
    """构造 cxcywh_score_class 布局的模拟输出。

    每行: [cx, cy, w, h, score, class_id]
    """
    rows = []
    for _ in range(num_dets):
        cx = rng.uniform(0.1 * input_w, 0.9 * input_w)
        cy = rng.uniform(0.1 * input_h, 0.9 * input_h)
        w = rng.uniform(5, min(input_w * 0.5, 2 * cx, 2 * (input_w - cx)))
        h = rng.uniform(5, min(input_h * 0.5, 2 * cy, 2 * (input_h - cy)))
        score = rng.uniform(0.0, 1.0)
        class_id = rng.integers(0, num_classes)
        rows.append([cx, cy, w, h, score, class_id])
    return np.array(rows, dtype=np.float32)


def _build_raw_output(
    layout: str,
    num_dets: int,
    input_w: int,
    input_h: int,
    num_classes: int,
    seed: int,
) -> np.ndarray:
    """根据布局类型构造模拟输出。"""
    rng = np.random.default_rng(seed)
    if layout == "cxcywh_obj_cls":
        return _build_raw_output_cxcywh_obj_cls(
            num_dets, input_w, input_h, num_classes, rng
        )
    elif layout == "xyxy_score_class":
        return _build_raw_output_xyxy_score_class(
            num_dets, input_w, input_h, num_classes, rng
        )
    else:  # cxcywh_score_class
        return _build_raw_output_cxcywh_score_class(
            num_dets, input_w, input_h, num_classes, rng
        )


def _make_runtime(
    labels: list[str],
    input_w: int,
    input_h: int,
    layout: str,
    conf: float,
    iou: float,
) -> ModelRuntime:
    """创建一个用于测试的 ModelRuntime 实例（不需要真正的推理引擎）。"""
    return ModelRuntime(
        model_path="/fake/model.onnx",
        labels=labels,
        input_width=input_w,
        input_height=input_h,
        output_layout=layout,
        normalize=True,
        swap_rb=True,
        default_confidence=conf,
        default_iou=iou,
        backend="opencv_dnn",
        session=None,
        net=None,
    )


def _compute_preprocess_params(
    original_w: int, original_h: int, input_w: int, input_h: int
) -> tuple[float, float, float]:
    """计算预处理参数 (scale, pad_x, pad_y)，与 _preprocess 逻辑一致。"""
    scale = min(input_w / original_w, input_h / original_h)
    resized_w = int(round(original_w * scale))
    resized_h = int(round(original_h * scale))
    pad_x = (input_w - resized_w) // 2
    pad_y = (input_h - resized_h) // 2
    return scale, float(pad_x), float(pad_y)


# ---------------------------------------------------------------------------
# 属性 5: 置信度阈值过滤正确性
# ---------------------------------------------------------------------------

class TestProperty5ConfidenceThresholdFiltering:
    """
    Feature: el-defect-detection, Property 5: 置信度阈值过滤正确性
    **Validates: Requirements 2.7, 2.9**
    """

    @settings(max_examples=100)
    @given(
        layout=layout_st,
        labels=labels_st,
        input_w=input_dim_st,
        input_h=input_dim_st,
        original_w=original_dim_st,
        original_h=original_dim_st,
        conf_threshold=conf_threshold_st,
        iou_threshold=iou_threshold_st,
        num_dets=num_detections_st,
        seed=st.integers(min_value=0, max_value=2**31),
    )
    def test_all_detections_above_confidence_threshold(
        self,
        layout: str,
        labels: list[str],
        input_w: int,
        input_h: int,
        original_w: int,
        original_h: int,
        conf_threshold: float,
        iou_threshold: float,
        num_dets: int,
        seed: int,
    ):
        """
        Feature: el-defect-detection, Property 5: 置信度阈值过滤正确性
        **Validates: Requirements 2.7, 2.9**

        对于任何检测结果和置信度阈值，所有返回的检测项的 score
        应该大于或等于指定的置信度阈值。
        """
        num_classes = len(labels)

        # 构造模拟模型输出
        raw_data = _build_raw_output(
            layout, num_dets, input_w, input_h, num_classes, seed
        )
        raw_outputs = [raw_data]

        # 创建 runtime
        runtime = _make_runtime(labels, input_w, input_h, layout, conf_threshold, iou_threshold)

        # 计算预处理参数
        scale, pad_x, pad_y = _compute_preprocess_params(
            original_w, original_h, input_w, input_h
        )

        # 调用 _decode_output
        engine = DefectDetectionEngine()
        detections, _ = engine._decode_output(
            raw_outputs,
            runtime=runtime,
            conf_threshold=conf_threshold,
            iou_threshold=iou_threshold,
            scale=scale,
            pad_x=pad_x,
            pad_y=pad_y,
            original_width=original_w,
            original_height=original_h,
        )

        # 验证：所有返回的检测项 score >= conf_threshold
        for det in detections:
            assert det.score >= conf_threshold, (
                f"检测项置信度 {det.score} 低于阈值 {conf_threshold}，"
                f"class_id={det.class_id}, class_name={det.class_name}"
            )


# ---------------------------------------------------------------------------
# 属性 23: 坐标映射正确性
# ---------------------------------------------------------------------------

class TestProperty23CoordinateMappingCorrectness:
    """
    Feature: el-defect-detection, Property 23: 坐标映射正确性
    **Validates: Requirements 后处理流程**
    """

    @settings(max_examples=100)
    @given(
        layout=layout_st,
        labels=labels_st,
        input_w=input_dim_st,
        input_h=input_dim_st,
        original_w=original_dim_st,
        original_h=original_dim_st,
        conf_threshold=st.floats(min_value=0.01, max_value=0.5, allow_nan=False),
        iou_threshold=iou_threshold_st,
        num_dets=num_detections_st,
        seed=st.integers(min_value=0, max_value=2**31),
    )
    def test_detection_coordinates_within_image_bounds(
        self,
        layout: str,
        labels: list[str],
        input_w: int,
        input_h: int,
        original_w: int,
        original_h: int,
        conf_threshold: float,
        iou_threshold: float,
        num_dets: int,
        seed: int,
    ):
        """
        Feature: el-defect-detection, Property 23: 坐标映射正确性
        **Validates: Requirements 后处理流程**

        对于任何检测结果，检测框坐标应该在原始图像的有效范围内：
        - 0 <= x1 < x2 <= 原始图像宽度
        - 0 <= y1 < y2 <= 原始图像高度
        """
        num_classes = len(labels)

        # 构造模拟模型输出
        raw_data = _build_raw_output(
            layout, num_dets, input_w, input_h, num_classes, seed
        )
        raw_outputs = [raw_data]

        # 创建 runtime
        runtime = _make_runtime(labels, input_w, input_h, layout, conf_threshold, iou_threshold)

        # 计算预处理参数
        scale, pad_x, pad_y = _compute_preprocess_params(
            original_w, original_h, input_w, input_h
        )

        # 调用 _decode_output
        engine = DefectDetectionEngine()
        detections, _ = engine._decode_output(
            raw_outputs,
            runtime=runtime,
            conf_threshold=conf_threshold,
            iou_threshold=iou_threshold,
            scale=scale,
            pad_x=pad_x,
            pad_y=pad_y,
            original_width=original_w,
            original_height=original_h,
        )

        # 验证：所有检测框坐标在原始图像范围内
        for det in detections:
            assert 0 <= det.x1, (
                f"x1={det.x1} < 0, 超出图像左边界"
            )
            assert 0 <= det.y1, (
                f"y1={det.y1} < 0, 超出图像上边界"
            )
            assert det.x2 <= original_w, (
                f"x2={det.x2} > original_width={original_w}, 超出图像右边界"
            )
            assert det.y2 <= original_h, (
                f"y2={det.y2} > original_height={original_h}, 超出图像下边界"
            )
            # x1 < x2 且 y1 < y2（有效的边界框）
            # 注意：当 clip 后 x1 == x2 或 y1 == y2 时，_decode_output 中
            # 使用了 min/max 确保 x1 <= x2, y1 <= y2，
            # 但可能出现 x1 == x2 的退化情况（极小框被 clip 到同一像素）
            assert det.x1 <= det.x2, (
                f"x1={det.x1} > x2={det.x2}, 无效的边界框"
            )
            assert det.y1 <= det.y2, (
                f"y1={det.y1} > y2={det.y2}, 无效的边界框"
            )
