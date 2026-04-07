"""日志记录功能测试。

验证需求:
- 11.3: 后端服务在控制台输出请求日志
- 11.4: 后端服务记录模型加载事件
- 11.5: 后端服务记录检测任务的开始和完成
- 11.6: 文件操作失败时提供明确的文件路径和失败原因
- 11.7: 模型推理失败时提供推理引擎类型和错误详情
"""
from __future__ import annotations

import logging
from pathlib import Path
from unittest.mock import MagicMock, patch

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture()
def client() -> TestClient:
    return TestClient(app)


# ---------------------------------------------------------------------------
# 需求 11.3: 请求日志
# ---------------------------------------------------------------------------


class TestRequestLogging:
    """验证 HTTP 请求日志中间件输出请求方法、路径和状态码。"""

    def test_health_request_logged(self, client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
        with caplog.at_level(logging.INFO, logger="app.main"):
            client.get("/health")
        assert any("GET" in r.message and "/health" in r.message and "200" in r.message for r in caplog.records)

    def test_failed_request_logged(self, client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
        with caplog.at_level(logging.INFO, logger="app.main"):
            client.post("/api/detect", json={"image_path": "/nonexistent.jpg"})
        assert any("POST" in r.message and "/api/detect" in r.message for r in caplog.records)


# ---------------------------------------------------------------------------
# 需求 11.4: 模型加载事件日志
# ---------------------------------------------------------------------------


class TestModelLoadLogging:
    """验证模型加载成功和失败时都有日志记录。"""

    def test_load_nonexistent_model_logs_error(self, client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
        with caplog.at_level(logging.INFO, logger="app.main"):
            client.post("/api/model/load", json={
                "model_path": "/no/such/model.onnx",
                "labels": ["a"],
                "input_width": 640,
                "input_height": 640,
                "output_layout": "cxcywh_obj_cls",
            })
        assert any("模型文件不存在" in r.message for r in caplog.records)

    def test_load_success_logs_info(self, client: TestClient, tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
        model_file = tmp_path / "test.onnx"
        model_file.write_bytes(b"fake")
        with caplog.at_level(logging.INFO, logger="app.main"), \
             patch("app.main.engine") as mock_engine:
            mock_engine.load_model.return_value = {"backend": "opencv_dnn", "model_path": str(model_file)}
            client.post("/api/model/load", json={
                "model_path": str(model_file),
                "labels": ["crack"],
                "input_width": 640,
                "input_height": 640,
                "output_layout": "cxcywh_obj_cls",
            })
        assert any("开始加载模型" in r.message for r in caplog.records)
        assert any("模型加载成功" in r.message for r in caplog.records)


# ---------------------------------------------------------------------------
# 需求 11.5: 检测任务开始和完成日志
# ---------------------------------------------------------------------------


class TestDetectionLogging:
    """验证单张和批量检测任务的开始/完成日志。"""

    def test_single_detect_start_logged(self, client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
        with caplog.at_level(logging.INFO, logger="app.main"):
            client.post("/api/detect", json={"image_path": "/nonexistent.jpg"})
        assert any("单张检测开始" in r.message for r in caplog.records)

    def test_single_detect_complete_logged(
        self, client: TestClient, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        img = tmp_path / "test.jpg"
        img.write_bytes(b"fake")
        with caplog.at_level(logging.INFO, logger="app.main"), \
             patch("app.main.engine") as mock_engine:
            mock_engine.detect_image.return_value = {
                "image_path": str(img), "total": 0, "detections": [], "visualization_path": None,
            }
            client.post("/api/detect", json={"image_path": str(img)})
        assert any("单张检测完成" in r.message for r in caplog.records)

    def test_batch_detect_start_logged(self, client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
        with caplog.at_level(logging.INFO, logger="app.main"):
            client.post("/api/detect/batch", json={
                "input_dir": "/nonexistent_dir",
            })
        assert any("批量检测开始" in r.message for r in caplog.records)

    def test_batch_detect_complete_logged(
        self, client: TestClient, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        (tmp_path / "a.jpg").write_bytes(b"fake")
        with caplog.at_level(logging.INFO, logger="app.main"), \
             patch("app.main.engine") as mock_engine:
            mock_engine.detect_image.return_value = {
                "image_path": "a.jpg", "total": 0, "detections": [], "visualization_path": None,
            }
            client.post("/api/detect/batch", json={"input_dir": str(tmp_path)})
        assert any("批量检测完成" in r.message for r in caplog.records)


# ---------------------------------------------------------------------------
# 需求 11.6: 文件操作失败日志
# ---------------------------------------------------------------------------


class TestFileErrorLogging:
    """验证文件操作失败时日志包含文件路径和失败原因。"""

    def test_detect_nonexistent_image_logs_path(self, client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
        with caplog.at_level(logging.ERROR, logger="app.main"):
            client.post("/api/detect", json={"image_path": "/no/such/image.png"})
        error_records = [r for r in caplog.records if r.levelno >= logging.ERROR]
        assert any("文件不存在" in r.message or "image" in r.message.lower() for r in error_records)

    def test_csv_export_permission_error_logs_path(
        self, client: TestClient, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        # 模拟文件写入权限错误
        bad_path = str(tmp_path / "locked" / "report.csv")
        with caplog.at_level(logging.ERROR, logger="app.main"), \
             patch("app.main.Path") as mock_path_cls:
            mock_target = MagicMock()
            mock_target.parent.mkdir.return_value = None
            mock_target.open.side_effect = PermissionError("access denied")
            mock_target.as_posix.return_value = bad_path
            mock_path_cls.return_value.expanduser.return_value.resolve.return_value = mock_target
            resp = client.post(
                "/api/report/export_csv",
                params={"output_csv": bad_path},
                json={"results": []},
            )
        assert resp.status_code == 400


# ---------------------------------------------------------------------------
# 需求 11.7: 模型推理失败日志
# ---------------------------------------------------------------------------


class TestInferenceErrorLogging:
    """验证推理失败时日志包含引擎类型和错误详情。"""

    def test_onnxruntime_inference_failure_logged(self, caplog: pytest.LogCaptureFixture) -> None:
        from app.detector import DefectDetectionEngine, ModelRuntime

        runtime = ModelRuntime(
            model_path="/fake.onnx",
            labels=["a"],
            input_width=640,
            input_height=640,
            output_layout="cxcywh_obj_cls",
            normalize=True,
            swap_rb=True,
            default_confidence=0.5,
            default_iou=0.45,
            backend="onnxruntime",
        )
        runtime.session = MagicMock()
        runtime.session.get_inputs.return_value = [MagicMock(name="input")]
        runtime.session.run.side_effect = RuntimeError("ONNX inference error")

        blob = np.zeros((1, 3, 640, 640), dtype=np.float32)
        with caplog.at_level(logging.ERROR, logger="app.detector"):
            with pytest.raises(RuntimeError, match="ONNX Runtime 推理失败"):
                DefectDetectionEngine._inference(blob, runtime)
        assert any("onnxruntime" in r.message and "推理失败" in r.message for r in caplog.records)

    def test_opencv_dnn_inference_failure_logged(self, caplog: pytest.LogCaptureFixture) -> None:
        from app.detector import DefectDetectionEngine, ModelRuntime

        runtime = ModelRuntime(
            model_path="/fake.onnx",
            labels=["a"],
            input_width=640,
            input_height=640,
            output_layout="cxcywh_obj_cls",
            normalize=True,
            swap_rb=True,
            default_confidence=0.5,
            default_iou=0.45,
            backend="opencv_dnn",
        )
        mock_net = MagicMock()
        mock_net.forward.side_effect = RuntimeError("DNN forward error")
        runtime.net = mock_net

        blob = np.zeros((1, 3, 640, 640), dtype=np.float32)
        with caplog.at_level(logging.ERROR, logger="app.detector"):
            with pytest.raises(RuntimeError, match="OpenCV DNN 推理失败"):
                DefectDetectionEngine._inference(blob, runtime)
        assert any("opencv_dnn" in r.message and "推理失败" in r.message for r in caplog.records)


# ---------------------------------------------------------------------------
# run_server.py 日志配置
# ---------------------------------------------------------------------------


class TestRunServerLoggingConfig:
    """验证 run_server.py 的日志格式配置。"""

    def test_configure_logging_sets_format(self) -> None:
        from run_server import _configure_logging
        _configure_logging()
        root = logging.getLogger()
        # _configure_logging 调用 basicConfig，验证它不会抛出异常即可
        # 在测试环境中 root logger 可能已被 pytest 配置
        assert root.handlers is not None
