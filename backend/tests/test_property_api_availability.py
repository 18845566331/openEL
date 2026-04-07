"""
Feature: el-defect-detection, Property 19: API端点可用性
**Validates: Requirements 8.1, 8.2, 8.3, 8.4, 8.5, 8.6**

属性定义:
对于任何已定义的API端点(/health, /api/model/load, /api/model/load_profile,
/api/detect, /api/detect/batch, /api/report/export_csv),发送正确格式的请求
应该返回有效的响应(成功或错误),而不是连接失败或404错误。

测试策略:
- 使用 Hypothesis 生成随机的请求参数
- 对所有6个API端点发送正确格式的请求
- 验证所有端点返回有效的HTTP响应(200或400),而不是404或500
- 验证响应体是有效的JSON格式
- 不使用 mock，通过 TestClient 测试真实的 API 行为
"""
from __future__ import annotations

import pytest
from hypothesis import given, settings
import hypothesis.strategies as st
from fastapi.testclient import TestClient

from app.main import app


# ---------------------------------------------------------------------------
# Hypothesis 策略：生成随机请求参数
# ---------------------------------------------------------------------------

# 路径段策略
_path_segment_st = st.text(
    alphabet=st.characters(
        whitelist_categories=("L", "N"),
        whitelist_characters="_-./",
    ),
    min_size=1,
    max_size=50,
)

# 模型加载请求参数策略
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

# 单张检测请求参数策略
_detect_request_st = st.fixed_dictionaries({
    "image_path": _path_segment_st,
}, optional={
    "confidence_threshold": st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
    "iou_threshold": st.floats(min_value=0.0, max_value=1.0, allow_nan=False),
    "save_visualization": st.booleans(),
    "visualization_dir": st.one_of(st.none(), _path_segment_st),
})

# 批量检测请求参数策略
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

# CSV导出请求参数策略
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

# 配置文件路径策略
_profile_path_st = _path_segment_st

# 有效的HTTP状态码集合（不包含404和5xx）
VALID_STATUS_CODES = {200, 400, 422}


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

def _assert_valid_response(response, endpoint: str) -> None:
    """验证响应是有效的HTTP响应，不是404或5xx错误。"""
    assert response.status_code in VALID_STATUS_CODES, (
        f"端点 {endpoint} 返回了意外的状态码 {response.status_code}，"
        f"期望 {VALID_STATUS_CODES} 之一，body={response.text}"
    )
    # 验证响应体是有效的JSON
    data = response.json()
    assert isinstance(data, (dict, list)), (
        f"端点 {endpoint} 返回的不是有效的JSON对象: {data}"
    )


# ---------------------------------------------------------------------------
# 属性测试
# ---------------------------------------------------------------------------

class TestProperty19ApiEndpointAvailability:
    """
    Feature: el-defect-detection, Property 19: API端点可用性
    **Validates: Requirements 8.1, 8.2, 8.3, 8.4, 8.5, 8.6**
    """

    @pytest.fixture(autouse=True)
    def _setup_client(self):
        self.client = TestClient(app, raise_server_exceptions=False)

    # --- 需求 8.1: 健康检查端点 GET /health ---

    @settings(max_examples=100)
    @given(data=st.data())
    def test_health_endpoint_available(self, data):
        """
        Feature: el-defect-detection, Property 19: API端点可用性
        **Validates: Requirements 8.1**

        GET /health 端点应始终返回有效的HTTP响应(200或400),
        而不是404或连接失败。
        """
        response = self.client.get("/health")
        _assert_valid_response(response, "GET /health")

    # --- 需求 8.2: 模型加载端点 POST /api/model/load ---

    @settings(max_examples=100)
    @given(request_body=_model_load_request_st)
    def test_model_load_endpoint_available(self, request_body: dict):
        """
        Feature: el-defect-detection, Property 19: API端点可用性
        **Validates: Requirements 8.2**

        对于任何正确格式的模型加载请求，POST /api/model/load 端点
        应返回有效的HTTP响应(200或400),而不是404或连接失败。
        """
        response = self.client.post("/api/model/load", json=request_body)
        _assert_valid_response(response, "POST /api/model/load")

    # --- 需求 8.3: 配置文件加载端点 POST /api/model/load_profile ---

    @settings(max_examples=100)
    @given(profile_path=_profile_path_st)
    def test_model_load_profile_endpoint_available(self, profile_path: str):
        """
        Feature: el-defect-detection, Property 19: API端点可用性
        **Validates: Requirements 8.3**

        对于任何配置文件路径，POST /api/model/load_profile 端点
        应返回有效的HTTP响应(200或400),而不是404或连接失败。
        """
        response = self.client.post(
            "/api/model/load_profile",
            params={"profile_path": profile_path},
        )
        _assert_valid_response(response, "POST /api/model/load_profile")

    # --- 需求 8.4: 单张检测端点 POST /api/detect ---

    @settings(max_examples=100)
    @given(request_body=_detect_request_st)
    def test_detect_single_endpoint_available(self, request_body: dict):
        """
        Feature: el-defect-detection, Property 19: API端点可用性
        **Validates: Requirements 8.4**

        对于任何正确格式的检测请求，POST /api/detect 端点
        应返回有效的HTTP响应(200或400),而不是404或连接失败。
        """
        response = self.client.post("/api/detect", json=request_body)
        _assert_valid_response(response, "POST /api/detect")

    # --- 需求 8.5: 批量检测端点 POST /api/detect/batch ---

    @settings(max_examples=100)
    @given(request_body=_batch_detect_request_st)
    def test_detect_batch_endpoint_available(self, request_body: dict):
        """
        Feature: el-defect-detection, Property 19: API端点可用性
        **Validates: Requirements 8.5**

        对于任何正确格式的批量检测请求，POST /api/detect/batch 端点
        应返回有效的HTTP响应(200或400),而不是404或连接失败。
        """
        response = self.client.post("/api/detect/batch", json=request_body)
        _assert_valid_response(response, "POST /api/detect/batch")

    # --- 需求 8.6: CSV报告导出端点 POST /api/report/export_csv ---

    @settings(max_examples=100)
    @given(request_data=_csv_export_request_st)
    def test_export_csv_endpoint_available(self, request_data: dict):
        """
        Feature: el-defect-detection, Property 19: API端点可用性
        **Validates: Requirements 8.6**

        对于任何正确格式的CSV导出请求，POST /api/report/export_csv 端点
        应返回有效的HTTP响应(200或400),而不是404或连接失败。
        """
        response = self.client.post(
            "/api/report/export_csv",
            params={"output_csv": request_data["output_csv"]},
            json=request_data["batch_result"],
        )
        _assert_valid_response(response, "POST /api/report/export_csv")
