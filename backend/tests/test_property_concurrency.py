"""
Feature: el-defect-detection, Property 22: 并发请求线程安全
**Validates: Requirements 12.6, 12.7**

属性定义:
对于任何并发的API请求序列,系统应该正确处理所有请求而不出现数据竞争、
死锁或状态不一致的情况。

测试策略:
- 使用 Hypothesis 生成随机的并发请求序列（请求类型和数量）
- 使用 concurrent.futures.ThreadPoolExecutor 并发发送请求
- 验证所有请求都返回有效的HTTP响应（无死锁、无崩溃）
- 验证并发请求后引擎状态保持一致（无数据竞争）
- 不使用 mock，通过 TestClient 测试真实的 API 行为
"""
from __future__ import annotations

import os
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

import pytest
from hypothesis import given, settings, HealthCheck
import hypothesis.strategies as st
from fastapi.testclient import TestClient

from app.main import app


# ---------------------------------------------------------------------------
# 有效的HTTP状态码集合（不包含5xx服务器错误）
# ---------------------------------------------------------------------------
VALID_STATUS_CODES = {200, 400, 422}


# ---------------------------------------------------------------------------
# Hypothesis 策略
# ---------------------------------------------------------------------------

# 并发请求类型
_request_type_st = st.sampled_from([
    "health",
    "detect",
    "batch",
    "export_csv",
])

# 并发请求序列：2~8个并发请求
_concurrent_requests_st = st.lists(
    _request_type_st,
    min_size=2,
    max_size=8,
)

# 并发线程数
_num_workers_st = st.integers(min_value=2, max_value=6)


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

def _send_request(client: TestClient, request_type: str, tmp_dir: str) -> dict[str, Any]:
    """根据请求类型发送对应的API请求，返回状态码和响应数据。"""
    if request_type == "health":
        resp = client.get("/health")
    elif request_type == "detect":
        resp = client.post("/api/detect", json={
            "image_path": "/nonexistent/test_image.jpg",
        })
    elif request_type == "batch":
        resp = client.post("/api/detect/batch", json={
            "input_dir": "/nonexistent/batch_dir",
        })
    elif request_type == "export_csv":
        output_csv = os.path.join(tmp_dir, "concurrent_test.csv")
        resp = client.post(
            "/api/report/export_csv",
            json={
                "output_path": output_csv,
                "project_info": {
                    "project_name": "并发测试",
                    "file_results": [{
                        "name": "img.jpg",
                        "result": "NG",
                        "path": "/test/img.jpg",
                        "detections": [{
                            "class_id": 0,
                            "class_name": "隐裂",
                            "score": 0.9,
                            "box": {"x1": 0, "y1": 0, "x2": 100, "y2": 100},
                        }],
                    }],
                    "defect_by_class": {"隐裂": 1},
                },
            },
        )
    else:
        resp = client.get("/health")

    return {
        "request_type": request_type,
        "status_code": resp.status_code,
        "body": resp.json(),
    }


# ---------------------------------------------------------------------------
# 属性测试
# ---------------------------------------------------------------------------

class TestProperty22ConcurrencyThreadSafety:
    """
    Feature: el-defect-detection, Property 22: 并发请求线程安全
    **Validates: Requirements 12.6, 12.7**
    """

    @pytest.fixture(autouse=True)
    def _setup(self):
        self.client = TestClient(app, raise_server_exceptions=False)

    @settings(max_examples=100, suppress_health_check=[HealthCheck.too_slow])
    @given(
        request_types=_concurrent_requests_st,
        num_workers=_num_workers_st,
    )
    def test_concurrent_requests_no_crash_or_deadlock(
        self,
        request_types: list[str],
        num_workers: int,
    ) -> None:
        """
        Feature: el-defect-detection, Property 22: 并发请求线程安全
        **Validates: Requirements 12.6, 12.7**

        对于任何并发的API请求序列，所有请求都应该返回有效的HTTP响应，
        不出现死锁（超时）或崩溃（5xx错误）。
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            futures = []
            with ThreadPoolExecutor(max_workers=num_workers) as executor:
                for req_type in request_types:
                    futures.append(
                        executor.submit(_send_request, self.client, req_type, tmp_dir)
                    )

                results = []
                for future in as_completed(futures, timeout=30):
                    result = future.result(timeout=10)
                    results.append(result)

            # 验证：所有请求都返回了有效的HTTP响应
            assert len(results) == len(request_types), (
                f"期望 {len(request_types)} 个响应，实际收到 {len(results)} 个"
            )

            for result in results:
                assert result["status_code"] in VALID_STATUS_CODES, (
                    f"并发请求 {result['request_type']} 返回了意外的状态码 "
                    f"{result['status_code']}，body={result['body']}"
                )

    @settings(max_examples=100, suppress_health_check=[HealthCheck.too_slow])
    @given(
        num_concurrent=st.integers(min_value=2, max_value=8),
    )
    def test_concurrent_health_checks_consistent_state(
        self,
        num_concurrent: int,
    ) -> None:
        """
        Feature: el-defect-detection, Property 22: 并发请求线程安全
        **Validates: Requirements 12.6, 12.7**

        对于任何数量的并发健康检查请求，所有响应中的引擎状态应该一致
        （model_loaded 字段值相同），不出现数据竞争导致的状态不一致。
        """
        futures = []
        with ThreadPoolExecutor(max_workers=num_concurrent) as executor:
            for _ in range(num_concurrent):
                futures.append(
                    executor.submit(lambda: self.client.get("/health"))
                )

            responses = []
            for future in as_completed(futures, timeout=30):
                resp = future.result(timeout=10)
                responses.append(resp)

        # 验证：所有响应都是有效的
        assert len(responses) == num_concurrent

        # 验证：所有响应中的 model_loaded 状态一致（无数据竞争）
        model_loaded_values = set()
        for resp in responses:
            assert resp.status_code in VALID_STATUS_CODES
            data = resp.json()
            if "runtime" in data and data["runtime"] is not None:
                model_loaded_values.add(data["runtime"].get("model_loaded"))

        # 所有并发请求看到的 model_loaded 状态应该相同
        assert len(model_loaded_values) <= 1, (
            f"并发健康检查返回了不一致的 model_loaded 状态: {model_loaded_values}"
        )

    @settings(max_examples=100, suppress_health_check=[HealthCheck.too_slow])
    @given(
        num_concurrent=st.integers(min_value=2, max_value=6),
    )
    def test_concurrent_csv_exports_no_corruption(
        self,
        num_concurrent: int,
    ) -> None:
        """
        Feature: el-defect-detection, Property 22: 并发请求线程安全
        **Validates: Requirements 12.6, 12.7**

        对于任何数量的并发CSV导出请求（写入不同文件），所有请求都应该
        成功完成，不出现文件损坏或数据竞争。
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            batch_result = {
                "results": [
                    {
                        "image_path": f"/test/img_{i}.jpg",
                        "total": 1,
                        "detections": [
                            {
                                "class_id": 0,
                                "class_name": "隐裂",
                                "score": 0.85,
                                "box": {"x1": 10, "y1": 20, "x2": 100, "y2": 200},
                            }
                        ],
                    }
                    for i in range(3)
                ]
            }

            def export_csv(idx: int):
                output_csv = os.path.join(tmp_dir, f"report_{idx}.csv")
                return self.client.post(
                    "/api/report/export_csv",
                    json={
                        "output_path": output_csv,
                        "project_info": {
                            "project_name": "并发CSV导出测试",
                            "file_results": [
                                {
                                    "name": f"img_{i}.jpg",
                                    "result": "NG",
                                    "path": f"/test/img_{i}.jpg",
                                    "detections": [{
                                        "class_id": 0,
                                        "class_name": "隐裂",
                                        "score": 0.85,
                                        "box": {"x1": 10, "y1": 20, "x2": 100, "y2": 200},
                                    }],
                                }
                                for i in range(3)
                            ],
                            "defect_by_class": {"隐裂": 3},
                        },
                    },
                )

            futures = []
            with ThreadPoolExecutor(max_workers=num_concurrent) as executor:
                for i in range(num_concurrent):
                    futures.append(executor.submit(export_csv, i))

                responses = []
                for future in as_completed(futures, timeout=30):
                    resp = future.result(timeout=10)
                    responses.append(resp)

            # 验证：所有导出请求都成功
            assert len(responses) == num_concurrent
            for resp in responses:
                assert resp.status_code == 200, (
                    f"并发CSV导出返回了意外的状态码 {resp.status_code}，"
                    f"body={resp.text}"
                )
                data = resp.json()
                assert "output_path" in data

            # 验证：所有CSV文件都存在且不为空
            for i in range(num_concurrent):
                csv_path = os.path.join(tmp_dir, f"report_{i}.csv")
                assert os.path.exists(csv_path), f"CSV文件不存在: {csv_path}"
                assert os.path.getsize(csv_path) > 0, f"CSV文件为空: {csv_path}"
