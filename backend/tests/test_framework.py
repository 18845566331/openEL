"""后端框架单元测试 — 验证 FastAPI 应用启动、健康检查端点和 CORS 配置。

需求: 8.1, 8.8
"""
from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import app


def test_app_startup():
    """测试 FastAPI 应用能够正常创建测试客户端。"""
    client = TestClient(app)
    assert client is not None


def test_health_endpoint(client: TestClient):
    """测试 GET /health 返回 200 和正确的 JSON 结构。

    需求 8.1: 后端服务 SHALL 提供健康检查端点(GET /health)
    """
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert "runtime" in data


def test_health_runtime_fields(client: TestClient):
    """测试健康检查返回的 runtime 字段包含必要信息。"""
    response = client.get("/health")
    runtime = response.json()["runtime"]
    assert "model_loaded" in runtime
    assert "backend" in runtime
    assert "labels" in runtime


def test_cors_preflight(client: TestClient):
    """测试 CORS 预检请求返回正确的 Access-Control 头。

    需求 8.8: 后端服务 SHALL 支持 CORS 跨域请求
    """
    response = client.options(
        "/health",
        headers={
            "Origin": "http://localhost:3000",
            "Access-Control-Request-Method": "GET",
        },
    )
    assert response.headers.get("access-control-allow-origin") == "http://localhost:3000"
    assert "GET" in response.headers.get("access-control-allow-methods", "")


def test_cors_on_response(client: TestClient):
    """测试实际请求的响应中包含 CORS 头。"""
    response = client.get(
        "/health",
        headers={"Origin": "http://localhost:3000"},
    )
    assert response.headers.get("access-control-allow-origin") == "http://localhost:3000"


def test_health_json_format(client: TestClient):
    """测试健康检查端点返回有效的 JSON 格式。

    需求 8.7: 后端服务 SHALL 使用 JSON 格式进行请求和响应数据交换
    """
    response = client.get("/health")
    assert response.headers.get("content-type") == "application/json"
    # 确保能正常解析 JSON
    data = response.json()
    assert isinstance(data, dict)
