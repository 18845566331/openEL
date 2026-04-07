"""
并发单元测试 — 测试具体的并发场景和边界情况。

**Validates: Requirements 12.6, 12.7**

需求 12.6: 系统在推理过程中使用线程锁保证线程安全
需求 12.7: 后端服务支持并发API请求

与 test_property_concurrency.py 的区别:
- 本文件使用 pytest 编写具体场景的单元测试（非属性测试）
- 测试固定数量的并发请求和特定的请求组合
- 验证具体的边界情况和错误场景
"""
from __future__ import annotations

import os
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed

import pytest
from fastapi.testclient import TestClient

from app.main import app, engine


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def client() -> TestClient:
    return TestClient(app, raise_server_exceptions=False)


# ---------------------------------------------------------------------------
# 1. 多个并发检测请求（/api/detect）
# ---------------------------------------------------------------------------

class TestConcurrentDetectRequests:
    """测试多个并发检测请求的线程安全性。"""

    def test_concurrent_detect_with_nonexistent_images(self, client: TestClient) -> None:
        """多个并发检测请求（图像不存在）应全部返回400错误，无崩溃。"""
        num_requests = 10

        def send_detect(idx: int):
            return client.post("/api/detect", json={
                "image_path": f"/nonexistent/image_{idx}.jpg",
            })

        with ThreadPoolExecutor(max_workers=5) as executor:
            futures = [executor.submit(send_detect, i) for i in range(num_requests)]
            responses = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

        assert len(responses) == num_requests
        for resp in responses:
            assert resp.status_code == 400
            data = resp.json()
            assert "detail" in data

    def test_concurrent_detect_all_return_valid_json(self, client: TestClient) -> None:
        """并发检测请求的响应都应该是有效的JSON格式。"""
        num_requests = 8

        def send_detect(idx: int):
            return client.post("/api/detect", json={
                "image_path": f"/tmp/fake_image_{idx}.png",
                "confidence_threshold": 0.5,
                "iou_threshold": 0.4,
            })

        with ThreadPoolExecutor(max_workers=4) as executor:
            futures = [executor.submit(send_detect, i) for i in range(num_requests)]
            responses = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

        assert len(responses) == num_requests
        for resp in responses:
            # 应该能成功解析JSON（无论成功还是失败）
            data = resp.json()
            assert isinstance(data, dict)

    def test_concurrent_detect_with_different_thresholds(self, client: TestClient) -> None:
        """并发发送不同阈值参数的检测请求，验证参数不会互相干扰。"""
        thresholds = [0.1, 0.3, 0.5, 0.7, 0.9]

        def send_detect(conf: float):
            return client.post("/api/detect", json={
                "image_path": "/nonexistent/test.jpg",
                "confidence_threshold": conf,
                "iou_threshold": 0.45,
            })

        with ThreadPoolExecutor(max_workers=5) as executor:
            futures = {
                executor.submit(send_detect, t): t for t in thresholds
            }
            for future in as_completed(futures, timeout=30):
                resp = future.result(timeout=10)
                # 所有请求都应该返回有效响应（400因为图像不存在）
                assert resp.status_code in {200, 400, 422}


# ---------------------------------------------------------------------------
# 2. 并发模型加载请求（/api/model/load）
# ---------------------------------------------------------------------------

class TestConcurrentModelLoad:
    """测试并发模型加载请求的线程安全性。"""

    def test_concurrent_model_load_with_invalid_paths(self, client: TestClient) -> None:
        """多个并发模型加载请求（无效路径）应全部返回400错误，无死锁。"""
        num_requests = 6

        def send_load(idx: int):
            return client.post("/api/model/load", json={
                "model_path": f"/nonexistent/model_{idx}.onnx",
                "labels": ["隐裂", "断栅"],
                "input_width": 640,
                "input_height": 640,
            })

        with ThreadPoolExecutor(max_workers=4) as executor:
            futures = [executor.submit(send_load, i) for i in range(num_requests)]
            responses = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

        assert len(responses) == num_requests
        for resp in responses:
            assert resp.status_code == 400
            data = resp.json()
            assert "detail" in data

    def test_concurrent_model_load_no_deadlock(self, client: TestClient) -> None:
        """并发模型加载请求不应导致死锁（RLock可重入锁验证）。"""
        num_requests = 4

        def send_load(idx: int):
            return client.post("/api/model/load", json={
                "model_path": f"/tmp/nonexistent_model_{idx}.onnx",
                "labels": [f"defect_{idx}"],
                "input_width": 320,
                "input_height": 320,
                "output_layout": "cxcywh_obj_cls",
            })

        with ThreadPoolExecutor(max_workers=4) as executor:
            futures = [executor.submit(send_load, i) for i in range(num_requests)]
            # 如果发生死锁，as_completed 会超时
            responses = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

        # 所有请求都应该完成（无死锁）
        assert len(responses) == num_requests

    def test_concurrent_load_profile_with_invalid_paths(self, client: TestClient) -> None:
        """并发通过配置文件加载模型（无效路径）应全部返回400。"""
        num_requests = 5

        def send_load_profile(idx: int):
            return client.post(
                "/api/model/load_profile",
                params={"profile_path": f"/nonexistent/profile_{idx}.json"},
            )

        with ThreadPoolExecutor(max_workers=3) as executor:
            futures = [executor.submit(send_load_profile, i) for i in range(num_requests)]
            responses = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

        assert len(responses) == num_requests
        for resp in responses:
            assert resp.status_code == 400


# ---------------------------------------------------------------------------
# 3. 混合并发请求（不同类型的请求同时发送）
# ---------------------------------------------------------------------------

class TestMixedConcurrentRequests:
    """测试不同类型的请求同时发送时的线程安全性。"""

    def test_mixed_health_and_detect(self, client: TestClient) -> None:
        """同时发送健康检查和检测请求，验证互不干扰。"""
        def send_health():
            return ("health", client.get("/health"))

        def send_detect():
            return ("detect", client.post("/api/detect", json={
                "image_path": "/nonexistent/test.jpg",
            }))

        with ThreadPoolExecutor(max_workers=6) as executor:
            futures = []
            for _ in range(5):
                futures.append(executor.submit(send_health))
                futures.append(executor.submit(send_detect))

            results = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

        assert len(results) == 10
        health_results = [r for r in results if r[0] == "health"]
        detect_results = [r for r in results if r[0] == "detect"]

        # 健康检查应该全部成功
        for _, resp in health_results:
            assert resp.status_code == 200

        # 检测请求应该返回400（图像不存在或模型未加载）
        for _, resp in detect_results:
            assert resp.status_code == 400

    def test_mixed_load_detect_health(self, client: TestClient) -> None:
        """同时发送模型加载、检测和健康检查请求。"""
        def send_health():
            return "health", client.get("/health")

        def send_detect():
            return "detect", client.post("/api/detect", json={
                "image_path": "/nonexistent/img.jpg",
            })

        def send_load():
            return "load", client.post("/api/model/load", json={
                "model_path": "/nonexistent/model.onnx",
                "labels": ["隐裂"],
            })

        with ThreadPoolExecutor(max_workers=6) as executor:
            futures = []
            for _ in range(3):
                futures.append(executor.submit(send_health))
                futures.append(executor.submit(send_detect))
                futures.append(executor.submit(send_load))

            results = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

        # 所有9个请求都应该完成
        assert len(results) == 9
        for req_type, resp in results:
            assert resp.status_code in {200, 400, 422}, (
                f"请求类型 {req_type} 返回了意外的状态码 {resp.status_code}"
            )

    def test_mixed_batch_and_csv_export(self, client: TestClient) -> None:
        """同时发送批量检测和CSV导出请求。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            def send_batch():
                return "batch", client.post("/api/detect/batch", json={
                    "input_dir": "/nonexistent/batch_dir",
                })

            def send_csv(idx: int):
                output_csv = os.path.join(tmp_dir, f"report_{idx}.csv")
                return "csv", client.post(
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
                                    "score": 0.85,
                                    "box": {"x1": 10, "y1": 20, "x2": 100, "y2": 200},
                                }],
                            }],
                            "defect_by_class": {"隐裂": 1},
                        },
                    },
                )

            with ThreadPoolExecutor(max_workers=6) as executor:
                futures = []
                for i in range(3):
                    futures.append(executor.submit(send_batch))
                    futures.append(executor.submit(send_csv, i))

                results = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

            assert len(results) == 6
            for req_type, resp in results:
                if req_type == "csv":
                    assert resp.status_code == 200
                else:
                    # 批量检测因目录不存在返回400
                    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# 4. 验证并发请求后系统状态一致
# ---------------------------------------------------------------------------

class TestConcurrentStateConsistency:
    """验证并发请求后系统状态保持一致，无数据竞争。"""

    def test_state_consistent_after_concurrent_health_checks(self, client: TestClient) -> None:
        """大量并发健康检查后，引擎状态应保持一致。"""
        num_requests = 20

        with ThreadPoolExecutor(max_workers=10) as executor:
            futures = [
                executor.submit(lambda: client.get("/health"))
                for _ in range(num_requests)
            ]
            responses = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

        assert len(responses) == num_requests

        # 收集所有 model_loaded 状态
        states = set()
        for resp in responses:
            assert resp.status_code == 200
            data = resp.json()
            runtime = data.get("runtime", {})
            if runtime:
                states.add(runtime.get("model_loaded"))

        # 所有并发请求看到的状态应该一致
        assert len(states) <= 1, f"并发健康检查返回了不一致的状态: {states}"

    def test_engine_describe_consistent_under_concurrent_reads(self) -> None:
        """直接调用引擎的 describe() 方法进行并发读取，验证无数据竞争。"""
        num_reads = 20

        with ThreadPoolExecutor(max_workers=8) as executor:
            futures = [executor.submit(engine.describe) for _ in range(num_reads)]
            results = [f.result(timeout=10) for f in as_completed(futures, timeout=30)]

        assert len(results) == num_reads

        # 所有结果的 model_loaded 字段应该一致
        loaded_values = {r["model_loaded"] for r in results}
        assert len(loaded_values) == 1, (
            f"并发 describe() 返回了不一致的 model_loaded: {loaded_values}"
        )

    def test_concurrent_csv_exports_produce_valid_files(self, client: TestClient) -> None:
        """并发CSV导出到不同文件，验证每个文件内容完整无损坏。"""
        num_exports = 6
        batch_data = {
            "results": [
                {
                    "image_path": f"/test/img_{i}.jpg",
                    "total": 2,
                    "detections": [
                        {
                            "class_id": 0,
                            "class_name": "隐裂",
                            "score": 0.90,
                            "box": {"x1": 10, "y1": 20, "x2": 100, "y2": 200},
                        },
                        {
                            "class_id": 1,
                            "class_name": "断栅",
                            "score": 0.75,
                            "box": {"x1": 200, "y1": 300, "x2": 400, "y2": 500},
                        },
                    ],
                }
                for i in range(5)
            ],
        }

        with tempfile.TemporaryDirectory() as tmp_dir:
            def export_csv(idx: int):
                output_csv = os.path.join(tmp_dir, f"concurrent_report_{idx}.csv")
                return client.post(
                    "/api/report/export_csv",
                    json={
                        "output_path": output_csv,
                        "project_info": {
                            "project_name": "并发CSV测试",
                            "file_results": [
                                {
                                    "name": f"img_{i}.jpg",
                                    "result": "NG",
                                    "path": f"/test/img_{i}.jpg",
                                    "detections": [
                                        {"class_id": 0, "class_name": "隐裂", "score": 0.90, "box": {"x1": 10, "y1": 20, "x2": 100, "y2": 200}},
                                        {"class_id": 1, "class_name": "断栅", "score": 0.75, "box": {"x1": 200, "y1": 300, "x2": 400, "y2": 500}},
                                    ],
                                }
                                for i in range(5)
                            ],
                            "defect_by_class": {"隐裂": 5, "断栅": 5},
                        },
                    },
                )

            with ThreadPoolExecutor(max_workers=6) as executor:
                futures = [executor.submit(export_csv, i) for i in range(num_exports)]
                responses = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

            assert len(responses) == num_exports
            for resp in responses:
                assert resp.status_code == 200

            # 验证每个CSV文件内容完整
            for i in range(num_exports):
                csv_path = os.path.join(tmp_dir, f"concurrent_report_{i}.csv")
                assert os.path.exists(csv_path), f"CSV文件不存在: {csv_path}"
                with open(csv_path, encoding="utf-8-sig") as f:
                    content = f.read()
                # 验证包含项目信息和文件结果
                assert "项目名称" in content
                assert "文件名" in content
                assert "检测结果" in content

    def test_no_state_corruption_after_mixed_requests(self, client: TestClient) -> None:
        """混合并发请求后，引擎状态不应被破坏。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            # 先记录初始状态
            initial_resp = client.get("/health")
            initial_state = initial_resp.json().get("runtime", {}).get("model_loaded")

            # 发送混合并发请求
            def send_request(idx: int):
                if idx % 3 == 0:
                    return client.get("/health")
                elif idx % 3 == 1:
                    return client.post("/api/detect", json={
                        "image_path": "/nonexistent/img.jpg",
                    })
                else:
                    output_csv = os.path.join(tmp_dir, f"state_test_{idx}.csv")
                    return client.post(
                        "/api/report/export_csv",
                        json={
                            "output_path": output_csv,
                            "project_info": {
                                "project_name": "状态测试",
                                "file_results": [],
                                "defect_by_class": {},
                            },
                        },
                    )

            with ThreadPoolExecutor(max_workers=6) as executor:
                futures = [executor.submit(send_request, i) for i in range(12)]
                responses = [f.result(timeout=15) for f in as_completed(futures, timeout=30)]

            assert len(responses) == 12

            # 验证最终状态与初始状态一致（无状态破坏）
            final_resp = client.get("/health")
            final_state = final_resp.json().get("runtime", {}).get("model_loaded")
            assert initial_state == final_state, (
                f"并发请求后状态不一致: 初始={initial_state}, 最终={final_state}"
            )
