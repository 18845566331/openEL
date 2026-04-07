"""批量图像检测 - 属性测试和单元测试。

包含:
- 属性 11: 批量目录扫描完整性 (需求 3.1, 3.4)
- 属性 12: 递归扫描深度 (需求 3.3)
- 属性 13: 批量处理容错性 (需求 3.7)
- 属性 14: 批量统计正确性 (需求 3.8, 3.9, 3.10)
- 单元测试: 平面目录扫描、递归目录扫描、文件过滤、错误容错、统计计算
  (需求 3.1, 3.3, 3.4, 3.7, 3.8)
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient
from hypothesis import given, settings, assume, HealthCheck
import hypothesis.strategies as st

from app.main import app


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

def _create_minimal_onnx(path: Path) -> None:
    """创建一个最小的 Identity ONNX 模型。"""
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
    """使用 numpy 随机生成 + cv2.imwrite 创建测试图像。"""
    img = np.random.randint(0, 256, (height, width, 3), dtype=np.uint8)
    cv2.imwrite(str(path), img)


def _load_model_via_api(client: TestClient, model_path: Path) -> None:
    """通过 API 加载模型。"""
    resp = client.post("/api/model/load", json={
        "model_path": str(model_path),
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


def _populate_images(
    directory: Path,
    count: int,
    extensions: list[str] | None = None,
    width: int = 64,
    height: int = 64,
) -> list[Path]:
    """在指定目录中创建测试图像文件，返回创建的文件路径列表。"""
    if extensions is None:
        extensions = ["png"]
    created: list[Path] = []
    for i in range(count):
        ext = extensions[i % len(extensions)]
        img_path = directory / f"img_{i:04d}.{ext}"
        _create_test_image(img_path, width, height)
        created.append(img_path)
    return created


def _call_batch_detect(
    client: TestClient,
    input_dir: str,
    recursive: bool = False,
    extensions: list[str] | None = None,
    max_images: int = 5000,
) -> dict[str, Any]:
    """调用批量检测 API 并返回结果。"""
    payload: dict[str, Any] = {
        "input_dir": input_dir,
        "recursive": recursive,
        "max_images": max_images,
    }
    if extensions is not None:
        payload["extensions"] = extensions
    resp = client.post("/api/detect/batch", json=payload)
    assert resp.status_code == 200, f"批量检测失败: {resp.text}"
    return resp.json()


# ---------------------------------------------------------------------------
# 共享 Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def onnx_model_path(tmp_path_factory) -> Path:
    """模块级别的临时 ONNX 模型文件。"""
    tmp_dir = tmp_path_factory.mktemp("batch_models")
    model_path = tmp_dir / "test_model.onnx"
    _create_minimal_onnx(model_path)
    return model_path


@pytest.fixture(scope="module")
def client_with_model(onnx_model_path: Path) -> TestClient:
    """模块级别的已加载模型的 TestClient。"""
    c = TestClient(app)
    _load_model_via_api(c, onnx_model_path)
    return c


# ---------------------------------------------------------------------------
# Hypothesis 策略
# ---------------------------------------------------------------------------

# 图像数量策略: 1~10 张（保持测试速度合理）
image_count_st = st.integers(min_value=1, max_value=10)

# 扩展名策略: 从支持的格式中选取子集
SUPPORTED_EXTENSIONS = ["jpg", "jpeg", "png", "bmp", "tif", "tiff"]
extensions_st = st.lists(
    st.sampled_from(SUPPORTED_EXTENSIONS),
    min_size=1,
    max_size=4,
    unique=True,
)

# 子目录深度策略
depth_st = st.integers(min_value=1, max_value=3)

# 子目录数量策略
subdir_count_st = st.integers(min_value=1, max_value=3)

# 损坏文件数量策略
corrupt_count_st = st.integers(min_value=1, max_value=3)


# ===========================================================================
# 属性 11: 批量目录扫描完整性
# ===========================================================================

class TestProperty11BatchDirectoryScanCompleteness:
    """
    Feature: el-defect-detection, Property 11: 批量目录扫描完整性
    **Validates: Requirements 3.1, 3.4**
    """

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        num_images=image_count_st,
        exts=extensions_st,
        data=st.data(),
    )
    def test_scan_finds_all_matching_images(
        self,
        client_with_model: TestClient,
        tmp_path: Path,
        num_images: int,
        exts: list[str],
        data: st.DataObject,
    ):
        """
        Feature: el-defect-detection, Property 11: 批量目录扫描完整性
        **Validates: Requirements 3.1, 3.4**

        对于任何包含图像文件的目录，扫描操作应该找到所有匹配指定扩展名的图像文件。
        """
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            test_dir = Path(td)
            created = _populate_images(test_dir, num_images, exts)

            # 确保所有图像都已创建
            assume(len(created) == num_images)

            # 调用批量检测
            result = _call_batch_detect(
                client_with_model,
                input_dir=str(test_dir),
                recursive=False,
                extensions=exts,
            )

            # 验证: 扫描到的图像数量应等于创建的图像数量
            assert result["total_images"] == num_images, (
                f"期望扫描到 {num_images} 张图像，实际扫描到 {result['total_images']} 张"
            )
            # 验证: 结果列表长度应等于图像数量
            assert len(result["results"]) == num_images

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        num_matching=st.integers(min_value=1, max_value=5),
        num_non_matching=st.integers(min_value=1, max_value=5),
    )
    def test_scan_filters_by_extension(
        self,
        client_with_model: TestClient,
        tmp_path: Path,
        num_matching: int,
        num_non_matching: int,
    ):
        """
        Feature: el-defect-detection, Property 11: 批量目录扫描完整性
        **Validates: Requirements 3.1, 3.4**

        扫描操作应该只找到匹配指定扩展名的文件，忽略其他扩展名的文件。
        """
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            test_dir = Path(td)

            # 创建匹配扩展名的图像 (png)
            _populate_images(test_dir, num_matching, ["png"])

            # 创建不匹配扩展名的文件 (txt)
            for i in range(num_non_matching):
                (test_dir / f"other_{i}.txt").write_text("not an image")

            result = _call_batch_detect(
                client_with_model,
                input_dir=str(test_dir),
                extensions=["png"],
            )

            # 验证: 只扫描到匹配扩展名的图像
            assert result["total_images"] == num_matching


# ===========================================================================
# 属性 12: 递归扫描深度
# ===========================================================================

class TestProperty12RecursiveScanDepth:
    """
    Feature: el-defect-detection, Property 12: 递归扫描深度
    **Validates: Requirements 3.3**
    """

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        top_count=st.integers(min_value=1, max_value=5),
        sub_count=st.integers(min_value=1, max_value=5),
        depth=depth_st,
    )
    def test_recursive_true_includes_subdirectories(
        self,
        client_with_model: TestClient,
        tmp_path: Path,
        top_count: int,
        sub_count: int,
        depth: int,
    ):
        """
        Feature: el-defect-detection, Property 12: 递归扫描深度
        **Validates: Requirements 3.3**

        当 recursive 为 true 时，扫描应该包含所有子目录中的图像。
        """
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            test_dir = Path(td)

            # 在顶层目录创建图像
            _populate_images(test_dir, top_count, ["png"])

            # 在嵌套子目录中创建图像
            current = test_dir
            for d in range(depth):
                current = current / f"sub_{d}"
                current.mkdir(exist_ok=True)
            _populate_images(current, sub_count, ["png"])

            total_expected = top_count + sub_count

            # recursive=True: 应该找到所有图像
            result = _call_batch_detect(
                client_with_model,
                input_dir=str(test_dir),
                recursive=True,
                extensions=["png"],
            )
            assert result["total_images"] == total_expected, (
                f"recursive=True 时期望 {total_expected} 张，实际 {result['total_images']} 张"
            )

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        top_count=st.integers(min_value=1, max_value=5),
        sub_count=st.integers(min_value=1, max_value=5),
    )
    def test_recursive_false_only_top_level(
        self,
        client_with_model: TestClient,
        tmp_path: Path,
        top_count: int,
        sub_count: int,
    ):
        """
        Feature: el-defect-detection, Property 12: 递归扫描深度
        **Validates: Requirements 3.3**

        当 recursive 为 false 时，应该只包含顶层目录的图像。
        """
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            test_dir = Path(td)

            # 在顶层目录创建图像
            _populate_images(test_dir, top_count, ["png"])

            # 在子目录中创建图像
            sub_dir = test_dir / "subdir"
            sub_dir.mkdir(exist_ok=True)
            _populate_images(sub_dir, sub_count, ["png"])

            # recursive=False: 应该只找到顶层图像
            result = _call_batch_detect(
                client_with_model,
                input_dir=str(test_dir),
                recursive=False,
                extensions=["png"],
            )
            assert result["total_images"] == top_count, (
                f"recursive=False 时期望 {top_count} 张，实际 {result['total_images']} 张"
            )


# ===========================================================================
# 属性 13: 批量处理容错性
# ===========================================================================

class TestProperty13BatchFaultTolerance:
    """
    Feature: el-defect-detection, Property 13: 批量处理容错性
    **Validates: Requirements 3.7**
    """

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        valid_count=st.integers(min_value=1, max_value=5),
        corrupt_count=corrupt_count_st,
    )
    def test_continues_processing_after_invalid_images(
        self,
        client_with_model: TestClient,
        tmp_path: Path,
        valid_count: int,
        corrupt_count: int,
    ):
        """
        Feature: el-defect-detection, Property 13: 批量处理容错性
        **Validates: Requirements 3.7**

        对于任何包含部分无效图像的批量检测任务，系统应该成功处理所有有效图像，
        并在结果中记录无效图像的错误信息，而不是中止整个批量任务。
        """
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            test_dir = Path(td)

            # 创建有效图像
            _populate_images(test_dir, valid_count, ["png"])

            # 创建损坏的图像文件（有效的图像扩展名但内容无效）
            for i in range(corrupt_count):
                corrupt_path = test_dir / f"corrupt_{i:04d}.png"
                corrupt_path.write_bytes(b"this is not a valid image file content")

            total_files = valid_count + corrupt_count

            result = _call_batch_detect(
                client_with_model,
                input_dir=str(test_dir),
                extensions=["png"],
            )

            # 验证: 所有文件都被处理（包括损坏的）
            assert result["total_images"] == total_files, (
                f"期望处理 {total_files} 个文件，实际处理 {result['total_images']} 个"
            )
            assert len(result["results"]) == total_files

            # 验证: 损坏的图像应该有 error 字段
            error_results = [r for r in result["results"] if "error" in r and r["error"]]
            assert len(error_results) >= corrupt_count, (
                f"期望至少 {corrupt_count} 个错误记录，实际 {len(error_results)} 个"
            )

            # 验证: 有效图像应该被成功处理（无 error 字段或 error 为空）
            success_results = [r for r in result["results"] if "error" not in r or not r["error"]]
            assert len(success_results) >= valid_count, (
                f"期望至少 {valid_count} 个成功结果，实际 {len(success_results)} 个"
            )


# ===========================================================================
# 属性 14: 批量统计正确性
# ===========================================================================

class TestProperty14BatchStatisticsCorrectness:
    """
    Feature: el-defect-detection, Property 14: 批量统计正确性
    **Validates: Requirements 3.8, 3.9, 3.10**
    """

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        num_images=st.integers(min_value=1, max_value=10),
    )
    def test_total_equals_ok_plus_ng(
        self,
        client_with_model: TestClient,
        tmp_path: Path,
        num_images: int,
    ):
        """
        Feature: el-defect-detection, Property 14: 批量统计正确性
        **Validates: Requirements 3.8, 3.9, 3.10**

        total_images = ok_images + ng_images
        """
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            test_dir = Path(td)
            _populate_images(test_dir, num_images, ["png"])

            result = _call_batch_detect(
                client_with_model,
                input_dir=str(test_dir),
                extensions=["png"],
            )

            # 验证: total_images = ok_images + ng_images
            assert result["total_images"] == result["ok_images"] + result["ng_images"], (
                f"total_images({result['total_images']}) != "
                f"ok_images({result['ok_images']}) + ng_images({result['ng_images']})"
            )

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        num_images=st.integers(min_value=1, max_value=10),
    )
    def test_total_defects_equals_sum_of_class_counts(
        self,
        client_with_model: TestClient,
        tmp_path: Path,
        num_images: int,
    ):
        """
        Feature: el-defect-detection, Property 14: 批量统计正确性
        **Validates: Requirements 3.8, 3.9, 3.10**

        total_defects = sum(defect_by_class.values())
        """
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            test_dir = Path(td)
            _populate_images(test_dir, num_images, ["png"])

            result = _call_batch_detect(
                client_with_model,
                input_dir=str(test_dir),
                extensions=["png"],
            )

            # 验证: total_defects = sum(defect_by_class.values())
            class_sum = sum(result["defect_by_class"].values())
            assert result["total_defects"] == class_sum, (
                f"total_defects({result['total_defects']}) != "
                f"sum(defect_by_class)({class_sum})"
            )

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        num_images=st.integers(min_value=1, max_value=10),
    )
    def test_ng_images_matches_results_with_detections(
        self,
        client_with_model: TestClient,
        tmp_path: Path,
        num_images: int,
    ):
        """
        Feature: el-defect-detection, Property 14: 批量统计正确性
        **Validates: Requirements 3.8, 3.9, 3.10**

        ng_images = 检测结果中 total > 0 的图像数量
        """
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            test_dir = Path(td)
            _populate_images(test_dir, num_images, ["png"])

            result = _call_batch_detect(
                client_with_model,
                input_dir=str(test_dir),
                extensions=["png"],
            )

            # 验证: ng_images = 检测结果中 total > 0 的图像数量
            actual_ng = sum(1 for r in result["results"] if r.get("total", 0) > 0)
            assert result["ng_images"] == actual_ng, (
                f"ng_images({result['ng_images']}) != 实际NG数量({actual_ng})"
            )

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        num_images=st.integers(min_value=1, max_value=10),
    )
    def test_class_counts_match_detection_details(
        self,
        client_with_model: TestClient,
        tmp_path: Path,
        num_images: int,
    ):
        """
        Feature: el-defect-detection, Property 14: 批量统计正确性
        **Validates: Requirements 3.8, 3.9, 3.10**

        每个类别的统计数量 = 所有检测结果中该类别出现的次数
        """
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            test_dir = Path(td)
            _populate_images(test_dir, num_images, ["png"])

            result = _call_batch_detect(
                client_with_model,
                input_dir=str(test_dir),
                extensions=["png"],
            )

            # 从详细结果中手动统计每个类别的出现次数
            from collections import Counter
            manual_counter: Counter[str] = Counter()
            for r in result["results"]:
                for det in r.get("detections", []):
                    manual_counter[det["class_name"]] += 1

            # 验证: defect_by_class 与手动统计一致
            for cls_name, count in result["defect_by_class"].items():
                assert count == manual_counter[cls_name], (
                    f"类别 '{cls_name}' 统计不一致: "
                    f"defect_by_class={count}, 手动统计={manual_counter[cls_name]}"
                )

            # 验证: 手动统计中的所有类别都在 defect_by_class 中
            for cls_name, count in manual_counter.items():
                assert cls_name in result["defect_by_class"], (
                    f"类别 '{cls_name}' 在检测结果中出现但不在 defect_by_class 中"
                )


# ===========================================================================
# 单元测试: 批量图像检测
# ===========================================================================

class TestBatchDetectUnit:
    """批量图像检测单元测试。

    需求: 3.1, 3.3, 3.4, 3.7, 3.8
    """

    def test_flat_directory_scan(self, client_with_model: TestClient, tmp_path: Path):
        """需求 3.1: 扫描目录下的所有图像文件（平面目录）。"""
        test_dir = tmp_path / "flat_scan"
        test_dir.mkdir()
        _populate_images(test_dir, 5, ["png", "jpg"])

        result = _call_batch_detect(
            client_with_model,
            input_dir=str(test_dir),
            extensions=["png", "jpg"],
        )

        assert result["total_images"] == 5
        assert len(result["results"]) == 5

    def test_recursive_directory_scan(self, client_with_model: TestClient, tmp_path: Path):
        """需求 3.3: 启用递归扫描时扫描所有子目录。"""
        test_dir = tmp_path / "recursive_scan"
        test_dir.mkdir()

        # 顶层 3 张
        _populate_images(test_dir, 3, ["png"])

        # 子目录 2 张
        sub1 = test_dir / "sub1"
        sub1.mkdir()
        _populate_images(sub1, 2, ["png"])

        # 嵌套子目录 1 张
        sub2 = sub1 / "sub2"
        sub2.mkdir()
        _populate_images(sub2, 1, ["png"])

        result = _call_batch_detect(
            client_with_model,
            input_dir=str(test_dir),
            recursive=True,
            extensions=["png"],
        )

        assert result["total_images"] == 6

    def test_non_recursive_ignores_subdirectories(
        self, client_with_model: TestClient, tmp_path: Path
    ):
        """需求 3.3: 未启用递归扫描时只扫描顶层目录。"""
        test_dir = tmp_path / "non_recursive_scan"
        test_dir.mkdir()

        _populate_images(test_dir, 3, ["png"])

        sub = test_dir / "sub"
        sub.mkdir()
        _populate_images(sub, 2, ["png"])

        result = _call_batch_detect(
            client_with_model,
            input_dir=str(test_dir),
            recursive=False,
            extensions=["png"],
        )

        assert result["total_images"] == 3

    def test_extension_filter_only_matching(
        self, client_with_model: TestClient, tmp_path: Path
    ):
        """需求 3.4: 通过文件扩展名过滤图像文件。"""
        test_dir = tmp_path / "ext_filter"
        test_dir.mkdir()

        # 创建 png 和 jpg 图像
        _populate_images(test_dir, 3, ["png"])
        _populate_images(test_dir, 2, ["jpg"])

        # 只过滤 png
        result = _call_batch_detect(
            client_with_model,
            input_dir=str(test_dir),
            extensions=["png"],
        )

        assert result["total_images"] == 3

    def test_extension_filter_case_insensitive(
        self, client_with_model: TestClient, tmp_path: Path
    ):
        """需求 3.4: 扩展名过滤应不区分大小写。"""
        test_dir = tmp_path / "case_filter"
        test_dir.mkdir()

        # 创建大写扩展名的图像
        img = np.random.randint(0, 256, (64, 64, 3), dtype=np.uint8)
        cv2.imwrite(str(test_dir / "upper.PNG"), img)
        cv2.imwrite(str(test_dir / "lower.png"), img)

        result = _call_batch_detect(
            client_with_model,
            input_dir=str(test_dir),
            extensions=["png"],
        )

        assert result["total_images"] == 2

    def test_fault_tolerance_with_corrupt_images(
        self, client_with_model: TestClient, tmp_path: Path
    ):
        """需求 3.7: 某张图像检测失败时记录错误并继续处理。"""
        test_dir = tmp_path / "fault_tolerance"
        test_dir.mkdir()

        # 创建 2 张有效图像
        _populate_images(test_dir, 2, ["png"])

        # 创建 1 张损坏图像
        corrupt = test_dir / "corrupt.png"
        corrupt.write_bytes(b"invalid image data")

        result = _call_batch_detect(
            client_with_model,
            input_dir=str(test_dir),
            extensions=["png"],
        )

        # 所有文件都应被处理
        assert result["total_images"] == 3
        assert len(result["results"]) == 3

        # 损坏图像应有 error 字段
        errors = [r for r in result["results"] if r.get("error")]
        assert len(errors) >= 1

    def test_statistics_calculation(self, client_with_model: TestClient, tmp_path: Path):
        """需求 3.8: 返回汇总统计信息。"""
        test_dir = tmp_path / "stats_calc"
        test_dir.mkdir()
        _populate_images(test_dir, 5, ["png"])

        result = _call_batch_detect(
            client_with_model,
            input_dir=str(test_dir),
            extensions=["png"],
        )

        # 验证统计字段存在
        assert "total_images" in result
        assert "ok_images" in result
        assert "ng_images" in result
        assert "total_defects" in result
        assert "defect_by_class" in result
        assert "results" in result

        # 验证统计一致性
        assert result["total_images"] == result["ok_images"] + result["ng_images"]
        assert result["total_defects"] == sum(result["defect_by_class"].values())
        assert result["total_images"] == 5

    def test_empty_directory_returns_zero(
        self, client_with_model: TestClient, tmp_path: Path
    ):
        """空目录应返回零统计。"""
        test_dir = tmp_path / "empty_dir"
        test_dir.mkdir()

        result = _call_batch_detect(
            client_with_model,
            input_dir=str(test_dir),
            extensions=["png"],
        )

        assert result["total_images"] == 0
        assert result["ok_images"] == 0
        assert result["ng_images"] == 0
        assert result["total_defects"] == 0
        assert result["results"] == []

    def test_nonexistent_directory_returns_error(self, client_with_model: TestClient):
        """需求 3.2: 输入目录不存在时返回错误。"""
        resp = client_with_model.post("/api/detect/batch", json={
            "input_dir": "/nonexistent/directory/path",
        })
        assert resp.status_code == 400
        assert "不存在" in resp.json()["detail"]

    def test_max_images_limit(self, client_with_model: TestClient, tmp_path: Path):
        """需求 3.5: 支持配置最大处理图像数量限制。"""
        test_dir = tmp_path / "max_limit"
        test_dir.mkdir()
        _populate_images(test_dir, 10, ["png"])

        result = _call_batch_detect(
            client_with_model,
            input_dir=str(test_dir),
            extensions=["png"],
            max_images=3,
        )

        assert result["total_images"] == 3
        assert len(result["results"]) == 3

    def test_no_matching_files_returns_zero(
        self, client_with_model: TestClient, tmp_path: Path
    ):
        """目录中没有匹配扩展名的文件时返回零统计。"""
        test_dir = tmp_path / "no_match"
        test_dir.mkdir()

        # 创建非图像文件
        (test_dir / "readme.txt").write_text("hello")
        (test_dir / "data.csv").write_text("a,b,c")

        result = _call_batch_detect(
            client_with_model,
            input_dir=str(test_dir),
            extensions=["png"],
        )

        assert result["total_images"] == 0
        assert result["results"] == []
