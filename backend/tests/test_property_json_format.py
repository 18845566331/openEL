"""
Feature: el-defect-detection, Property 20: JSON数据交换格式
**Validates: Requirements 8.7**

属性定义:
对于任何API响应,响应体应该是有效的JSON格式,能够被JSON解析器成功解析。

测试策略:
- 使用 Hypothesis 生成随机的请求参数
- 对所有6个API端点发送请求
- 验证每个响应的Content-Type包含application/json
- 验证每个响应体能被JSON解析器成功解析
- 验证解析后的结果是dict或list类型
- 不使用 mock，通过 TestClient 测试真实的 API 行为
"""
from __future__ import annotations

import json

import pytest
from hypothesis import given, settings
import hypothesis.strategies as st
from fastapi.testclient import TestClient

from app.main import app


# ---------------------------------------------------------------------------
# Hypothesis 策略：生成随机请求参数（复用 Property 19 的策略模式）
# ---------------------------------------------------------------------------

_path_segment_st = st.text(
    alphabet=st.characters(
        whitelist_categories=("L", "N"),
        whitelist_characters="_-./",
    ),
    min_size=1,
    max_size=50,
)

_model_load_request_st = st.fixed_dictionaries({
    "model_path": _path_segment_st,
    "labels": st.lists(
        st.text(min_size=1, max_size=20, alphabet=st.characters(whitelist_categories=("L", "N"))),
        min_size=0,
        max_size=10,
    ),
    "input_width": st.integers(min_value=64, max_value=4096),
    "input_height": st.integers(min_value=64, max_value=4096),
    "output_layout": st.sampled_from(["cxcywh_obj_cls", "xyxy_score_class", "cxcywh_score_class"]),
    "normalize": st.booleans(),
    "swap_rb": st.booleans(),
    "confidence_threshold": st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
    "iou_threshold": st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
    "backend_preference": st.sampled_from(["onnxruntime", "opencv"]),
})

_detect_request_st = st.fixed_dictionaries({
    "image_path": _path_segment_st,
}, optional={
    "confidence_threshold": st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
    "iou_threshold": st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
    "save_visualization": st.booleans(),
    "visualization_dir": st.one_of(st.none(), _path_segment_st),
})

_batch_detect_request_st = st.fixed_dictionaries({
    "input_dir": _path_segment_st,
}, optional={
    "recursive": st.booleans(),
    "extensions": st.lists(
        st.sampled_from([".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff"]),
        min_size=1,
        max_size=6,
    ),
    "max_images": st.integers(min_value=1, max_value=5000),
    "confidence_threshold": st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
    "iou_threshold": st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
    "save_visualization": st.booleans(),
})

_csv_export_request_st = st.fixed_dictionaries({
    "batch_result": st.fixed_dictionaries({
        "results": st.lists(
            st.fixed_dictionaries({
                "image_path": _path_segment_st,
                "total": st.integers(min_value=0, max_value=10),
                "detections": st.lists(
                    st.fixed_dictionaries({
                        "class_id": st.integers(min_value=0, max_value=5),
                        "class_name": st.sampled_from(["隐裂", "断栅", "黑斑", "烧结异常"]),
                        "score": st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
                        "box": st.fixed_dictionaries({
                            "x1": st.integers(min_value=0, max_value=640),
                            "y1": st.integers(min_value=0, max_value=640),
                            "x2": st.integers(min_value=0, max_value=640),
                            "y2": st.integers(min_value=0, max_value=640),
                        }),
                    }),
                    min_size=0,
                    max_size=5,
                ),
            }),
            min_size=0,
            max_size=5,
        ),
    }),
    "output_csv": _path_segment_st,
})

_profile_path_st = _path_segment_st


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

def _assert_valid_json_response(response, endpoint: str) -> None:
    """验证响应是有效的JSON格式，且Content-Type正确。"""
    # 1. 验证Content-Type包含application/json
    content_type = response.headers.get("content-type", "")
    assert "application/json" in content_type, (
        f"端点 {endpoint} 的Content-Type不包含application/json: "
        f"'{content_type}', status={response.status_code}"
    )

    # 2. 验证响应体能被JSON解析器成功解析
    raw_body = response.content.decode("utf-8")
    try:
        parsed = json.loads(raw_body)
    except json.JSONDecodeError as exc:
        pytest.fail(
            f"端点 {endpoint} 的响应体不是有效的JSON: "
            f"error={exc}, body={raw_body[:200]}"
        )

    # 3. 验证解析后的结果是dict或list
    assert isinstance(parsed, (dict, list)), (
        f"端点 {endpoint} 的JSON响应不是对象或数组: type={type(parsed)}"
    )


# ---------------------------------------------------------------------------
# 属性测试
# ---------------------------------------------------------------------------

class TestProperty20JsonDataExchangeFormat:
    """
    Feature: el-defect-detection, Property 20: JSON数据交换格式
    **Validates: Requirements 8.7**
    """

    @pytest.fixture(autouse=True)
    def _setup_client(self):
        self.client = TestClient(app, raise_server_exceptions=False)

    # --- GET /health ---

    @settings(max_examples=100)
    @given(data=st.data())
    def test_health_returns_valid_json(self, data):
        """
        Feature: el-defect-detection, Property 20: JSON数据交换格式
        **Validates: Requirements 8.7**

        GET /health 端点的响应应始终是有效的JSON格式。
        """
        response = self.client.get("/health")
        _assert_valid_json_response(response, "GET /health")

    # --- POST /api/model/load ---

    @settings(max_examples=100)
    @given(request_body=_model_load_request_st)
    def test_model_load_returns_valid_json(self, request_body: dict):
        """
        Feature: el-defect-detection, Property 20: JSON数据交换格式
        **Validates: Requirements 8.7**

        对于任何模型加载请求，POST /api/model/load 的响应
        应始终是有效的JSON格式（无论成功或失败）。
        """
        response = self.client.post("/api/model/load", json=request_body)
        _assert_valid_json_response(response, "POST /api/model/load")

    # --- POST /api/model/load_profile ---

    @settings(max_examples=100)
    @given(profile_path=_profile_path_st)
    def test_model_load_profile_returns_valid_json(self, profile_path: str):
        """
        Feature: el-defect-detection, Property 20: JSON数据交换格式
        **Validates: Requirements 8.7**

        对于任何配置文件路径，POST /api/model/load_profile 的响应
        应始终是有效的JSON格式（无论成功或失败）。
        """
        response = self.client.post(
            "/api/model/load_profile",
            params={"profile_path": profile_path},
        )
        _assert_valid_json_response(response, "POST /api/model/load_profile")

    # --- POST /api/detect ---

    @settings(max_examples=100)
    @given(request_body=_detect_request_st)
    def test_detect_single_returns_valid_json(self, request_body: dict):
        """
        Feature: el-defect-detection, Property 20: JSON数据交换格式
        **Validates: Requirements 8.7**

        对于任何检测请求，POST /api/detect 的响应
        应始终是有效的JSON格式（无论成功或失败）。
        """
        response = self.client.post("/api/detect", json=request_body)
        _assert_valid_json_response(response, "POST /api/detect")

    # --- POST /api/detect/batch ---

    @settings(max_examples=100)
    @given(request_body=_batch_detect_request_st)
    def test_detect_batch_returns_valid_json(self, request_body: dict):
        """
        Feature: el-defect-detection, Property 20: JSON数据交换格式
        **Validates: Requirements 8.7**

        对于任何批量检测请求，POST /api/detect/batch 的响应
        应始终是有效的JSON格式（无论成功或失败）。
        """
        response = self.client.post("/api/detect/batch", json=request_body)
        _assert_valid_json_response(response, "POST /api/detect/batch")

    # --- POST /api/report/export_csv ---

    @settings(max_examples=100)
    @given(request_data=_csv_export_request_st)
    def test_export_csv_returns_valid_json(self, request_data: dict):
        """
        Feature: el-defect-detection, Property 20: JSON数据交换格式
        **Validates: Requirements 8.7**

        对于任何CSV导出请求，POST /api/report/export_csv 的响应
        应始终是有效的JSON格式（无论成功或失败）。
        """
        response = self.client.post(
            "/api/report/export_csv",
            params={"output_csv": request_data["output_csv"]},
            json=request_data["batch_result"],
        )
        _assert_valid_json_response(response, "POST /api/report/export_csv")
