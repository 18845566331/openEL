"""DefectDetectionEngine 模型加载和 describe() 单元测试。

需求: 1.1, 1.9, 1.10, 1.11, 1.12, 12.6
"""
from __future__ import annotations

import threading
from pathlib import Path
from unittest.mock import MagicMock, patch

import cv2
import numpy as np
import pytest

from app.detector import DefectDetectionEngine, ModelLoadConfig, ModelRuntime


# ---------------------------------------------------------------------------
# 辅助：创建一个最小的有效 ONNX 模型文件
# ---------------------------------------------------------------------------

def _create_minimal_onnx(path: Path) -> None:
    """使用 OpenCV DNN 可读取的最小 ONNX 文件。

    我们通过 onnx 库创建一个简单的 Identity 模型。
    如果 onnx 不可用，则写入一个空文件（测试会跳过需要真实模型的场景）。
    """
    try:
        import onnx
        from onnx import TensorProto, helper

        X = helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, 64, 64])
        Y = helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3, 64, 64])
        node = helper.make_node("Identity", inputs=["input"], outputs=["output"])
        graph = helper.make_graph([node], "test_graph", [X], [Y])
        model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 11)])
        model.ir_version = 7  # 兼容 ONNX Runtime 的 IR 版本
        onnx.save(model, str(path))
    except ImportError:
        # 如果 onnx 库不可用，写入一个假文件
        path.write_bytes(b"\x08\x07")


@pytest.fixture()
def onnx_model(tmp_path: Path) -> Path:
    """创建临时 ONNX 模型文件。"""
    model_path = tmp_path / "test_model.onnx"
    _create_minimal_onnx(model_path)
    return model_path


@pytest.fixture()
def engine() -> DefectDetectionEngine:
    return DefectDetectionEngine()


def _default_load_kwargs(model_path: str) -> dict:
    return {
        "model_path": model_path,
        "labels": ["隐裂", "断栅", "黑斑", "烧结异常"],
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
# describe() 测试
# ---------------------------------------------------------------------------

class TestDescribe:
    """测试 describe() 方法返回运行时状态。"""

    def test_describe_before_load(self, engine: DefectDetectionEngine):
        """需求 1.12: 模型未加载时返回空状态。"""
        state = engine.describe()
        assert state["model_loaded"] is False
        assert state["backend"] is None
        assert state["model_path"] is None
        assert state["labels"] == []
        assert state["input_size"] is None
        assert state["output_layout"] is None
        assert state["default_confidence"] is None
        assert state["default_iou"] is None

    def test_describe_after_load(self, engine: DefectDetectionEngine, onnx_model: Path):
        """需求 1.12: 模型加载成功后返回运行时配置信息。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        engine.load_model(ModelLoadConfig(**kwargs))
        state = engine.describe()

        assert state["model_loaded"] is True
        assert state["backend"] in ("onnxruntime", "opencv_dnn")
        assert state["model_path"] == onnx_model.resolve().as_posix()
        assert state["labels"] == ["隐裂", "断栅", "黑斑", "烧结异常"]
        assert state["input_size"] == [640, 640]
        assert state["output_layout"] == "cxcywh_obj_cls"
        assert state["default_confidence"] == 0.55
        assert state["default_iou"] == 0.45

    def test_describe_returns_copy_of_labels(self, engine: DefectDetectionEngine, onnx_model: Path):
        """确保 describe() 返回的 labels 是副本，不会被外部修改影响。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        engine.load_model(ModelLoadConfig(**kwargs))
        state = engine.describe()
        state["labels"].append("新类别")
        # 再次获取应不受影响
        assert "新类别" not in engine.describe()["labels"]


# ---------------------------------------------------------------------------
# load_model() 测试
# ---------------------------------------------------------------------------

class TestLoadModel:
    """测试 load_model() 方法。"""

    def test_load_valid_model(self, engine: DefectDetectionEngine, onnx_model: Path):
        """需求 1.1: 提供有效的 ONNX 模型文件路径时加载成功。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        result = engine.load_model(ModelLoadConfig(**kwargs))
        assert result["model_loaded"] is True
        assert result["backend"] in ("onnxruntime", "opencv_dnn")

    def test_load_nonexistent_model_raises(self, engine: DefectDetectionEngine):
        """需求 1.2 (隐含): 模型文件不存在时抛出 FileNotFoundError。"""
        kwargs = _default_load_kwargs("/nonexistent/path/model.onnx")
        with pytest.raises(FileNotFoundError, match="模型文件不存在"):
            engine.load_model(ModelLoadConfig(**kwargs))

    def test_load_returns_runtime_info(self, engine: DefectDetectionEngine, onnx_model: Path):
        """需求 1.12: 加载成功后返回运行时配置信息。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        result = engine.load_model(ModelLoadConfig(**kwargs))
        assert "model_loaded" in result
        assert "backend" in result
        assert "model_path" in result
        assert "labels" in result
        assert "input_size" in result
        assert "output_layout" in result
        assert "default_confidence" in result
        assert "default_iou" in result

    def test_load_preserves_config_params(self, engine: DefectDetectionEngine, onnx_model: Path):
        """需求 1.4, 1.5, 1.6, 1.7, 1.8: 加载后配置参数应被保留。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        kwargs["labels"] = ["A", "B"]
        kwargs["input_width"] = 320
        kwargs["input_height"] = 480
        kwargs["output_layout"] = "xyxy_score_class"
        kwargs["confidence_threshold"] = 0.7
        kwargs["iou_threshold"] = 0.3
        result = engine.load_model(ModelLoadConfig(**kwargs))

        assert result["labels"] == ["A", "B"]
        assert result["input_size"] == [320, 480]
        assert result["output_layout"] == "xyxy_score_class"
        assert result["default_confidence"] == 0.7
        assert result["default_iou"] == 0.3

    def test_load_invalid_layout_raises(self, engine: DefectDetectionEngine, onnx_model: Path):
        """需求 1.6: 无效的输出布局应抛出 ValueError。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        kwargs["output_layout"] = "invalid_layout"
        with pytest.raises(ValueError, match="无效的输出布局"):
            engine.load_model(ModelLoadConfig(**kwargs))


# ---------------------------------------------------------------------------
# 引擎选择逻辑测试
# ---------------------------------------------------------------------------

class TestEngineSelection:
    """测试推理引擎选择逻辑。"""

    def test_prefer_onnxruntime_when_available(
        self, engine: DefectDetectionEngine, onnx_model: Path
    ):
        """需求 1.9: 用户选择 onnxruntime 且可用时优先使用。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        kwargs["backend_preference"] = "onnxruntime"
        result = engine.load_model(ModelLoadConfig(**kwargs))
        # 如果 onnxruntime 已安装，应使用它
        try:
            import onnxruntime
            assert result["backend"] == "onnxruntime"
        except ImportError:
            assert result["backend"] == "opencv_dnn"

    def test_use_opencv_when_preferred(
        self, engine: DefectDetectionEngine, onnx_model: Path
    ):
        """需求 1.10: 用户选择 opencv_dnn 时使用 OpenCV DNN。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        kwargs["backend_preference"] = "opencv_dnn"
        result = engine.load_model(ModelLoadConfig(**kwargs))
        assert result["backend"] == "opencv_dnn"

    def test_fallback_to_opencv_when_ort_unavailable(
        self, engine: DefectDetectionEngine, onnx_model: Path
    ):
        """需求 1.10: ONNX Runtime 不可用时回退到 OpenCV DNN。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        kwargs["backend_preference"] = "onnxruntime"
        with patch("app.detector.ort", None):
            result = engine.load_model(ModelLoadConfig(**kwargs))
        assert result["backend"] == "opencv_dnn"

    def test_fallback_to_opencv_when_ort_fails(
        self, engine: DefectDetectionEngine, onnx_model: Path
    ):
        """需求 1.10: ONNX Runtime 加载失败时回退到 OpenCV DNN。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        kwargs["backend_preference"] = "onnxruntime"
        mock_ort = MagicMock()
        mock_ort.get_available_providers.return_value = ["CPUExecutionProvider"]
        mock_ort.InferenceSession.side_effect = RuntimeError("模拟加载失败")
        with patch("app.detector.ort", mock_ort):
            result = engine.load_model(ModelLoadConfig(**kwargs))
        assert result["backend"] == "opencv_dnn"


# ---------------------------------------------------------------------------
# GPU 加速测试
# ---------------------------------------------------------------------------

class TestGPUAcceleration:
    """测试 GPU 加速检测和配置。"""

    def test_ort_cuda_provider_selected_when_available(self):
        """需求 1.11: CUDA 可用时 ONNX Runtime 应选择 CUDAExecutionProvider。"""
        mock_ort = MagicMock()
        mock_ort.get_available_providers.return_value = [
            "CUDAExecutionProvider",
            "CPUExecutionProvider",
        ]
        with patch("app.detector.ort", mock_ort):
            providers = DefectDetectionEngine._select_ort_providers()
        assert providers[0] == "CUDAExecutionProvider"
        assert "CPUExecutionProvider" in providers

    def test_ort_cpu_only_when_no_cuda(self):
        """需求 1.11: 无 CUDA 时仅使用 CPUExecutionProvider。"""
        mock_ort = MagicMock()
        mock_ort.get_available_providers.return_value = ["CPUExecutionProvider"]
        with patch("app.detector.ort", mock_ort):
            providers = DefectDetectionEngine._select_ort_providers()
        assert providers == ["CPUExecutionProvider"]

    def test_opencv_cuda_backend_when_available(self):
        """需求 1.11: OpenCV CUDA 可用时配置 GPU 后端。"""
        mock_net = MagicMock()
        with patch("cv2.cuda.getCudaEnabledDeviceCount", return_value=1):
            DefectDetectionEngine._configure_opencv_backend(mock_net)
        mock_net.setPreferableBackend.assert_called_with(cv2.dnn.DNN_BACKEND_CUDA)
        mock_net.setPreferableTarget.assert_called_with(cv2.dnn.DNN_TARGET_CUDA_FP16)

    def test_opencv_cpu_backend_when_no_cuda(self):
        """需求 1.11: 无 CUDA 时使用 CPU 后端。"""
        mock_net = MagicMock()
        with patch("cv2.cuda.getCudaEnabledDeviceCount", return_value=0):
            DefectDetectionEngine._configure_opencv_backend(mock_net)
        mock_net.setPreferableBackend.assert_called_with(cv2.dnn.DNN_BACKEND_OPENCV)
        mock_net.setPreferableTarget.assert_called_with(cv2.dnn.DNN_TARGET_CPU)

    def test_opencv_cpu_fallback_on_cuda_error(self):
        """需求 1.11: CUDA 检测异常时安全回退到 CPU。"""
        mock_net = MagicMock()
        with patch("cv2.cuda.getCudaEnabledDeviceCount", side_effect=Exception("no CUDA")):
            DefectDetectionEngine._configure_opencv_backend(mock_net)
        mock_net.setPreferableBackend.assert_called_with(cv2.dnn.DNN_BACKEND_OPENCV)
        mock_net.setPreferableTarget.assert_called_with(cv2.dnn.DNN_TARGET_CPU)


# ---------------------------------------------------------------------------
# 线程安全测试
# ---------------------------------------------------------------------------

class TestThreadSafety:
    """测试线程安全性。需求 12.6。"""

    def test_concurrent_describe(self, engine: DefectDetectionEngine, onnx_model: Path):
        """并发调用 describe() 不应出错。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        engine.load_model(ModelLoadConfig(**kwargs))

        results = []
        errors = []

        def worker():
            try:
                results.append(engine.describe())
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=worker) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors
        assert len(results) == 10
        assert all(r["model_loaded"] is True for r in results)

    def test_concurrent_load_and_describe(self, engine: DefectDetectionEngine, onnx_model: Path):
        """并发加载和查询不应出现数据竞争。"""
        kwargs = _default_load_kwargs(str(onnx_model))
        errors = []

        def load_worker():
            try:
                engine.load_model(ModelLoadConfig(**kwargs))
            except Exception as e:
                errors.append(e)

        def describe_worker():
            try:
                engine.describe()
            except Exception as e:
                errors.append(e)

        threads = []
        for _ in range(5):
            threads.append(threading.Thread(target=load_worker))
            threads.append(threading.Thread(target=describe_worker))
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors
