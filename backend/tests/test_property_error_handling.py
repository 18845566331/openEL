"""
Feature: el-defect-detection, Property 2: 无效输入错误处理
**Validates: Requirements 1.2, 2.2, 3.2, 5.8, 11.1**

属性定义:
对于任何无效输入（不存在的文件路径、无效的目录路径、无法读取的图像），
系统应该返回明确的错误信息而不是崩溃或返回空结果。

测试策略:
- 使用 Hypothesis 生成随机的无效文件路径和目录路径
- 对所有 API 端点发送包含无效路径的请求
- 验证所有端点返回 HTTP 400 状态码
- 验证所有错误响应包含 "detail" 字段的 JSON 格式
- 不使用 mock，通过 TestClient 测试真实的 API 行为
"""
from __future__ import annotations

import pytest
from hypothesis import given, settings, assume
import hypothesis.strategies as st
from fastapi.testclient import TestClient

from app.main import app


# ---------------------------------------------------------------------------
# Hypothesis 策略：生成随机的无效路径
# ---------------------------------------------------------------------------

# 生成随机的不存在文件路径（使用不太可能存在的前缀）
_path_segment_st = st.text(
    alphabet=st.characters(
        whitelist_categories=("L", "N"),
        whitelist_characters="_-",
    ),
    min_size=1,
    max_size=30,
)

# 生成不存在的文件路径：/nonexistent_<random>/<random>/<random>.<ext>
_invalid_file_path_st = st.builds(
    lambda prefix, mid, name, ext: f"/nonexistent_{prefix}/{mid}/{name}.{ext}",
    prefix=_path_segment_st,
    mid=_path_segment_st,
    name=_path_segment_st,
    ext=st.sampled_from(["onnx", "jpg", "png", "bmp", "json", "csv", "tif"]),
)

# 生成不存在的目录路径
_invalid_dir_path_st = st.builds(
    lambda prefix, mid, tail: f"/nonexistent_{prefix}/{mid}/{tail}",
    prefix=_path_segment_st,
    mid=_path_segment_st,
    tail=_path_segment_st,
)


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

def _assert_error_response(response) -> None:
    """验证错误响应的统一格式：HTTP 400 + JSON body 含 detail 字段。"""
    assert response.status_code == 400, (
        f"期望 HTTP 400，实际 {response.status_code}，body={response.text}"
    )
    data = response.json()
    assert isinstance(data, dict), f"响应不是 JSON 对象: {data}"
    assert "detail" in data, f"响应缺少 'detail' 字段: {data}"
    assert isinstance(data["detail"], str), f"'detail' 不是字符串: {data['detail']}"
    assert len(data["detail"]) > 0, "'detail' 字段为空字符串"


# ---------------------------------------------------------------------------
# 属性测试
# ---------------------------------------------------------------------------

class TestProperty2InvalidInputErrorHandling:
    """
    Feature: el-defect-detection, Property 2: 无效输入错误处理
    **Validates: Requirements 1.2, 2.2, 3.2, 5.8, 11.1**
    """

    @pytest.fixture(autouse=True)
    def _setup_client(self):
        self.client = TestClient(app, raise_server_exceptions=False)

    # --- 需求 1.2: 模型文件不存在或路径无效时返回明确的错误信息 ---

    @settings(max_examples=100)
    @given(invalid_path=_invalid_file_path_st)
    def test_model_load_invalid_path(self, invalid_path: str):
        """
        Feature: el-defect-detection, Property 2: 无效输入错误处理
        **Validates: Requirements 1.2, 11.1**

        对于任何不存在的模型文件路径，POST /api/model/load 应返回
        HTTP 400 和包含 detail 字段的 JSON 错误响应。
        """
        response = self.client.post(
            "/api/model/load",
            json={"model_path": invalid_path},
        )
        _assert_error_response(response)

    @settings(max_examples=100)
    @given(invalid_path=_invalid_file_path_st)
    def test_model_load_profile_invalid_path(self, invalid_path: str):
        """
        Feature: el-defect-detection, Property 2: 无效输入错误处理
        **Validates: Requirements 1.2, 11.1**

        对于任何不存在的配置文件路径，POST /api/model/load_profile 应返回
        HTTP 400 和包含 detail 字段的 JSON 错误响应。
        """
        response = self.client.post(
            "/api/model/load_profile",
            params={"profile_path": invalid_path},
        )
        _assert_error_response(response)

    # --- 需求 2.2: 图像文件不存在或无法读取时返回明确的错误信息 ---

    @settings(max_examples=100)
    @given(invalid_path=_invalid_file_path_st)
    def test_detect_single_invalid_image_path(self, invalid_path: str):
        """
        Feature: el-defect-detection, Property 2: 无效输入错误处理
        **Validates: Requirements 2.2, 11.1**

        对于任何不存在的图像文件路径，POST /api/detect 应返回
        HTTP 400 和包含 detail 字段的 JSON 错误响应。
        """
        response = self.client.post(
            "/api/detect",
            json={"image_path": invalid_path},
        )
        _assert_error_response(response)

    # --- 需求 3.2: 输入目录不存在时返回明确的错误信息 ---

    @settings(max_examples=100)
    @given(invalid_dir=_invalid_dir_path_st)
    def test_batch_detect_invalid_directory(self, invalid_dir: str):
        """
        Feature: el-defect-detection, Property 2: 无效输入错误处理
        **Validates: Requirements 3.2, 11.1**

        对于任何不存在的目录路径，POST /api/detect/batch 应返回
        HTTP 400 和包含 detail 字段的 JSON 错误响应。
        """
        response = self.client.post(
            "/api/detect/batch",
            json={"input_dir": invalid_dir},
        )
        _assert_error_response(response)

    # --- 需求 5.8: 导出过程中发生错误时返回明确的错误信息 ---

    @settings(max_examples=100)
    @given(invalid_path=_invalid_file_path_st)
    def test_csv_export_invalid_output_path(self, invalid_path: str):
        """
        Feature: el-defect-detection, Property 2: 无效输入错误处理
        **Validates: Requirements 5.8, 11.1**

        对于任何无效的输出路径，POST /api/report/export_csv 应返回
        HTTP 400 错误或 HTTP 200 成功（自动创建目录），但绝不应崩溃。
        当返回错误时，响应应包含 detail 字段。
        """
        # CSV 导出端点: batch_result 是 JSON body, output_csv 是 query param
        response = self.client.post(
            "/api/report/export_csv",
            params={"output_csv": invalid_path},
            json={"results": []},
        )
        # CSV 导出对于合法路径会自动创建目录并成功
        # 对于非法路径会返回 400 错误
        # 两种情况都不应崩溃
        if response.status_code == 400:
            data = response.json()
            assert "detail" in data
            assert isinstance(data["detail"], str)
            assert len(data["detail"]) > 0
        else:
            # 如果路径合法，应返回 200 成功
            assert response.status_code == 200

    # --- 综合测试：所有端点对特殊无效路径的处理 ---

    def test_all_endpoints_handle_special_invalid_paths(self):
        """
        Feature: el-defect-detection, Property 2: 无效输入错误处理
        **Validates: Requirements 1.2, 2.2, 3.2, 11.1**

        所有接受路径参数的端点对明确不存在的路径应返回错误而不崩溃。
        """
        nonexistent = "/absolutely_nonexistent_path_12345/file.onnx"

        # 模型加载 - 不存在的路径
        resp = self.client.post(
            "/api/model/load",
            json={"model_path": nonexistent},
        )
        assert resp.status_code == 400
        assert "detail" in resp.json()

        # 单张检测 - 不存在的路径
        resp = self.client.post(
            "/api/detect",
            json={"image_path": nonexistent},
        )
        assert resp.status_code == 400
        assert "detail" in resp.json()

        # 批量检测 - 不存在的路径
        resp = self.client.post(
            "/api/detect/batch",
            json={"input_dir": "/absolutely_nonexistent_path_12345/dir"},
        )
        assert resp.status_code == 400
        assert "detail" in resp.json()

        # 配置文件加载 - 不存在的路径
        resp = self.client.post(
            "/api/model/load_profile",
            params={"profile_path": nonexistent},
        )
        assert resp.status_code == 400
        assert "detail" in resp.json()
