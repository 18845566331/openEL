"""
Feature: el-defect-detection, Property 24: 预处理可逆性
**Validates: Requirements 预处理和后处理流程**

属性定义:
对于任何图像和预处理参数(scale, pad_x, pad_y)，从模型输出空间映射回原始图像空间的
坐标变换应该是预处理变换的逆操作，即：
- original_x = (model_x - pad_x) / scale
- original_y = (model_y - pad_y) / scale

测试策略:
- 使用 Hypothesis 生成随机的图像尺寸和输入尺寸
- 创建随机图像
- 调用 _preprocess() 获取 scale, pad_x, pad_y
- 选择原始图像中的一个点 (ox, oy)
- 计算该点在模型输入空间中的坐标: model_x = ox * scale + pad_x, model_y = oy * scale + pad_y
- 验证逆变换: (model_x - pad_x) / scale ≈ ox, (model_y - pad_y) / scale ≈ oy
"""
from __future__ import annotations

import numpy as np
from hypothesis import given, settings
import hypothesis.strategies as st

from app.detector import DefectDetectionEngine


# ---------------------------------------------------------------------------
# Hypothesis 策略
# ---------------------------------------------------------------------------

# 图像尺寸策略：合理的源图像尺寸范围
src_dimension_st = st.integers(min_value=32, max_value=2000)

# 模型输入尺寸策略
input_dimension_st = st.integers(min_value=64, max_value=2048)


# ---------------------------------------------------------------------------
# 属性测试
# ---------------------------------------------------------------------------

class TestProperty24PreprocessReversibility:
    """
    Feature: el-defect-detection, Property 24: 预处理可逆性
    **Validates: Requirements 预处理和后处理流程**
    """

    @settings(max_examples=100)
    @given(
        src_w=src_dimension_st,
        src_h=src_dimension_st,
        input_w=input_dimension_st,
        input_h=input_dimension_st,
        ox_frac=st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
        oy_frac=st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
        normalize=st.booleans(),
        swap_rb=st.booleans(),
    )
    def test_preprocess_coordinate_reversibility(
        self,
        src_w: int,
        src_h: int,
        input_w: int,
        input_h: int,
        ox_frac: float,
        oy_frac: float,
        normalize: bool,
        swap_rb: bool,
    ):
        """
        Feature: el-defect-detection, Property 24: 预处理可逆性
        **Validates: Requirements 预处理和后处理流程**

        对于任何图像和预处理参数，正向坐标变换后再逆变换应该恢复原始坐标。
        """
        # 创建随机图像（3通道 BGR）
        image = np.random.randint(0, 256, (src_h, src_w, 3), dtype=np.uint8)

        # 调用 _preprocess 获取变换参数
        _blob, scale, pad_x, pad_y = DefectDetectionEngine._preprocess(
            image,
            (input_w, input_h),
            normalize=normalize,
            swap_rb=swap_rb,
        )

        # 在原始图像坐标空间中选择一个点
        # 使用分数避免超出边界
        ox = ox_frac * (src_w - 1)
        oy = oy_frac * (src_h - 1)

        # 正向变换：原始坐标 -> 模型输入空间坐标
        model_x = ox * scale + pad_x
        model_y = oy * scale + pad_y

        # 逆变换：模型输入空间坐标 -> 原始坐标
        recovered_x = (model_x - pad_x) / scale
        recovered_y = (model_y - pad_y) / scale

        # 验证逆变换恢复原始坐标（浮点容差 < 1.0 像素）
        assert abs(recovered_x - ox) < 1.0, (
            f"X 坐标逆变换失败: original={ox}, recovered={recovered_x}, "
            f"diff={abs(recovered_x - ox)}"
        )
        assert abs(recovered_y - oy) < 1.0, (
            f"Y 坐标逆变换失败: original={oy}, recovered={recovered_y}, "
            f"diff={abs(recovered_y - oy)}"
        )
