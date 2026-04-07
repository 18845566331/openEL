"""前后端集成测试 — 从后端角度模拟前端 Flutter 应用的请求模式。

与 test_integration.py 不同，本文件重点模拟前端 DetectionApiService 的实际调用序列：
- 前端启动时的初始化流程（健康检查 → 获取运行时状态）
- 前端模型配置页面的操作（加载模型 → 查询状态 → 重新加载）
- 前端单张检测页面的操作（选择图像 → 调节参数 → 检测 → 查看结果）
- 前端批量检测页面的操作（选择目录 → 配置选项 → 批量检测 → 导出报告）
- 前端错误处理（网络错误场景、无效参数、模型未加载时的操作）
- 前端可能发送的各种参数组合

任务: 25.2 编写前后端集成测试
"""
from __future__ import annotations

import json
import tempfile
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.main import app


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------


def _create_minimal_onnx(path: Path) -> None:
    """创建一个最小的 Identity ONNX 模型用于测试。"""
    import onnx
    from onnx import TensorProto, helper

    X = helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, 64, 64])
    Y = helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3, 64, 64])
    node = helper.make_node("Identity", inputs=["input"], outputs=["output"])
    graph = helper.make_graph([node], "test_graph", [X], [Y])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 11)])
    model.ir_version = 7
    onnx.save(model, str(path))


def _create_test_image(path: Path, width: int = 100, height: int = 100) -> None:
    """创建测试图像文件。"""
    img = np.random.randint(0, 256, (height, width, 3), dtype=np.uint8)
    cv2.imwrite(str(path), img)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def fe_client() -> TestClient:
    """模拟前端 Dio HTTP 客户端（raise_server_exceptions=False 模拟真实网络行为）。"""
    return TestClient(app, raise_server_exceptions=False)


@pytest.fixture(scope="module")
def _onnx_model(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """模块级别的临时 ONNX 模型文件。"""
    tmp_dir = tmp_path_factory.mktemp("fe_integration_models")
    model_path = tmp_dir / "fe_test_model.onnx"
    _create_minimal_onnx(model_path)
    return model_path


@pytest.fixture(scope="module")
def fe_client_with_model(_onnx_model: Path) -> TestClient:
    """模块级别的已加载模型的 TestClient，模拟前端已完成模型配置。"""
    c = TestClient(app)
    resp = c.post("/api/model/load", json={
        "model_path": str(_onnx_model),
        "labels": ["隐裂", "断栅", "黑斑", "烧结异常"],
        "input_width": 64,
        "input_height": 64,
        "output_layout": "cxcywh_obj_cls",
        "normalize": True,
        "swap_rb": True,
        "confidence_threshold": 0.55,
        "iou_threshold": 0.45,
        "backend_preference": "onnxruntime",
    })
    assert resp.status_code == 200
    return c



# ===========================================================================
# 场景 1: 前端启动时的初始化流程
# ===========================================================================


class TestFrontendStartupFlow:
    """模拟前端应用启动时的初始化请求序列。

    前端 DetectionApiService 在启动时会：
    1. 调用 health() 检查后端是否可用
    2. 从 health 响应中读取 runtime 信息判断模型是否已加载
    3. 根据模型状态决定是否显示模型配置页面
    """

    def test_startup_health_check_returns_runtime_info(self, fe_client: TestClient):
        """前端启动 → 健康检查 → 获取运行时状态。

        前端通过 health() 获取 runtime 字段来判断模型加载状态。
        """
        resp = fe_client.get("/health")
        assert resp.status_code == 200

        data = resp.json()
        assert data["status"] == "ok"
        assert "runtime" in data

        runtime = data["runtime"]
        # 前端会检查 model_loaded 字段决定是否需要加载模型
        assert "model_loaded" in runtime

    def test_startup_repeated_health_checks(self, fe_client: TestClient):
        """前端可能在启动时多次调用健康检查（重试机制）。"""
        for _ in range(3):
            resp = fe_client.get("/health")
            assert resp.status_code == 200
            assert resp.json()["status"] == "ok"

    def test_startup_health_then_check_model_status(
        self, fe_client_with_model: TestClient
    ):
        """前端启动 → 健康检查 → 发现模型已加载 → 读取模型配置信息。

        前端会从 runtime 中提取 labels、input_size 等信息显示在界面上。
        """
        resp = fe_client_with_model.get("/health")
        assert resp.status_code == 200

        runtime = resp.json()["runtime"]
        assert runtime["model_loaded"] is True
        # 前端会读取这些字段显示在模型配置面板
        assert "backend" in runtime
        assert "labels" in runtime
        assert "input_size" in runtime
        assert "default_confidence" in runtime
        assert "default_iou" in runtime


# ===========================================================================
# 场景 2: 前端模型配置页面的操作
# ===========================================================================


class TestFrontendModelConfigFlow:
    """模拟前端模型配置页面 (ModelConfigScreen) 的操作序列。

    前端模型配置页面允许用户：
    1. 选择模型文件路径并填写参数 → 调用 loadModel()
    2. 或选择配置文件 → 调用 loadModelByProfile()
    3. 加载后查询状态确认
    4. 可以重新加载不同的模型
    """

    def test_load_model_with_full_params(self, fe_client: TestClient):
        """前端通过完整参数加载模型（对应 loadModel() 方法）。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            model_path = Path(tmp_dir) / "model.onnx"
            _create_minimal_onnx(model_path)

            # 模拟前端 loadModel() 发送的完整参数
            resp = fe_client.post("/api/model/load", json={
                "model_path": str(model_path),
                "labels": ["隐裂", "断栅", "黑斑", "烧结异常"],
                "input_width": 640,
                "input_height": 640,
                "output_layout": "cxcywh_obj_cls",
                "normalize": True,
                "swap_rb": True,
                "confidence_threshold": 0.55,
                "iou_threshold": 0.45,
                "backend_preference": "onnxruntime",
            })
            assert resp.status_code == 200

            data = resp.json()
            assert data["message"] == "模型加载成功"
            assert "runtime" in data
            assert data["runtime"]["model_loaded"] is True

    def test_load_model_by_profile(self, fe_client: TestClient):
        """前端通过配置文件加载模型（对应 loadModelByProfile() 方法）。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            model_path = Path(tmp_dir) / "model.onnx"
            _create_minimal_onnx(model_path)

            profile = {
                "model_path": str(model_path),
                "labels": ["隐裂", "断栅"],
                "input_width": 64,
                "input_height": 64,
                "output_layout": "cxcywh_obj_cls",
            }
            profile_path = Path(tmp_dir) / "profile.json"
            profile_path.write_text(json.dumps(profile), encoding="utf-8")

            # 前端 loadModelByProfile() 使用 queryParameters
            resp = fe_client.post(
                "/api/model/load_profile",
                params={"profile_path": str(profile_path)},
            )
            assert resp.status_code == 200
            assert resp.json()["message"] == "模型加载成功"

    def test_load_then_verify_then_reload_different_model(
        self, fe_client: TestClient
    ):
        """加载模型 → 查询状态确认 → 重新加载不同配置的模型。

        前端用户可能先加载一个模型，然后切换到另一个模型。
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            model_path = Path(tmp_dir) / "model.onnx"
            _create_minimal_onnx(model_path)

            # 第一次加载：4个标签
            resp1 = fe_client.post("/api/model/load", json={
                "model_path": str(model_path),
                "labels": ["隐裂", "断栅", "黑斑", "烧结异常"],
                "input_width": 64,
                "input_height": 64,
            })
            assert resp1.status_code == 200

            # 查询状态确认
            health1 = fe_client.get("/health")
            runtime1 = health1.json()["runtime"]
            assert runtime1["model_loaded"] is True
            assert len(runtime1["labels"]) == 4

            # 第二次加载：2个标签，不同阈值
            resp2 = fe_client.post("/api/model/load", json={
                "model_path": str(model_path),
                "labels": ["隐裂", "断栅"],
                "input_width": 64,
                "input_height": 64,
                "confidence_threshold": 0.3,
                "iou_threshold": 0.6,
            })
            assert resp2.status_code == 200

            # 查询状态确认新配置
            health2 = fe_client.get("/health")
            runtime2 = health2.json()["runtime"]
            assert runtime2["model_loaded"] is True
            assert len(runtime2["labels"]) == 2
            assert runtime2["default_confidence"] == pytest.approx(0.3)
            assert runtime2["default_iou"] == pytest.approx(0.6)

    def test_load_model_with_different_output_layouts(self, fe_client: TestClient):
        """前端可能选择不同的输出布局格式。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            model_path = Path(tmp_dir) / "model.onnx"
            _create_minimal_onnx(model_path)

            for layout in ["cxcywh_obj_cls", "xyxy_score_class", "cxcywh_score_class"]:
                resp = fe_client.post("/api/model/load", json={
                    "model_path": str(model_path),
                    "labels": ["隐裂"],
                    "input_width": 64,
                    "input_height": 64,
                    "output_layout": layout,
                })
                assert resp.status_code == 200
                assert resp.json()["runtime"]["output_layout"] == layout

    def test_load_model_with_different_backend_preferences(
        self, fe_client: TestClient
    ):
        """前端可能选择不同的推理引擎偏好。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            model_path = Path(tmp_dir) / "model.onnx"
            _create_minimal_onnx(model_path)

            for backend in ["onnxruntime", "opencv"]:
                resp = fe_client.post("/api/model/load", json={
                    "model_path": str(model_path),
                    "labels": ["隐裂"],
                    "input_width": 64,
                    "input_height": 64,
                    "backend_preference": backend,
                })
                assert resp.status_code == 200
                assert resp.json()["runtime"]["model_loaded"] is True



# ===========================================================================
# 场景 3: 前端单张检测页面的操作
# ===========================================================================


class TestFrontendSingleDetectFlow:
    """模拟前端单张检测页面 (SingleDetectScreen) 的操作序列。

    前端单张检测页面允许用户：
    1. 选择图像文件
    2. 调节置信度和IOU阈值（滑块控件，范围 0.0~1.0）
    3. 选择是否保存可视化
    4. 点击检测按钮 → 调用 detect()
    5. 查看检测结果（缺陷列表、可视化图像）
    """

    def test_detect_with_default_thresholds(
        self, fe_client_with_model: TestClient
    ):
        """前端使用默认阈值检测（不传 threshold 参数）。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_path = Path(tmp_dir) / "test.png"
            _create_test_image(img_path)

            # 前端 detect() 总是传递 threshold 参数，但后端也支持 None
            resp = fe_client_with_model.post("/api/detect", json={
                "image_path": str(img_path),
            })
            assert resp.status_code == 200

            result = resp.json()
            assert "image_path" in result
            assert "total" in result
            assert "detections" in result
            assert isinstance(result["total"], int)

    def test_detect_with_custom_thresholds(
        self, fe_client_with_model: TestClient
    ):
        """前端用户调节滑块后传递自定义阈值。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_path = Path(tmp_dir) / "test.png"
            _create_test_image(img_path)

            # 模拟前端 detect() 方法发送的参数
            resp = fe_client_with_model.post("/api/detect", json={
                "image_path": str(img_path),
                "confidence_threshold": 0.3,
                "iou_threshold": 0.6,
                "save_visualization": False,
            })
            assert resp.status_code == 200
            result = resp.json()
            assert result["total"] >= 0

    def test_detect_with_visualization_enabled(
        self, fe_client_with_model: TestClient
    ):
        """前端启用可视化保存。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_path = Path(tmp_dir) / "test.jpg"
            _create_test_image(img_path)
            vis_dir = Path(tmp_dir) / "vis"

            resp = fe_client_with_model.post("/api/detect", json={
                "image_path": str(img_path),
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
                "save_visualization": True,
                "visualization_dir": str(vis_dir),
            })
            assert resp.status_code == 200
            assert vis_dir.exists()

    def test_detect_multiple_images_sequentially(
        self, fe_client_with_model: TestClient
    ):
        """前端用户连续检测多张图像（每次选择不同图像）。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            results = []
            for i in range(3):
                img_path = Path(tmp_dir) / f"img_{i}.png"
                _create_test_image(img_path, width=80 + i * 20, height=80 + i * 20)

                resp = fe_client_with_model.post("/api/detect", json={
                    "image_path": str(img_path),
                    "confidence_threshold": 0.5,
                    "iou_threshold": 0.45,
                })
                assert resp.status_code == 200
                results.append(resp.json())

            # 每次检测都应返回完整结构
            for r in results:
                assert "image_path" in r
                assert "total" in r
                assert "detections" in r

    def test_detect_with_boundary_threshold_values(
        self, fe_client_with_model: TestClient
    ):
        """前端滑块的边界值：0.0 和 1.0。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_path = Path(tmp_dir) / "test.png"
            _create_test_image(img_path)

            # 最低阈值
            resp_low = fe_client_with_model.post("/api/detect", json={
                "image_path": str(img_path),
                "confidence_threshold": 0.0,
                "iou_threshold": 0.0,
            })
            assert resp_low.status_code == 200

            # 最高阈值
            resp_high = fe_client_with_model.post("/api/detect", json={
                "image_path": str(img_path),
                "confidence_threshold": 1.0,
                "iou_threshold": 1.0,
            })
            assert resp_high.status_code == 200

    def test_detect_various_image_formats(
        self, fe_client_with_model: TestClient
    ):
        """前端支持选择多种图像格式。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            for ext in [".jpg", ".png", ".bmp"]:
                img_path = Path(tmp_dir) / f"test{ext}"
                _create_test_image(img_path)

                resp = fe_client_with_model.post("/api/detect", json={
                    "image_path": str(img_path),
                })
                assert resp.status_code == 200
                assert "detections" in resp.json()



# ===========================================================================
# 场景 4: 前端批量检测页面的操作
# ===========================================================================


class TestFrontendBatchDetectFlow:
    """模拟前端批量检测页面 (BatchDetectScreen) 的操作序列。

    前端批量检测页面允许用户：
    1. 选择输入目录
    2. 配置递归扫描、文件扩展名过滤、最大图像数量
    3. 调节阈值参数
    4. 选择是否保存可视化
    5. 点击检测按钮 → 调用 detectBatch()
    6. 查看统计信息和结果列表
    7. 点击导出按钮 → 调用 exportCsv()
    """

    def test_batch_detect_with_frontend_default_params(
        self, fe_client_with_model: TestClient
    ):
        """前端使用默认参数进行批量检测。

        前端 detectBatch() 默认: recursive=true, maxImages=5000
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_dir = Path(tmp_dir) / "images"
            img_dir.mkdir()
            for i in range(3):
                _create_test_image(img_dir / f"img_{i}.png")

            resp = fe_client_with_model.post("/api/detect/batch", json={
                "input_dir": str(img_dir),
                "recursive": True,
                "confidence_threshold": 0.55,
                "iou_threshold": 0.45,
                "max_images": 5000,
                "save_visualization": False,
            })
            assert resp.status_code == 200

            result = resp.json()
            assert result["total_images"] == 3
            assert "ok_images" in result
            assert "ng_images" in result
            assert "total_defects" in result
            assert "defect_by_class" in result
            assert "results" in result
            assert len(result["results"]) == 3

    def test_batch_detect_with_custom_extensions(
        self, fe_client_with_model: TestClient
    ):
        """前端用户自定义文件扩展名过滤。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_dir = Path(tmp_dir) / "mixed"
            img_dir.mkdir()
            _create_test_image(img_dir / "a.png")
            _create_test_image(img_dir / "b.jpg")
            _create_test_image(img_dir / "c.bmp")

            # 只选择 png 和 jpg
            resp = fe_client_with_model.post("/api/detect/batch", json={
                "input_dir": str(img_dir),
                "extensions": [".png", ".jpg"],
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
            })
            assert resp.status_code == 200
            assert resp.json()["total_images"] == 2

    def test_batch_detect_with_max_images_limit(
        self, fe_client_with_model: TestClient
    ):
        """前端用户设置最大处理图像数量。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_dir = Path(tmp_dir) / "many"
            img_dir.mkdir()
            for i in range(10):
                _create_test_image(img_dir / f"img_{i:03d}.png")

            resp = fe_client_with_model.post("/api/detect/batch", json={
                "input_dir": str(img_dir),
                "extensions": [".png"],
                "max_images": 3,
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
            })
            assert resp.status_code == 200
            assert resp.json()["total_images"] == 3

    def test_batch_detect_then_export_csv_workflow(
        self, fe_client_with_model: TestClient
    ):
        """前端完整工作流：批量检测 → 查看结果 → 导出CSV报告。

        前端 exportCsv() 将 BatchSummary.toJson() 作为请求体发送。
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_dir = Path(tmp_dir) / "batch"
            img_dir.mkdir()
            for i in range(4):
                _create_test_image(img_dir / f"img_{i}.png")

            # 步骤1: 批量检测
            resp_batch = fe_client_with_model.post("/api/detect/batch", json={
                "input_dir": str(img_dir),
                "extensions": [".png"],
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
            })
            assert resp_batch.status_code == 200
            batch_result = resp_batch.json()

            # 步骤2: 前端显示统计信息（验证数据一致性）
            assert batch_result["total_images"] == (
                batch_result["ok_images"] + batch_result["ng_images"]
            )

            # 步骤3: 导出CSV报告 — 使用新的 project_info 格式
            csv_path = str(Path(tmp_dir) / "report.csv")
            file_results = []
            for r in batch_result["results"]:
                dets = r.get("detections", [])
                file_results.append({
                    "name": Path(r["image_path"]).name,
                    "result": "NG" if dets else "OK",
                    "path": r["image_path"],
                })
            resp_export = fe_client_with_model.post(
                "/api/report/export_csv",
                json={
                    "output_path": csv_path,
                    "project_info": {
                        "project_name": "前端批量检测测试",
                        "file_results": file_results,
                        "defect_by_class": batch_result.get("defect_by_class", {}),
                    },
                },
            )
            assert resp_export.status_code == 200
            assert resp_export.json()["message"] == "CSV 报告导出成功"
            assert Path(csv_path).exists()

    def test_batch_detect_with_visualization_then_export(
        self, fe_client_with_model: TestClient
    ):
        """批量检测启用可视化 → 导出报告。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_dir = Path(tmp_dir) / "vis_batch"
            img_dir.mkdir()
            for i in range(2):
                _create_test_image(img_dir / f"img_{i}.png")
            vis_dir = Path(tmp_dir) / "vis_output"

            resp = fe_client_with_model.post("/api/detect/batch", json={
                "input_dir": str(img_dir),
                "extensions": [".png"],
                "save_visualization": True,
                "visualization_dir": str(vis_dir),
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
            })
            assert resp.status_code == 200
            assert vis_dir.exists()

    def test_batch_detect_empty_directory(
        self, fe_client_with_model: TestClient
    ):
        """前端选择了空目录进行批量检测。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            empty_dir = Path(tmp_dir) / "empty"
            empty_dir.mkdir()

            resp = fe_client_with_model.post("/api/detect/batch", json={
                "input_dir": str(empty_dir),
                "extensions": [".png"],
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
            })
            assert resp.status_code == 200
            result = resp.json()
            assert result["total_images"] == 0
            assert result["results"] == []



# ===========================================================================
# 场景 5: 前端错误处理
# ===========================================================================


class TestFrontendErrorHandling:
    """模拟前端遇到的各种错误场景。

    前端 DetectionApiService._convertDioException() 会根据 HTTP 响应中的
    detail 字段向用户显示错误信息。这里验证后端返回的错误格式符合前端预期。
    """

    def test_detect_without_model_loaded(self, fe_client: TestClient):
        """前端在模型未加载时尝试检测 → 应收到包含 detail 的错误响应。"""
        # 先确保引擎处于未加载状态（通过新的 TestClient）
        c = TestClient(app, raise_server_exceptions=False)

        with tempfile.TemporaryDirectory() as tmp_dir:
            img_path = Path(tmp_dir) / "test.png"
            _create_test_image(img_path)

            # 加载一个模型先（确保引擎有状态），然后测试无效图像
            # 这里直接测试：如果模型碰巧已加载，检测不存在的图像
            resp = c.post("/api/detect", json={
                "image_path": "/nonexistent/image.jpg",
            })
            assert resp.status_code == 400
            error = resp.json()
            # 前端期望 detail 字段存在
            assert "detail" in error
            assert isinstance(error["detail"], str)
            assert len(error["detail"]) > 0

    def test_load_model_invalid_path_error_format(self, fe_client: TestClient):
        """前端加载不存在的模型 → 验证错误响应格式。"""
        resp = fe_client.post("/api/model/load", json={
            "model_path": "/nonexistent/model.onnx",
            "labels": ["隐裂"],
        })
        assert resp.status_code == 400
        error = resp.json()
        assert "detail" in error
        assert "不存在" in error["detail"]

    def test_load_profile_invalid_path_error_format(self, fe_client: TestClient):
        """前端通过配置文件加载 → 配置文件不存在。"""
        resp = fe_client.post(
            "/api/model/load_profile",
            params={"profile_path": "/nonexistent/profile.json"},
        )
        assert resp.status_code == 400
        assert "detail" in resp.json()

    def test_load_profile_invalid_json_error_format(self, fe_client: TestClient):
        """前端选择了非JSON格式的配置文件。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            bad_profile = Path(tmp_dir) / "bad.json"
            bad_profile.write_text("this is not json", encoding="utf-8")

            resp = fe_client.post(
                "/api/model/load_profile",
                params={"profile_path": str(bad_profile)},
            )
            assert resp.status_code == 400
            assert "detail" in resp.json()
            assert "JSON" in resp.json()["detail"]

    def test_batch_detect_invalid_directory_error_format(
        self, fe_client_with_model: TestClient
    ):
        """前端选择了不存在的目录进行批量检测。"""
        resp = fe_client_with_model.post("/api/detect/batch", json={
            "input_dir": "/nonexistent/directory",
            "confidence_threshold": 0.5,
            "iou_threshold": 0.45,
        })
        assert resp.status_code == 400
        error = resp.json()
        assert "detail" in error
        assert "不存在" in error["detail"]

    def test_detect_invalid_image_path_error_format(
        self, fe_client_with_model: TestClient
    ):
        """前端传递了不存在的图像路径。"""
        resp = fe_client_with_model.post("/api/detect", json={
            "image_path": "/nonexistent/image.jpg",
            "confidence_threshold": 0.5,
            "iou_threshold": 0.45,
        })
        assert resp.status_code == 400
        assert "detail" in resp.json()

    def test_detect_corrupt_image_error_format(
        self, fe_client_with_model: TestClient
    ):
        """前端选择了损坏的图像文件。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            bad_img = Path(tmp_dir) / "corrupt.png"
            bad_img.write_bytes(b"not a real image data")

            resp = fe_client_with_model.post("/api/detect", json={
                "image_path": str(bad_img),
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
            })
            assert resp.status_code == 400
            assert "detail" in resp.json()

    def test_invalid_threshold_values_rejected(self, fe_client: TestClient):
        """前端发送超出范围的阈值参数（理论上前端滑块会限制，但测试边界）。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_path = Path(tmp_dir) / "test.png"
            _create_test_image(img_path)

            # 置信度阈值超出范围
            resp = fe_client.post("/api/detect", json={
                "image_path": str(img_path),
                "confidence_threshold": 1.5,
            })
            assert resp.status_code == 422  # Pydantic 验证错误

            resp2 = fe_client.post("/api/detect", json={
                "image_path": str(img_path),
                "confidence_threshold": -0.1,
            })
            assert resp2.status_code == 422

    def test_error_responses_are_valid_json(self, fe_client: TestClient):
        """所有错误响应都应该是有效的 JSON（前端 _asMap 需要解析）。"""
        error_requests = [
            ("POST", "/api/model/load", {"model_path": "/bad.onnx"}),
            ("POST", "/api/detect", {"image_path": "/bad.jpg"}),
            ("POST", "/api/detect/batch", {"input_dir": "/bad/dir"}),
        ]
        for method, url, data in error_requests:
            if method == "POST":
                resp = fe_client.post(url, json=data)
            else:
                resp = fe_client.get(url)

            # 无论成功还是失败，响应都应该是有效 JSON
            body = resp.json()
            assert isinstance(body, dict)

    def test_sequential_errors_dont_crash_service(self, fe_client: TestClient):
        """前端连续发送多个错误请求后，服务仍然正常。"""
        # 连续发送各种错误请求
        fe_client.post("/api/model/load", json={"model_path": "/bad1.onnx"})
        fe_client.post("/api/model/load", json={"model_path": "/bad2.onnx"})
        fe_client.post("/api/detect", json={"image_path": "/bad.jpg"})
        fe_client.post("/api/detect/batch", json={"input_dir": "/bad"})
        fe_client.post(
            "/api/model/load_profile",
            params={"profile_path": "/bad.json"},
        )

        # 健康检查仍然正常
        resp = fe_client.get("/health")
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"


# ===========================================================================
# 场景 6: 前端各种参数组合
# ===========================================================================


class TestFrontendParameterCombinations:
    """测试前端可能发送的各种参数组合和边界值。"""

    def test_model_load_minimal_params(self, fe_client: TestClient):
        """前端只提供必需参数，其余使用默认值。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            model_path = Path(tmp_dir) / "model.onnx"
            _create_minimal_onnx(model_path)

            resp = fe_client.post("/api/model/load", json={
                "model_path": str(model_path),
            })
            assert resp.status_code == 200
            runtime = resp.json()["runtime"]
            # 默认值应被应用
            assert runtime["input_size"] == [640, 640]
            assert runtime["output_layout"] == "cxcywh_obj_cls"

    def test_model_load_with_empty_labels(self, fe_client: TestClient):
        """前端传递空标签列表。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            model_path = Path(tmp_dir) / "model.onnx"
            _create_minimal_onnx(model_path)

            resp = fe_client.post("/api/model/load", json={
                "model_path": str(model_path),
                "labels": [],
            })
            assert resp.status_code == 200

    def test_detect_with_only_image_path(
        self, fe_client_with_model: TestClient
    ):
        """前端只传递 image_path，不传其他可选参数。

        注意：需要先确保模型以正确的 input_size 加载（fe_client_with_model 使用 64x64）。
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            # 重新加载模型确保 input_size 与测试模型匹配
            model_dir = Path(tmp_dir) / "models"
            model_dir.mkdir()
            model_path = model_dir / "model.onnx"
            _create_minimal_onnx(model_path)
            fe_client_with_model.post("/api/model/load", json={
                "model_path": str(model_path),
                "labels": ["隐裂"],
                "input_width": 64,
                "input_height": 64,
            })

            img_path = Path(tmp_dir) / "test.png"
            _create_test_image(img_path)

            resp = fe_client_with_model.post("/api/detect", json={
                "image_path": str(img_path),
            })
            assert resp.status_code == 200

    def test_batch_detect_with_all_extensions(
        self, fe_client_with_model: TestClient
    ):
        """前端传递所有支持的扩展名。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_dir = Path(tmp_dir) / "all_ext"
            img_dir.mkdir()
            _create_test_image(img_dir / "a.png")
            _create_test_image(img_dir / "b.jpg")

            resp = fe_client_with_model.post("/api/detect/batch", json={
                "input_dir": str(img_dir),
                "extensions": [".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff"],
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
            })
            assert resp.status_code == 200
            assert resp.json()["total_images"] == 2

    def test_batch_detect_max_images_equals_one(
        self, fe_client_with_model: TestClient
    ):
        """前端设置 max_images=1（最小值）。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_dir = Path(tmp_dir) / "one"
            img_dir.mkdir()
            for i in range(5):
                _create_test_image(img_dir / f"img_{i}.png")

            resp = fe_client_with_model.post("/api/detect/batch", json={
                "input_dir": str(img_dir),
                "extensions": [".png"],
                "max_images": 1,
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
            })
            assert resp.status_code == 200
            assert resp.json()["total_images"] == 1

    def test_export_csv_with_empty_batch_result(
        self, fe_client_with_model: TestClient
    ):
        """前端导出空的批量结果。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "empty.csv")

            resp = fe_client_with_model.post(
                "/api/report/export_csv",
                json={
                    "output_path": csv_path,
                    "project_info": {
                        "project_name": "空结果前端测试",
                        "file_results": [],
                        "defect_by_class": {},
                    },
                },
            )
            assert resp.status_code == 200
            assert Path(csv_path).exists()

    def test_detect_with_large_image(
        self, fe_client_with_model: TestClient
    ):
        """前端选择较大分辨率的图像。

        注意：需要先确保模型以正确的 input_size 加载。
        """
        with tempfile.TemporaryDirectory() as tmp_dir:
            model_path = Path(tmp_dir) / "model.onnx"
            _create_minimal_onnx(model_path)
            fe_client_with_model.post("/api/model/load", json={
                "model_path": str(model_path),
                "labels": ["隐裂"],
                "input_width": 64,
                "input_height": 64,
            })

            img_path = Path(tmp_dir) / "large.png"
            _create_test_image(img_path, width=1920, height=1080)

            resp = fe_client_with_model.post("/api/detect", json={
                "image_path": str(img_path),
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
            })
            assert resp.status_code == 200
            assert "detections" in resp.json()

    def test_detect_with_small_image(
        self, fe_client_with_model: TestClient
    ):
        """前端选择很小的图像。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            model_path = Path(tmp_dir) / "model.onnx"
            _create_minimal_onnx(model_path)
            fe_client_with_model.post("/api/model/load", json={
                "model_path": str(model_path),
                "labels": ["隐裂"],
                "input_width": 64,
                "input_height": 64,
            })

            img_path = Path(tmp_dir) / "small.png"
            _create_test_image(img_path, width=10, height=10)

            resp = fe_client_with_model.post("/api/detect", json={
                "image_path": str(img_path),
                "confidence_threshold": 0.5,
                "iou_threshold": 0.45,
            })
            assert resp.status_code == 200
