"""共享测试夹具和配置。"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture()
def client() -> TestClient:
    """创建 FastAPI 测试客户端。"""
    return TestClient(app)
