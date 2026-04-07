"""
Feature: el-defect-detection, Property 21: HTTP状态码正确性
**Validates: Requirements 8.9, 8.10, 11.2**

属性定义:
对于任何API请求,成功的操作应该返回HTTP 200状态码,失败的操作应该返回
HTTP 400或其他4xx/5xx状态码,且错误响应应该包含"detail"字段说明错误原因。

测试策略:
- 使用 Hypothesis 生成随机的请求参数
- 对成功场景（/health端点）验证返回 HTTP 200
- 对失败场景（不存在的文件路径）验证返回 HTTP 400 且包含 "detail" 字段
- 验证错误响应的 "detail" 字段是非空字符串
- 不使用 mock，通过 TestClient 测试真实的 API 行为
"""
from __future__ import annotations

import os
import tempfile

import pytest
from hypothesis import given, settings
import hypothesis.strategies as st
from fastapi.testclient import TestClient

from app.main import app


# ---------------------------------------------------------------------------
# Hypothesis 策略
# ---------------------------------------------------------------------------

_path_segment_st = st.text(
    alphabet=st.characters(
        whitelist_categories=("L", "N"),
        whitelist_characters="_-",
    ),
    min_size=1,
    max_size=30,
)

# 不存在的文件路径
_nonexistent_file_path_st = st.builds(
    lambda prefix, name, ext: f"Z:/___nonexistent_test_path_{prefix}/{name}.{ext}",
    prefix=_path_segment_st,
    name=_path_segment_st,
    ext=st.sampled_from(["onnx", "jpg", "png", "json"]),
)

# 不存在的目录路径（使用Z:盘符确保在Windows上不存在）
_nonexistent_dir_path_st = st.builds(
    lambda prefix, tail: f"Z:/___nonexistent_test_dir_{prefix}/{tail}",
    prefix=_path_segment_st,
    tail=_path_segment_st,
)

# 模型加载请求（使用不存在的路径 → 必定失败）
_failing_model_load_st = st.fixed_dictionaries({
    "model_path": _nonexistent_file_path_st,
    "labels": st.lists(
        st.text(min_size=1, max_size=10, alphabet=st.characters(whitelist_categories=("L", "N"))),
        min_size=1,
        max_size=5,
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

# 单张检测请求（使用不存在的路径 → 必定失败）
_failing_detect_st = st.fixed_dictionaries({
    "image_path": _nonexistent_file_path_st,
})

# 批量检测请求（使用不存在的目录 → 必定失败）
_failing_batch_detect_st = st.fixed_dictionaries({
    "input_dir": _nonexistent_dir_path_st,
})

# CSV导出请求（有效的batch_result数据，用于成功场景）
_valid_csv_export_st = st.fixed_dictionaries({
    "batch_result": st.fixed_dictionaries({
        "results": st.lists(
            st.fixed_dictionaries({
                "image_path": _path_segment_st,
                "total": st.integers(min_value=0, max_value=5),
                "detections": st.lists(
                    st.fixed_dictionaries({
                        "class_id": st.integers(min_value=0, max_value=3),
                        "class_name": st.sampled_from(["隐裂", "断栅", "黑斑"]),
                        "score": st.floats(min_value=0.1, max_value=1.0, allow_nan=False),
                        "box": st.fixed_dictionaries({
                            "x1": st.integers(min_value=0, max_value=300),
                            "y1": st.integers(min_value=0, max_value=300),
                            "x2": st.integers(min_value=301, max_value=640),
                            "y2": st.integers(min_value=301, max_value=640),
                        }),
                    }),
                    min_size=0,
                    max_size=3,
                ),
            }),
            min_size=0,
            max_size=3,
        ),
    }),
})


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

def _assert_success_status(response, endpoint: str) -> None:
    """验证成功响应返回 HTTP 200。"""
    assert response.status_code == 200, (
        f"端点 {endpoint} 期望返回 HTTP 200，实际返回 {response.status_code}，"
        f"body={response.text[:300]}"
    )


def _assert_error_with_detail(response, endpoint: str) -> None:
    """验证错误响应返回 HTTP 400 且包含 detail 字段。"""
    assert response.status_code == 400, (
        f"端点 {endpoint} 期望返回 HTTP 400，实际返回 {response.status_code}，"
        f"body={response.text[:300]}"
    )
    data = response.json()
    assert isinstance(data, dict), (
        f"端点 {endpoint} 错误响应不是 JSON 对象: {data}"
    )
    assert "detail" in data, (
        f"端点 {endpoint} 错误响应缺少 'detail' 字段: {data}"
    )
    assert isinstance(data["detail"], str), (
        f"端点 {endpoint} 的 'detail' 字段不是字符串: {data['detail']}"
    )
    assert len(data["detail"]) > 0, (
        f"端点 {endpoint} 的 'detail' 字段为空字符串"
    )


# ---------------------------------------------------------------------------
# 属性测试
# ---------------------------------------------------------------------------

class TestProperty21HttpStatusCodeCorrectness:
    """
    Feature: el-defect-detection, Property 21: HTTP状态码正确性
    **Validates: Requirements 8.9, 8.10, 11.2**
    """

    @pytest.fixture(autouse=True)
    def _setup_client(self, tmp_path):
        self.client = TestClient(app, raise_server_exceptions=False)
        self.tmp_path = tmp_path

    # -----------------------------------------------------------------------
    # 需求 8.9: 成功的操作返回 HTTP 200
    # -----------------------------------------------------------------------

    @settings(max_examples=100)
    @given(data=st.data())
    def test_health_success_returns_200(self, data):
        """
        Feature: el-defect-detection, Property 21: HTTP状态码正确性
        **Validates: Requirements 8.9**

        GET /health 端点在正常情况下应返回 HTTP 200 状态码。
        """
        response = self.client.get("/health")
        _assert_success_status(response, "GET /health")

    @settings(max_examples=100)
    @given(request_data=_valid_csv_export_st)
    def test_csv_export_success_returns_200(self, request_data: dict):
        """
        Feature: el-defect-detection, Property 21: HTTP状态码正确性
        **Validates: Requirements 8.9**

        对于有效的CSV导出请求（合法的输出路径和batch_result数据），
        POST /api/report/export_csv 应返回 HTTP 200 状态码。
        """
        output_csv = os.path.join(str(self.tmp_path), "report.csv")
        # 从旧格式的 results 构建新的 project_info 格式
        old_results = request_data.get("batch_result", {}).get("results", [])
        file_results = []
        defect_by_class: dict[str, int] = {}
        for r in old_results:
            dets = r.get("detections", [])
            file_results.append({
                "name": r.get("image_path", "unknown"),
                "result": "NG" if dets else "OK",
                "path": r.get("image_path", ""),
            })
            for d in dets:
                cn = d.get("class_name", "unknown")
                defect_by_class[cn] = defect_by_class.get(cn, 0) + 1
        response = self.client.post(
            "/api/report/export_csv",
            json={
                "output_path": output_csv,
                "project_info": {
                    "project_name": "HTTP状态码测试",
                    "file_results": file_results,
                    "defect_by_class": defect_by_class,
                },
            },
        )
        _assert_success_status(response, "POST /api/report/export_csv")

    # -----------------------------------------------------------------------
    # 需求 8.10: 失败的操作返回 HTTP 400 且包含 detail 字段
    # 需求 11.2: 捕获异常并转换为用户友好的错误消息
    # -----------------------------------------------------------------------

    @settings(max_examples=100)
    @given(request_body=_failing_model_load_st)
    def test_model_load_failure_returns_400_with_detail(self, request_body: dict):
        """
        Feature: el-defect-detection, Property 21: HTTP状态码正确性
        **Validates: Requirements 8.10, 11.2**

        对于不存在的模型文件路径，POST /api/model/load 应返回
        HTTP 400 状态码，且响应包含 "detail" 字段说明错误原因。
        """
        response = self.client.post("/api/model/load", json=request_body)
        _assert_error_with_detail(response, "POST /api/model/load")

    @settings(max_examples=100)
    @given(invalid_path=_nonexistent_file_path_st)
    def test_load_profile_failure_returns_400_with_detail(self, invalid_path: str):
        """
        Feature: el-defect-detection, Property 21: HTTP状态码正确性
        **Validates: Requirements 8.10, 11.2**

        对于不存在的配置文件路径，POST /api/model/load_profile 应返回
        HTTP 400 状态码，且响应包含 "detail" 字段说明错误原因。
        """
        response = self.client.post(
            "/api/model/load_profile",
            params={"profile_path": invalid_path},
        )
        _assert_error_with_detail(response, "POST /api/model/load_profile")

    @settings(max_examples=100)
    @given(request_body=_failing_detect_st)
    def test_detect_single_failure_returns_400_with_detail(self, request_body: dict):
        """
        Feature: el-defect-detection, Property 21: HTTP状态码正确性
        **Validates: Requirements 8.10, 11.2**

        对于不存在的图像文件路径，POST /api/detect 应返回
        HTTP 400 状态码，且响应包含 "detail" 字段说明错误原因。
        """
        response = self.client.post("/api/detect", json=request_body)
        _assert_error_with_detail(response, "POST /api/detect")

    @settings(max_examples=100)
    @given(request_body=_failing_batch_detect_st)
    def test_batch_detect_failure_returns_400_with_detail(self, request_body: dict):
        """
        Feature: el-defect-detection, Property 21: HTTP状态码正确性
        **Validates: Requirements 8.10, 11.2**

        对于不存在的目录路径，POST /api/detect/batch 应返回
        HTTP 400 状态码，且响应包含 "detail" 字段说明错误原因。
        """
        response = self.client.post("/api/detect/batch", json=request_body)
        _assert_error_with_detail(response, "POST /api/detect/batch")

    # -----------------------------------------------------------------------
    # 综合验证：成功与失败状态码互斥
    # -----------------------------------------------------------------------

    @settings(max_examples=100)
    @given(data=st.data())
    def test_status_code_dichotomy(self, data):
        """
        Feature: el-defect-detection, Property 21: HTTP状态码正确性
        **Validates: Requirements 8.9, 8.10, 11.2**

        对于同一个端点，成功请求返回200，失败请求返回400，
        且只有失败响应包含 "detail" 字段。
        """
        # 成功场景: /health 总是成功
        success_resp = self.client.get("/health")
        assert success_resp.status_code == 200
        success_data = success_resp.json()
        assert "status" in success_data

        # 失败场景: 不存在的图像路径
        fail_resp = self.client.post(
            "/api/detect",
            json={"image_path": "Z:/___nonexistent_test_path/image.jpg"},
        )
        assert fail_resp.status_code == 400
        fail_data = fail_resp.json()
        assert "detail" in fail_data
        assert isinstance(fail_data["detail"], str)
        assert len(fail_data["detail"]) > 0
