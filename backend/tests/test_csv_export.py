"""
Feature: el-defect-detection
属性 15: CSV导出结构正确性
属性 16: CSV编码正确性
属性 17: CSV缺陷明细格式
属性 18: 输出目录自动创建

当前 CSV 格式（新版）：
  项目名称, <value>
  报告编号, <value>
  委托单位, <value>
  检测单位, <value>
  检测人员, <value>
  签发日期, <value>
  (空行)
  缺陷类别, 数量
  <类别名>, <数量>    ← 每种缺陷一行
  (空行)
  文件名, 检测结果, 文件路径
  <name>, <OK|NG>, <path>   ← 每个文件一行

测试策略:
- 直接通过 FastAPI TestClient 调用 /api/report/export_csv 端点
- 构造模拟的 project_info 数据（不需要真正运行检测）
- 使用 tempfile.TemporaryDirectory() 确保每次迭代使用独立目录
"""
from __future__ import annotations

import csv
import tempfile
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from hypothesis import given, settings, assume, HealthCheck
import hypothesis.strategies as st

from app.main import app


# ---------------------------------------------------------------------------
# 辅助函数 & 策略
# ---------------------------------------------------------------------------

DEFECT_LABELS = ["隐裂", "断栅", "黑斑", "烧结异常"]

# 单个缺陷检测项策略
detection_st = st.fixed_dictionaries({
    "class_id": st.integers(min_value=0, max_value=len(DEFECT_LABELS) - 1),
    "class_name": st.sampled_from(DEFECT_LABELS),
    "score": st.floats(min_value=0.50, max_value=0.99, allow_nan=False, allow_infinity=False),
    "box": st.fixed_dictionaries({
        "x1": st.integers(min_value=0, max_value=500),
        "y1": st.integers(min_value=0, max_value=500),
        "x2": st.integers(min_value=501, max_value=1000),
        "y2": st.integers(min_value=501, max_value=1000),
    }),
})

# 单张图像结果策略（可能有0或多个缺陷）
image_result_st = st.fixed_dictionaries({
    "image_path": st.from_regex(r"/images/img_[a-z0-9]{1,10}\.(jpg|png)", fullmatch=True),
    "detections": st.lists(detection_st, min_size=0, max_size=5),
})

# 批量结果策略（1~20张图像）
batch_results_st = st.lists(image_result_st, min_size=1, max_size=20)


def _build_request_body(results: list[dict[str, Any]], output_csv: str) -> dict:
    """构建符合新 API 格式的请求 body。"""
    file_results = []
    defect_by_class: dict[str, int] = {}
    for r in results:
        dets = r.get("detections", [])
        file_results.append({
            "name": Path(r["image_path"]).name,
            "result": "NG" if dets else "OK",
            "path": r["image_path"],
        })
        for d in dets:
            cn = d.get("class_name", "unknown")
            defect_by_class[cn] = defect_by_class.get(cn, 0) + 1
    return {
        "output_path": output_csv,
        "project_info": {
            "project_name": "测试项目",
            "file_results": file_results,
            "defect_by_class": defect_by_class,
        },
    }


def _call_export(client: TestClient, results: list[dict], output_csv: str) -> Any:
    """调用 CSV 导出 API 端点。"""
    body = _build_request_body(results, output_csv)
    return client.post("/api/report/export_csv", json=body)


def _parse_csv(csv_path: str) -> list[list[str]]:
    """读取 CSV 文件为行列表。"""
    with Path(csv_path).open("r", encoding="utf-8-sig") as f:
        return list(csv.reader(f))


def _find_file_results_section(rows: list[list[str]]) -> tuple[int, list[list[str]]]:
    """找到"文件名, 检测结果, 文件路径"表头行及其后的数据行。"""
    for i, row in enumerate(rows):
        if len(row) >= 3 and row[0] == "文件名" and row[1] == "检测结果":
            return i, rows[i + 1:]
    return -1, []


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def client() -> TestClient:
    return TestClient(app)


# ===========================================================================
# 属性 15: CSV导出结构正确性
# ===========================================================================

class TestProperty15CsvStructureCorrectness:
    """
    Feature: el-defect-detection, Property 15: CSV导出结构正确性
    **Validates: Requirements 5.1, 5.2, 5.4**

    导出的 CSV 文件应包含项目信息头 + 缺陷统计 + 文件检测结果表。
    文件结果区的数据行数 = 图像数量。
    """

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(results=batch_results_st)
    def test_csv_has_project_header_and_file_results(
        self,
        client: TestClient,
        results: list[dict[str, Any]],
    ):
        """CSV 应包含项目信息头和匹配图像数量的文件结果行。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "report.csv")
            resp = _call_export(client, results, csv_path)
            assert resp.status_code == 200, f"导出应成功，实际: {resp.status_code} {resp.text}"

            rows = _parse_csv(csv_path)
            # 验证项目信息头
            assert rows[0][0] == "项目名称"
            assert rows[1][0] == "报告编号"

            # 验证文件结果区
            header_idx, data_rows = _find_file_results_section(rows)
            assert header_idx >= 0, "应包含'文件名, 检测结果, 文件路径'表头"
            assert len(data_rows) == len(results), (
                f"文件结果行数应等于图像数量 {len(results)}，实际: {len(data_rows)}"
            )

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(results=batch_results_st)
    def test_csv_status_column_is_ok_or_ng(
        self,
        client: TestClient,
        results: list[dict[str, Any]],
    ):
        """文件结果区的检测结果列应为 OK 或 NG。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "report.csv")
            resp = _call_export(client, results, csv_path)
            assert resp.status_code == 200

            rows = _parse_csv(csv_path)
            _, data_rows = _find_file_results_section(rows)
            for i, (row, result) in enumerate(zip(data_rows, results)):
                status = row[1]
                has_defects = len(result.get("detections", [])) > 0
                expected = "NG" if has_defects else "OK"
                assert status == expected, (
                    f"第 {i+1} 行检测结果应为 '{expected}'，实际: '{status}'"
                )


# ===========================================================================
# 属性 16: CSV编码正确性
# ===========================================================================

class TestProperty16CsvEncodingCorrectness:
    """
    Feature: el-defect-detection, Property 16: CSV编码正确性
    **Validates: Requirements 5.3**
    """

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(results=batch_results_st)
    def test_csv_file_has_utf8_bom(
        self,
        client: TestClient,
        results: list[dict[str, Any]],
    ):
        """CSV 文件开头应包含 UTF-8 BOM，且内容可用 UTF-8 正确解码。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "report.csv")
            resp = _call_export(client, results, csv_path)
            assert resp.status_code == 200

            raw_bytes = Path(csv_path).read_bytes()
            bom = b"\xef\xbb\xbf"
            assert raw_bytes[:3] == bom, (
                f"CSV 应以 UTF-8 BOM 开头，实际: {raw_bytes[:3]!r}"
            )

            content = raw_bytes.decode("utf-8")
            assert "项目名称" in content, "应包含 '项目名称'"
            assert "文件名" in content, "应包含 '文件名'"
            assert "检测结果" in content, "应包含 '检测结果'"


# ===========================================================================
# 属性 17: CSV缺陷统计格式
# ===========================================================================

# 专用策略：至少2个缺陷的图像结果
multi_defect_result_st = st.fixed_dictionaries({
    "image_path": st.from_regex(r"/images/img_[a-z0-9]{1,10}\.(jpg|png)", fullmatch=True),
    "detections": st.lists(detection_st, min_size=2, max_size=6),
})


class TestProperty17CsvDefectStatsFormat:
    """
    Feature: el-defect-detection, Property 17: CSV缺陷统计格式
    **Validates: Requirements 5.5**

    CSV 的缺陷统计区应包含每种缺陷类别的总数。
    """

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(result=multi_defect_result_st)
    def test_defect_stats_reflect_detection_counts(
        self,
        client: TestClient,
        result: dict[str, Any],
    ):
        """缺陷统计区应正确反映检测到的各类缺陷数量。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "report.csv")
            resp = _call_export(client, [result], csv_path)
            assert resp.status_code == 200

            rows = _parse_csv(csv_path)

            # 找到缺陷统计区（"缺陷类别, 数量" 行之后）
            stats_start = -1
            for i, row in enumerate(rows):
                if len(row) >= 2 and row[0] == "缺陷类别" and row[1] == "数量":
                    stats_start = i + 1
                    break
            assert stats_start > 0, "应包含'缺陷类别, 数量'表头"

            # 收集统计
            csv_stats: dict[str, int] = {}
            for row in rows[stats_start:]:
                if not row or not row[0]:
                    break
                csv_stats[row[0]] = int(row[1])

            # 验证与实际检测结果匹配
            expected_stats: dict[str, int] = {}
            for d in result["detections"]:
                cn = d["class_name"]
                expected_stats[cn] = expected_stats.get(cn, 0) + 1

            assert csv_stats == expected_stats, (
                f"缺陷统计不匹配: CSV={csv_stats}, 期望={expected_stats}"
            )


# ===========================================================================
# 属性 18: 输出目录自动创建
# ===========================================================================

class TestProperty18OutputDirectoryAutoCreation:
    """
    Feature: el-defect-detection, Property 18: 输出目录自动创建
    **Validates: Requirements 5.6**
    """

    @settings(max_examples=100, suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(
        results=batch_results_st,
        depth=st.integers(min_value=1, max_value=4),
    )
    def test_nested_output_directory_auto_created(
        self,
        client: TestClient,
        results: list[dict[str, Any]],
        depth: int,
    ):
        """不存在的嵌套目录路径应被自动创建。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            nested_dir = Path(tmp_dir)
            for i in range(depth):
                nested_dir = nested_dir / f"level_{i}"

            csv_path = str(nested_dir / "report.csv")
            assert not nested_dir.exists()

            resp = _call_export(client, results, csv_path)
            assert resp.status_code == 200, f"导出应成功，实际: {resp.status_code} {resp.text}"

            assert nested_dir.exists(), f"嵌套目录 {nested_dir} 应被自动创建"
            assert Path(csv_path).exists(), f"CSV 文件应存在于 {csv_path}"

            data = resp.json()
            assert "output_path" in data, "响应应包含 output_path 字段"


# ===========================================================================
# 单元测试: CSV导出
# ===========================================================================

class TestCsvExportUnit:
    """CSV导出单元测试。需求: 5.1, 5.2, 5.3, 5.6"""

    def test_csv_file_created_with_empty_results(self, client: TestClient):
        """导出空结果时应创建仅含项目信息和空文件结果区的 CSV。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "empty.csv")
            resp = _call_export(client, [], csv_path)
            assert resp.status_code == 200

            rows = _parse_csv(csv_path)
            assert rows[0][0] == "项目名称"
            _, data_rows = _find_file_results_section(rows)
            assert len(data_rows) == 0, "空结果应无文件数据行"

    def test_csv_structure_with_ok_image(self, client: TestClient):
        """无缺陷图像应标记为 OK。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "ok.csv")
            results = [{"image_path": "/images/good.jpg", "detections": []}]
            resp = _call_export(client, results, csv_path)
            assert resp.status_code == 200

            rows = _parse_csv(csv_path)
            _, data_rows = _find_file_results_section(rows)
            assert len(data_rows) == 1
            assert data_rows[0][0] == "good.jpg"
            assert data_rows[0][1] == "OK"

    def test_csv_structure_with_ng_image(self, client: TestClient):
        """有缺陷图像应标记为 NG。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "ng.csv")
            results = [{
                "image_path": "/images/bad.jpg",
                "detections": [
                    {"class_name": "隐裂", "score": 0.85, "class_id": 0,
                     "box": {"x1": 10, "y1": 20, "x2": 100, "y2": 200}},
                    {"class_name": "断栅", "score": 0.72, "class_id": 1,
                     "box": {"x1": 50, "y1": 60, "x2": 150, "y2": 250}},
                ],
            }]
            resp = _call_export(client, results, csv_path)
            assert resp.status_code == 200

            rows = _parse_csv(csv_path)
            _, data_rows = _find_file_results_section(rows)
            assert len(data_rows) == 1
            assert data_rows[0][0] == "bad.jpg"
            assert data_rows[0][1] == "NG"

    def test_csv_utf8_bom_encoding(self, client: TestClient):
        """CSV 文件应使用 UTF-8-BOM 编码。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "encoding.csv")
            resp = _call_export(client, [], csv_path)
            assert resp.status_code == 200

            raw = Path(csv_path).read_bytes()
            assert raw[:3] == b"\xef\xbb\xbf", (
                f"文件应以 UTF-8 BOM 开头，实际: {raw[:3]!r}"
            )

    def test_csv_directory_auto_creation(self, client: TestClient):
        """不存在的输出目录应被自动创建。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "a" / "b" / "c" / "report.csv")
            resp = _call_export(client, [], csv_path)
            assert resp.status_code == 200

            assert Path(csv_path).exists(), "CSV 文件应存在"
            assert (Path(tmp_dir) / "a" / "b" / "c").is_dir(), "嵌套目录应被创建"

    def test_csv_response_contains_output_path(self, client: TestClient):
        """响应应包含导出文件的完整路径。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "result.csv")
            resp = _call_export(client, [], csv_path)
            assert resp.status_code == 200

            data = resp.json()
            assert data["message"] == "CSV 报告导出成功"
            assert "output_path" in data
            assert Path(data["output_path"]).is_absolute()

    def test_csv_multiple_images_mixed(self, client: TestClient):
        """混合 OK 和 NG 图像的批量结果应正确导出。"""
        with tempfile.TemporaryDirectory() as tmp_dir:
            csv_path = str(Path(tmp_dir) / "mixed.csv")
            results = [
                {"image_path": "/img/a.jpg", "detections": []},
                {
                    "image_path": "/img/b.png",
                    "detections": [
                        {"class_name": "黑斑", "score": 0.91, "class_id": 2,
                         "box": {"x1": 0, "y1": 0, "x2": 50, "y2": 50}},
                    ],
                },
                {"image_path": "/img/c.bmp", "detections": []},
            ]

            resp = _call_export(client, results, csv_path)
            assert resp.status_code == 200

            rows = _parse_csv(csv_path)
            _, data_rows = _find_file_results_section(rows)
            assert len(data_rows) == 3
            assert data_rows[0][1] == "OK"
            assert data_rows[1][1] == "NG"
            assert data_rows[2][1] == "OK"
