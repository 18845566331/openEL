"""模型加载 API 端点单元测试。

需求: 8.2, 8.3, 1.2
任务: 2.3 实现模型加载API端点
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture()
def client() -> TestClient:
    return TestClient(app)


def _create_minimal_onnx(path: Path) -> None:
    """创建最小有效 ONNX 模型文件。"""
    try:
        import onnx
        from onnx import TensorProto, helper

        X = helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, 64, 64])
        Y = helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3, 64, 64])
        node = helper.make_node("Identity", inputs=["input"], outputs=["output"])
        graph = helper.make_graph([node], "test_graph", [X], [Y])
        model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 11)])
        model.ir_version = 7
        onnx.save(model, str(path))
    except ImportError:
        path.write_bytes(b"\x08\x07")


@pytest.fixture()
def onnx_model(tmp_path: Path) -> Path:
    model_path = tmp_path / "test_model.onnx"
    _create_minimal_onnx(model_path)
    return model_path


def _valid_load_body(model_path: str) -> dict:
    return {
        "model_path": model_path,
        "labels": ["隐裂", "断栅"],
        "input_width": 640,
        "input_height": 640,
        "output_layout": "cxcywh_obj_cls",
        "normalize": True,
        "swap_rb": True,
        "confidence_threshold": 0.55,
        "iou_threshold": 0.45,
        "backend_preference": "onnxruntime",
    }


# ---------------------------------------------------------------------------
# POST /api/model/load 测试
# ---------------------------------------------------------------------------

class TestLoadModelEndpoint:
    """需求 8.2: 后端服务 SHALL 提供模型加载端点(POST /api/model/load)"""

    def test_load_success(self, client: TestClient, onnx_model: Path):
        """有效模型路径应返回 200 和成功消息。"""
        body = _valid_load_body(str(onnx_model))
        response = client.post("/api/model/load", json=body)
        assert response.status_code == 200
        data = response.json()
        assert data["message"] == "模型加载成功"
        assert "runtime" in data
        assert data["runtime"]["model_loaded"] is True

    def test_load_returns_runtime_info(self, client: TestClient, onnx_model: Path):
        """需求 1.12: 加载成功后返回运行时配置信息。"""
        body = _valid_load_body(str(onnx_model))
        response = client.post("/api/model/load", json=body)
        runtime = response.json()["runtime"]
        assert runtime["backend"] in ("onnxruntime", "opencv_dnn")
        assert runtime["labels"] == ["隐裂", "断栅"]
        assert runtime["input_size"] == [640, 640]
        assert runtime["output_layout"] == "cxcywh_obj_cls"

    def test_load_nonexistent_model(self, client: TestClient):
        """需求 1.2: 模型文件不存在时返回 400 和明确错误信息。"""
        body = _valid_load_body("/nonexistent/path/model.onnx")
        response = client.post("/api/model/load", json=body)
        assert response.status_code == 400
        assert "不存在" in response.json()["detail"]

    def test_load_invalid_layout(self, client: TestClient, onnx_model: Path):
        """无效的输出布局应返回 400。"""
        body = _valid_load_body(str(onnx_model))
        body["output_layout"] = "invalid_layout"
        response = client.post("/api/model/load", json=body)
        assert response.status_code == 400

    def test_load_missing_model_path(self, client: TestClient):
        """缺少必填字段 model_path 应返回 422 (Pydantic 验证)。"""
        body = {"labels": ["A"]}
        response = client.post("/api/model/load", json=body)
        assert response.status_code == 422

    def test_load_invalid_threshold(self, client: TestClient, onnx_model: Path):
        """阈值超出范围应返回 422 (Pydantic 验证)。"""
        body = _valid_load_body(str(onnx_model))
        body["confidence_threshold"] = 1.5
        response = client.post("/api/model/load", json=body)
        assert response.status_code == 422

    def test_load_json_response_format(self, client: TestClient, onnx_model: Path):
        """需求 8.7: 响应应为有效 JSON 格式。"""
        body = _valid_load_body(str(onnx_model))
        response = client.post("/api/model/load", json=body)
        assert response.headers.get("content-type") == "application/json"
        data = response.json()
        assert isinstance(data, dict)


# ---------------------------------------------------------------------------
# POST /api/model/load_profile 测试
# ---------------------------------------------------------------------------

class TestLoadProfileEndpoint:
    """需求 8.3: 后端服务 SHALL 提供通过配置文件加载模型的端点"""

    def test_load_profile_success(self, client: TestClient, onnx_model: Path, tmp_path: Path):
        """有效配置文件应返回 200 和成功消息。"""
        profile = tmp_path / "profile.json"
        config = _valid_load_body(str(onnx_model))
        profile.write_text(json.dumps(config), encoding="utf-8")

        response = client.post(
            "/api/model/load_profile",
            params={"profile_path": str(profile)},
        )
        assert response.status_code == 200
        data = response.json()
        assert data["message"] == "模型加载成功"
        assert data["runtime"]["model_loaded"] is True

    def test_load_profile_nonexistent_file(self, client: TestClient):
        """需求 1.2: 配置文件不存在时返回 400 和明确错误信息。"""
        response = client.post(
            "/api/model/load_profile",
            params={"profile_path": "/nonexistent/profile.json"},
        )
        assert response.status_code == 400
        assert "配置文件不存在" in response.json()["detail"]

    def test_load_profile_invalid_json(self, client: TestClient, tmp_path: Path):
        """JSON 格式无效时返回 400。"""
        profile = tmp_path / "bad.json"
        profile.write_text("not valid json {{{", encoding="utf-8")

        response = client.post(
            "/api/model/load_profile",
            params={"profile_path": str(profile)},
        )
        assert response.status_code == 400
        assert "JSON格式无效" in response.json()["detail"]

    def test_load_profile_missing_required_field(self, client: TestClient, tmp_path: Path):
        """配置文件缺少必填字段时返回 400。"""
        profile = tmp_path / "incomplete.json"
        profile.write_text(json.dumps({"labels": ["A"]}), encoding="utf-8")

        response = client.post(
            "/api/model/load_profile",
            params={"profile_path": str(profile)},
        )
        assert response.status_code == 400
        assert "参数验证失败" in response.json()["detail"]

    def test_load_profile_model_not_found(self, client: TestClient, tmp_path: Path):
        """配置文件中的模型路径无效时返回 400。"""
        profile = tmp_path / "profile.json"
        config = _valid_load_body("/nonexistent/model.onnx")
        profile.write_text(json.dumps(config), encoding="utf-8")

        response = client.post(
            "/api/model/load_profile",
            params={"profile_path": str(profile)},
        )
        assert response.status_code == 400
        assert "不存在" in response.json()["detail"]

    def test_load_profile_missing_param(self, client: TestClient):
        """缺少 profile_path 查询参数应返回 422。"""
        response = client.post("/api/model/load_profile")
        assert response.status_code == 422
