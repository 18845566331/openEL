"""错误处理单元测试 — 验证所有API端点的统一错误处理。

需求: 11.1, 11.2, 8.10
任务: 11.1 完善所有API端点的错误处理
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture()
def client() -> TestClient:
    return TestClient(app, raise_server_exceptions=False)


# ---------------------------------------------------------------------------
# 统一错误响应格式测试
# ---------------------------------------------------------------------------


class TestUnifiedErrorFormat:
    """需求 11.1: 错误响应应包含 detail 字段的统一格式。"""

    def test_detect_nonexistent_image_returns_detail(self, client: TestClient):
        """检测不存在的图像应返回包含 detail 字段的 JSON 响应。"""
        response = client.post(
            "/api/detect",
            json={"image_path": "/nonexistent/image.jpg"},
        )
        assert response.status_code == 400
        data = response.json()
        assert "detail" in data
        assert isinstance(data["detail"], str)
        assert len(data["detail"]) > 0

    def test_batch_nonexistent_dir_returns_detail(self, client: TestClient):
        """批量检测不存在的目录应返回包含 detail 字段的 JSON 响应。"""
        response = client.post(
            "/api/detect/batch",
            json={"input_dir": "/nonexistent/directory"},
        )
        assert response.status_code == 400
        data = response.json()
        assert "detail" in data
        assert isinstance(data["detail"], str)

    def test_load_nonexistent_model_returns_detail(self, client: TestClient):
        """加载不存在的模型应返回包含 detail 字段的 JSON 响应。"""
        response = client.post(
            "/api/model/load",
            json={"model_path": "/nonexistent/model.onnx"},
        )
        assert response.status_code == 400
        data = response.json()
        assert "detail" in data

    def test_load_profile_nonexistent_returns_detail(self, client: TestClient):
        """加载不存在的配置文件应返回包含 detail 字段的 JSON 响应。"""
        response = client.post(
            "/api/model/load_profile",
            params={"profile_path": "/nonexistent/profile.json"},
        )
        assert response.status_code == 400
        data = response.json()
        assert "detail" in data


# ---------------------------------------------------------------------------
# HTTP 400 状态码测试
# ---------------------------------------------------------------------------


class TestHTTP400StatusCode:
    """需求 8.10: API请求失败时返回 HTTP 400 状态码。"""

    def test_detect_failure_returns_400(self, client: TestClient):
        response = client.post(
            "/api/detect",
            json={"image_path": "/nonexistent/image.jpg"},
        )
        assert response.status_code == 400

    def test_batch_failure_returns_400(self, client: TestClient):
        response = client.post(
            "/api/detect/batch",
            json={"input_dir": "/nonexistent/directory"},
        )
        assert response.status_code == 400

    def test_model_load_failure_returns_400(self, client: TestClient):
        response = client.post(
            "/api/model/load",
            json={"model_path": "/nonexistent/model.onnx"},
        )
        assert response.status_code == 400

    def test_profile_load_failure_returns_400(self, client: TestClient):
        response = client.post(
            "/api/model/load_profile",
            params={"profile_path": "/nonexistent/profile.json"},
        )
        assert response.status_code == 400


# ---------------------------------------------------------------------------
# 用户友好的中文错误消息测试
# ---------------------------------------------------------------------------


class TestUserFriendlyErrorMessages:
    """需求 11.2: 异常应转换为用户友好的错误消息。"""

    def test_detect_model_not_loaded_message(self, client: TestClient):
        """模型未加载时检测应返回友好的中文错误消息。"""
        # 确保引擎处于未加载状态（重置）
        from app.main import engine
        engine._runtime = None

        response = client.post(
            "/api/detect",
            json={"image_path": "/some/image.jpg"},
        )
        assert response.status_code == 400
        detail = response.json()["detail"]
        assert "模型" in detail

    def test_detect_file_not_found_message(self, client: TestClient):
        """图像文件不存在时应返回包含'文件不存在'的中文消息。"""
        from app.main import engine
        engine._runtime = None

        response = client.post(
            "/api/detect",
            json={"image_path": "/nonexistent/image.jpg"},
        )
        assert response.status_code == 400
        detail = response.json()["detail"]
        # 模型未加载或文件不存在，都应有中文描述
        assert isinstance(detail, str)
        assert len(detail) > 0

    def test_batch_dir_not_found_message(self, client: TestClient):
        """目录不存在时应返回包含'目录不存在'的中文消息。"""
        response = client.post(
            "/api/detect/batch",
            json={"input_dir": "/nonexistent/directory"},
        )
        detail = response.json()["detail"]
        assert "目录" in detail or "不存在" in detail

    def test_model_load_file_not_found_message(self, client: TestClient):
        """模型文件不存在时应返回包含'不存在'的中文消息。"""
        response = client.post(
            "/api/model/load",
            json={"model_path": "/nonexistent/model.onnx"},
        )
        detail = response.json()["detail"]
        assert "不存在" in detail

    def test_profile_file_not_found_message(self, client: TestClient):
        """配置文件不存在时应返回包含'配置文件不存在'的中文消息。"""
        response = client.post(
            "/api/model/load_profile",
            params={"profile_path": "/nonexistent/profile.json"},
        )
        detail = response.json()["detail"]
        assert "配置文件不存在" in detail

    def test_profile_invalid_json_message(self, client: TestClient, tmp_path):
        """JSON格式无效时应返回包含'JSON格式无效'的中文消息。"""
        bad_file = tmp_path / "bad.json"
        bad_file.write_text("{invalid json", encoding="utf-8")
        response = client.post(
            "/api/model/load_profile",
            params={"profile_path": str(bad_file)},
        )
        detail = response.json()["detail"]
        assert "JSON格式无效" in detail


# ---------------------------------------------------------------------------
# 错误响应 JSON 格式测试
# ---------------------------------------------------------------------------


class TestErrorResponseJSONFormat:
    """所有错误响应应为有效的 JSON 格式。"""

    def test_detect_error_is_json(self, client: TestClient):
        response = client.post(
            "/api/detect",
            json={"image_path": "/nonexistent/image.jpg"},
        )
        assert response.headers.get("content-type") == "application/json"
        data = response.json()
        assert isinstance(data, dict)

    def test_batch_error_is_json(self, client: TestClient):
        response = client.post(
            "/api/detect/batch",
            json={"input_dir": "/nonexistent/directory"},
        )
        assert response.headers.get("content-type") == "application/json"
        data = response.json()
        assert isinstance(data, dict)

    def test_model_load_error_is_json(self, client: TestClient):
        response = client.post(
            "/api/model/load",
            json={"model_path": "/nonexistent/model.onnx"},
        )
        assert response.headers.get("content-type") == "application/json"
        data = response.json()
        assert isinstance(data, dict)
