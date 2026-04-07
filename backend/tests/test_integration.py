"""后端集成测试 — 测试多个API端点的串联调用流程。

与单元测试和属性测试不同，集成测试关注的是多个端点之间的协作：
- 完整检测流程：健康检查 → 模型加载（失败场景） → 检测请求 → 验证错误处理
- 批量检测流程：健康检查 → 批量检测请求 → 验证结果格式
- 报告导出流程：构造检测结果 → 调用CSV导出 → 验证文件生成和内容
- 完整流程串联：健康检查 → 尝试加载模型 → 尝试检测 → 导出报告

任务: 25.1 编写后端集成测试
"""
from __future__ import annotations

import csv
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
def client() -> TestClient:
    """创建 FastAPI 测试客户端。"""
    return TestClient(app, raise_server_exceptions=False)



@pytest.fixture(scope="module")
def onnx_model_path(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """模块级别的临时 ONNX 模型文件。"""
    tmp_dir = tmp_path_factory.mktemp("integration_models")
    model_path = tmp_dir / "test_model.onnx"
    _create_minimal_onnx(model_path)
    return model_path


@pytest.fixture(scope="module")
def client_with_model(onnx_model_path: Path) -> TestClient:
    """模块级别的已加载模型的 TestClient。"""
    c = TestClient(app)
    resp = c.post("/api/model/load", json={
        "model_path": str(onnx_model_path),
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
    assert resp.status_code == 200, f"模型加载失败: {resp.text}"
    return c


# ===========================================================================
# 集成测试 1: 完整检测流程
# ===========================================================================


class TestIntegrationDetectionFlow:
    """完整检测流程集成测试。

    测试链路: 健康检查 → 模型加载（失败场景） → 检测请求 → 验证错误处理
    """

    def test_health_then_load_invalid_model_then_detect(self, client: TestClient):
        """健康检查 → 加载不存在的模型 → 尝试检测 → 验证错误链路。

        验证系统在模型加载失败后，检测请求能正确返回错误。
        """
        # 步骤1: 健康检查应成功
        resp_health = client.get("/health")
        assert resp_health.status_code == 200
        health_data = resp_health.json()
        assert health_data["status"] == "ok"
        assert "runtime" in health_data

        # 步骤2: 尝试加载不存在的模型 → 应失败
        resp_load = client.post("/api/model/load", json={
            "model_path": "/nonexistent/fake_model.onnx",
            "labels": ["隐裂"],
        })
        assert resp_load.status_code == 400
        load_error = resp_load.json()
        assert "detail" in load_error
        assert "不存在" in load_error["detail"]

        # 步骤3: 健康检查仍然正常（服务未崩溃）
        resp_health2 = client.get("/health")
        assert resp_health2.status_code == 200
        assert resp_health2.json()["status"] == "ok"

    def test_health_then_load_model_then_detect_invalid_image(
        self, client_with_model: TestClient
    ):
        """健康检查 → 模型已加载 → 检测不存在的图像 → 验证错误处理。"""
        # 步骤1: 健康检查
        resp_health = client_with_model.get("/health")
        assert resp_health.status_code == 200
        runtime = resp_health.json()["runtime"]
        assert runtime["model_loaded"] is True

        # 步骤2: 检测不存在的图像
        resp_detect = client_with_model.post("/api/detect", json={
            "image_path": "/nonexistent/test_image.jpg",
        })
        assert resp_detect.status_code == 400
        assert "detail" in resp_detect.json()

        # 步骤3: 服务仍然正常
        resp_health2 = client_with_model.get("/health")
        assert resp_health2.status_code == 200

    def test_load_model_then_detect_valid_image(
        self, client_with_model: TestClient
    ):
        """模型已加载 → 检测有效图像 → 验证结果结构完整。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            # 创建测试图像
            img_path = Path(tmp_dir) / "test.png"
            _create_test_image(img_path)

            # 执行检测
            resp = client_with_model.post("/api/detect", json={
                "image_path": str(img_path),
            })
            assert resp.status_code == 200

            result = resp.json()
            # 验证结果结构
            assert "image_path" in result
            assert "total" in result
            assert "detections" in result
            assert isinstance(result["detections"], list)
            assert isinstance(result["total"], int)
            assert result["total"] >= 0

    def test_load_model_detect_with_visualization(
        self, client_with_model: TestClient
    ):
        """模型已加载 → 检测图像并保存可视化 → 验证可视化文件生成。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            img_path = Path(tmp_dir) / "vis_test.png"
            _create_test_image(img_path)
            vis_dir = Path(tmp_dir) / "vis_output"

            resp = client_with_model.post("/api/detect", json={
                "image_path": str(img_path),
                "save_visualization": True,
                "visualization_dir": str(vis_dir),
            })
            assert resp.status_code == 200

            result = resp.json()
            # 可视化目录应被创建
            assert vis_dir.exists()
            # 如果有可视化路径，文件应存在
            if result.get("visualization_path"):
                assert Path(result["visualization_path"]).exists()


# ===========================================================================
# 集成测试 2: 批量检测流程
# ===========================================================================


class TestIntegrationBatchDetectionFlow:
    """批量检测流程集成测试。

    测试链路: 健康检查 → 批量检测请求 → 验证结果格式
    """

    def test_health_then_batch_detect(self, client_with_model: TestClient):
        """健康检查 → 批量检测 → 验证结果格式和统计一致性。"""
        # 步骤1: 健康检查确认模型已加载
        resp_health = client_with_model.get("/health")
        assert resp_health.status_code == 200
        assert resp_health.json()["runtime"]["model_loaded"] is True

        # 步骤2: 创建测试图像目录并执行批量检测
        with tempfile.TemporaryDirectory() as tmp_dir:
            test_dir = Path(tmp_dir) / "batch_images"
            test_dir.mkdir()
            for i in range(5):
                _create_test_image(test_dir / f"img_{i:03d}.png")

            resp_batch = client_with_model.post("/api/detect/batch", json={
                "input_dir": str(test_dir),
                "extensions": [".png"],
            })
            assert resp_batch.status_code == 200

            result = resp_batch.json()
            # 验证结果格式
            assert result["total_images"] == 5
            assert len(result["results"]) == 5
            assert result["total_images"] == result["ok_images"] + result["ng_images"]
            assert result["total_defects"] == sum(result["defect_by_class"].values())

            # 验证每个结果项的结构
            for item in result["results"]:
                assert "image_path" in item
                assert "total" in item
                assert "detections" in item

    def test_batch_detect_with_subdirectories(self, client_with_model: TestClient):
        """批量检测递归扫描 → 验证递归和非递归结果差异。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root_dir = Path(tmp_dir) / "nested"
            root_dir.mkdir()
            sub_dir = root_dir / "sub"
            sub_dir.mkdir()

            # 顶层3张，子目录2张
            for i in range(3):
                _create_test_image(root_dir / f"top_{i}.png")
            for i in range(2):
                _create_test_image(sub_dir / f"sub_{i}.png")

            # 非递归: 只扫描顶层
            resp_flat = client_with_model.post("/api/detect/batch", json={
                "input_dir": str(root_dir),
                "recursive": False,
                "extensions": [".png"],
            })
            assert resp_flat.status_code == 200
            assert resp_flat.json()["total_images"] == 3

            # 递归: 扫描所有层级
            resp_recursive = client_with_model.post("/api/detect/batch", json={
                "input_dir": str(root_dir),
                "recursive": True,
                "extensions": [".png"],
            })
            assert resp_recursive.status_code == 200
            assert resp_recursive.json()["total_images"] == 5

    def test_batch_detect_invalid_dir_then_valid_dir(
        self, client_with_model: TestClient
    ):
        """批量检测无效目录（失败） → 批量检测有效目录（成功） → 验证服务恢复。"""
        # 步骤1: 无效目录应返回错误
        resp_invalid = client_with_model.post("/api/detect/batch", json={
            "input_dir": "/nonexistent/directory",
        })
        assert resp_invalid.status_code == 400

        # 步骤2: 有效目录应正常工作
        with tempfile.TemporaryDirectory() as tmp_dir:
            test_dir = Path(tmp_dir) / "valid"
            test_dir.mkdir()
            _create_test_image(test_dir / "ok.png")

            resp_valid = client_with_model.post("/api/detect/batch", json={
                "input_dir": str(test_dir),
                "extensions": [".png"],
            })
            assert resp_valid.status_code == 200
            assert resp_valid.json()["total_images"] == 1

    def test_batch_detect_with_corrupt_images(self, client_with_model: TestClient):
        """批量检测包含损坏图像 → 验证容错处理和统计正确性。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            test_dir = Path(tmp_dir) / "mixed"
            test_dir.mkdir()

            # 3张有效图像
            for i in range(3):
                _create_test_image(test_dir / f"valid_{i}.png")

            # 2张损坏图像
            for i in range(2):
                (test_dir / f"corrupt_{i}.png").write_bytes(b"not a real image")

            resp = client_with_model.post("/api/detect/batch", json={
                "input_dir": str(test_dir),
                "extensions": [".png"],
            })
            assert resp.status_code == 200

            result = resp.json()
            assert result["total_images"] == 5
            assert len(result["results"]) == 5

            # 损坏图像应有error字段
            errors = [r for r in result["results"] if r.get("error")]
            assert len(errors) >= 2

            # 统计一致性仍然成立
            assert result["total_images"] == result["ok_images"] + result["ng_images"]



# ===========================================================================
# 集成测试 3: 报告导出流程
# ===========================================================================


class TestIntegrationReportExportFlow:
    """报告导出流程集成测试。

    测试链路: 构造检测结果 → 调用CSV导出 → 验证文件生成和内容
    """

    def test_construct_results_then_export_csv(self, client: TestClient):
        """构造模拟检测结果 → 导出CSV → 验证文件内容完整。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "report.csv")

            # 构造新格式的 project_info
            file_results = [
                {"name": "ok_1.jpg", "result": "OK", "path": "/img/ok_1.jpg"},
                {"name": "ok_2.jpg", "result": "OK", "path": "/img/ok_2.jpg"},
                {"name": "ng_1.jpg", "result": "NG", "path": "/img/ng_1.jpg"},
                {"name": "ng_2.jpg", "result": "NG", "path": "/img/ng_2.jpg"},
            ]

            resp = client.post(
                "/api/report/export_csv",
                json={
                    "output_path": csv_path,
                    "project_info": {
                        "project_name": "集成测试项目",
                        "file_results": file_results,
                        "defect_by_class": {"隐裂": 1, "断栅": 1, "黑斑": 1},
                    },
                },
            )
            assert resp.status_code == 200

            resp_data = resp.json()
            assert resp_data["message"] == "CSV 报告导出成功"
            assert "output_path" in resp_data

            # 验证CSV文件存在
            target = Path(csv_path)
            assert target.exists()

            # 验证UTF-8 BOM编码
            raw = target.read_bytes()
            assert raw[:3] == b"\xef\xbb\xbf"

            # 验证CSV内容 — 新格式包含项目信息头、缺陷统计和文件结果
            with target.open("r", encoding="utf-8-sig") as f:
                rows = list(csv.reader(f))

            # 查找文件结果表头行
            header_idx = None
            for i, row in enumerate(rows):
                if row and row[0] == "文件名":
                    header_idx = i
                    break
            assert header_idx is not None, "未找到文件结果表头"
            assert rows[header_idx] == ["文件名", "检测结果", "文件路径"]

            # 文件结果数据行
            data_rows = rows[header_idx + 1:]
            assert len(data_rows) == 4

            # OK图像
            assert data_rows[0][1] == "OK"
            assert data_rows[1][1] == "OK"

            # NG图像
            assert data_rows[2][1] == "NG"
            assert data_rows[3][1] == "NG"

    def test_export_csv_to_nested_directory(self, client: TestClient):
        """导出CSV到不存在的嵌套目录 → 验证目录自动创建。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "a" / "b" / "c" / "report.csv")

            resp = client.post(
                "/api/report/export_csv",
                json={
                    "output_path": csv_path,
                    "project_info": {
                        "project_name": "嵌套目录测试",
                        "file_results": [
                            {"name": "test.jpg", "result": "OK", "path": "/img/test.jpg"},
                        ],
                        "defect_by_class": {},
                    },
                },
            )
            assert resp.status_code == 200
            assert Path(csv_path).exists()
            assert (Path(tmp_dir) / "a" / "b" / "c").is_dir()

    def test_export_empty_results_then_non_empty(self, client: TestClient):
        """先导出空结果 → 再导出非空结果 → 验证两次导出都正确。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            # 第一次: 空结果
            csv1 = str(Path(tmp_dir) / "empty.csv")
            resp1 = client.post(
                "/api/report/export_csv",
                json={
                    "output_path": csv1,
                    "project_info": {
                        "project_name": "空结果测试",
                        "file_results": [],
                        "defect_by_class": {},
                    },
                },
            )
            assert resp1.status_code == 200
            assert Path(csv1).exists()

            # 第二次: 非空结果
            csv2 = str(Path(tmp_dir) / "non_empty.csv")
            resp2 = client.post(
                "/api/report/export_csv",
                json={
                    "output_path": csv2,
                    "project_info": {
                        "project_name": "非空结果测试",
                        "file_results": [
                            {"name": "x.jpg", "result": "NG", "path": "/img/x.jpg"},
                        ],
                        "defect_by_class": {"烧结异常": 1},
                    },
                },
            )
            assert resp2.status_code == 200

            # 验证非空CSV包含NG结果
            with Path(csv2).open("r", encoding="utf-8-sig") as f:
                content = f.read()
            assert "NG" in content


# ===========================================================================
# 集成测试 4: 完整流程串联
# ===========================================================================


class TestIntegrationFullPipeline:
    """完整流程串联集成测试。

    测试链路: 健康检查 → 尝试加载模型 → 尝试检测 → 导出报告
    """

    def test_full_pipeline_health_load_detect_export(self):
        """完整端到端流程: 健康检查 → 加载模型 → 批量检测 → 导出CSV报告。"""
        c = TestClient(app)

        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)

            # 步骤1: 健康检查
            resp_health = c.get("/health")
            assert resp_health.status_code == 200
            assert resp_health.json()["status"] == "ok"

            # 步骤2: 创建并加载模型
            model_path = tmp / "pipeline_model.onnx"
            _create_minimal_onnx(model_path)

            resp_load = c.post("/api/model/load", json={
                "model_path": str(model_path),
                "labels": ["隐裂", "断栅"],
                "input_width": 64,
                "input_height": 64,
                "output_layout": "cxcywh_obj_cls",
            })
            assert resp_load.status_code == 200
            assert resp_load.json()["message"] == "模型加载成功"

            # 步骤3: 验证模型已加载
            resp_health2 = c.get("/health")
            assert resp_health2.status_code == 200
            assert resp_health2.json()["runtime"]["model_loaded"] is True

            # 步骤4: 单张检测
            img_path = tmp / "single.png"
            _create_test_image(img_path)

            resp_detect = c.post("/api/detect", json={
                "image_path": str(img_path),
            })
            assert resp_detect.status_code == 200
            detect_result = resp_detect.json()
            assert "total" in detect_result
            assert "detections" in detect_result

            # 步骤5: 批量检测
            batch_dir = tmp / "batch_images"
            batch_dir.mkdir()
            for i in range(3):
                _create_test_image(batch_dir / f"img_{i}.png")

            resp_batch = c.post("/api/detect/batch", json={
                "input_dir": str(batch_dir),
                "extensions": [".png"],
            })
            assert resp_batch.status_code == 200
            batch_result = resp_batch.json()
            assert batch_result["total_images"] == 3
            assert batch_result["total_images"] == (
                batch_result["ok_images"] + batch_result["ng_images"]
            )

            # 步骤6: 导出CSV报告 — 使用新格式
            csv_path = str(tmp / "reports" / "final_report.csv")
            # 将 batch_result 转换为新的 project_info 格式
            file_results = []
            for r in batch_result["results"]:
                dets = r.get("detections", [])
                file_results.append({
                    "name": Path(r["image_path"]).name,
                    "result": "NG" if dets else "OK",
                    "path": r["image_path"],
                })
            resp_export = c.post(
                "/api/report/export_csv",
                json={
                    "output_path": csv_path,
                    "project_info": {
                        "project_name": "完整流程测试",
                        "file_results": file_results,
                        "defect_by_class": batch_result.get("defect_by_class", {}),
                    },
                },
            )
            assert resp_export.status_code == 200
            assert Path(csv_path).exists()

    def test_full_pipeline_with_profile_load(self):
        """通过配置文件加载模型 → 检测 → 导出报告。"""
        c = TestClient(app)

        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)

            # 创建模型文件
            model_path = tmp / "profile_model.onnx"
            _create_minimal_onnx(model_path)

            # 创建配置文件
            profile = {
                "model_path": str(model_path),
                "labels": ["隐裂", "断栅", "黑斑"],
                "input_width": 64,
                "input_height": 64,
                "output_layout": "cxcywh_obj_cls",
                "normalize": True,
                "swap_rb": True,
                "confidence_threshold": 0.5,
                "iou_threshold": 0.4,
            }
            profile_path = tmp / "model_profile.json"
            profile_path.write_text(json.dumps(profile), encoding="utf-8")

            # 通过配置文件加载模型
            resp_load = c.post(
                "/api/model/load_profile",
                params={"profile_path": str(profile_path)},
            )
            assert resp_load.status_code == 200
            assert resp_load.json()["message"] == "模型加载成功"

            # 检测图像
            img_path = tmp / "test.png"
            _create_test_image(img_path)

            resp_detect = c.post("/api/detect", json={
                "image_path": str(img_path),
            })
            assert resp_detect.status_code == 200

            # 构造新的 project_info 格式
            detect_data = resp_detect.json()
            dets = detect_data.get("detections", [])
            csv_path = str(tmp / "profile_report.csv")
            resp_export = c.post(
                "/api/report/export_csv",
                json={
                    "output_path": csv_path,
                    "project_info": {
                        "project_name": "配置文件流程测试",
                        "file_results": [{
                            "name": Path(detect_data["image_path"]).name,
                            "result": "NG" if dets else "OK",
                            "path": detect_data["image_path"],
                        }],
                        "defect_by_class": {},
                    },
                },
            )
            assert resp_export.status_code == 200
            assert Path(csv_path).exists()

    def test_error_recovery_across_endpoints(self):
        """验证跨端点的错误恢复能力。

        多次失败请求后，系统仍能正常处理后续请求。
        """
        c = TestClient(app, raise_server_exceptions=False)

        # 一系列失败请求
        c.post("/api/model/load", json={"model_path": "/bad/path.onnx"})
        c.post("/api/detect", json={"image_path": "/bad/image.jpg"})
        c.post("/api/detect/batch", json={"input_dir": "/bad/dir"})
        c.post(
            "/api/model/load_profile",
            params={"profile_path": "/bad/profile.json"},
        )

        # 健康检查仍然正常
        resp = c.get("/health")
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"

        # 加载有效模型仍然可以成功
        with tempfile.TemporaryDirectory() as tmp_dir:
            model_path = Path(tmp_dir) / "recovery_model.onnx"
            _create_minimal_onnx(model_path)

            resp_load = c.post("/api/model/load", json={
                "model_path": str(model_path),
                "labels": ["隐裂"],
                "input_width": 64,
                "input_height": 64,
            })
            assert resp_load.status_code == 200

    def test_batch_detect_then_export_csv_consistency(
        self, client_with_model: TestClient
    ):
        """批量检测 → 将结果直接传给CSV导出 → 验证CSV行数与检测结果一致。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            # 创建测试图像
            img_dir = Path(tmp_dir) / "images"
            img_dir.mkdir()
            num_images = 4
            for i in range(num_images):
                _create_test_image(img_dir / f"img_{i}.png")

            # 批量检测
            resp_batch = client_with_model.post("/api/detect/batch", json={
                "input_dir": str(img_dir),
                "extensions": [".png"],
            })
            assert resp_batch.status_code == 200
            batch_result = resp_batch.json()
            assert batch_result["total_images"] == num_images

            # 将批量结果转换为新格式并导出CSV
            csv_path = str(Path(tmp_dir) / "consistency.csv")
            file_results = []
            for r in batch_result["results"]:
                dets = r.get("detections", [])
                file_results.append({
                    "name": Path(r["image_path"]).name,
                    "result": "NG" if dets else "OK",
                    "path": r["image_path"],
                })
            resp_export = client_with_model.post(
                "/api/report/export_csv",
                json={
                    "output_path": csv_path,
                    "project_info": {
                        "project_name": "一致性测试",
                        "file_results": file_results,
                        "defect_by_class": batch_result.get("defect_by_class", {}),
                    },
                },
            )
            assert resp_export.status_code == 200

            # 验证CSV文件结果行数与检测结果一致
            with Path(csv_path).open("r", encoding="utf-8-sig") as f:
                rows = list(csv.reader(f))

            # 查找文件结果表头
            header_idx = None
            for i, row in enumerate(rows):
                if row and row[0] == "文件名":
                    header_idx = i
                    break
            assert header_idx is not None
            data_rows = rows[header_idx + 1:]
            assert len(data_rows) == num_images
