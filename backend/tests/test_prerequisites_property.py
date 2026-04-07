"""
Feature: installer-packaging, Property 3: 构建前置工具验证

**Validates: Requirements 7.6**

属性定义:
对于任意必需工具集合的子集缺失情况，构建脚本的工具验证函数应返回失败，
且错误信息中包含所有缺失工具的名称。

测试策略:
- 创建 Python 模型模拟 build_installer.ps1 中 Test-Prerequisites 的逻辑
- 定义必需工具集合: {"PyInstaller", "Inno Setup", "Flutter SDK"}
- 使用 Hypothesis 生成必需工具集合的随机子集作为"已安装工具"
- 验证：缺失工具时验证函数返回失败
- 验证：错误信息包含所有缺失工具的名称
- 验证：所有工具都已安装时验证函数返回成功
"""
from __future__ import annotations

from dataclasses import dataclass, field

import pytest
from hypothesis import given, settings
import hypothesis.strategies as st


# ---------------------------------------------------------------------------
# 必需工具集合（与 build_installer.ps1 中 Test-Prerequisites 一致）
# ---------------------------------------------------------------------------

REQUIRED_TOOLS: frozenset[str] = frozenset({"PyInstaller", "Inno Setup", "Flutter SDK"})


# ---------------------------------------------------------------------------
# Python 模型：模拟 build_installer.ps1 的 Test-Prerequisites 逻辑
# ---------------------------------------------------------------------------

@dataclass
class PrerequisiteResult:
    """工具验证的结果。"""
    success: bool
    missing_tools: list[str] = field(default_factory=list)
    error_message: str | None = None


def check_prerequisites(installed_tools: set[str]) -> PrerequisiteResult:
    """模拟 PowerShell Test-Prerequisites 函数。

    检查所有必需工具是否在已安装工具集合中。
    缺失时收集所有缺失工具名称，生成包含所有缺失工具的错误信息。

    这精确模拟了 build_installer.ps1 中的逻辑：
        $missingTools = @()
        # ... 逐个检查 PyInstaller, Inno Setup, Flutter SDK ...
        if ($missingTools.Count -gt 0) {
            $toolList = $missingTools -join ", "
            Write-Host "错误: 以下必需工具未找到: $toolList"
            exit 1
        }

    Parameters
    ----------
    installed_tools : set[str]
        当前已安装的工具名称集合

    Returns
    -------
    PrerequisiteResult
        验证结果，包含成功标志、缺失工具列表和错误信息
    """
    missing_tools: list[str] = []

    for tool in REQUIRED_TOOLS:
        if tool not in installed_tools:
            missing_tools.append(tool)

    if missing_tools:
        tool_list = ", ".join(missing_tools)
        return PrerequisiteResult(
            success=False,
            missing_tools=missing_tools,
            error_message=f"错误: 以下必需工具未找到: {tool_list}",
        )

    return PrerequisiteResult(success=True)


# ---------------------------------------------------------------------------
# Hypothesis 策略
# ---------------------------------------------------------------------------

# 生成必需工具集合的随机子集作为"已安装工具"
_installed_tools_st = st.frozensets(
    st.sampled_from(sorted(REQUIRED_TOOLS)),
    min_size=0,
    max_size=len(REQUIRED_TOOLS),
)

# 生成严格的真子集（至少缺少一个工具）
_partial_installed_tools_st = st.frozensets(
    st.sampled_from(sorted(REQUIRED_TOOLS)),
    min_size=0,
    max_size=len(REQUIRED_TOOLS) - 1,
)


# ---------------------------------------------------------------------------
# 属性测试
# ---------------------------------------------------------------------------

@pytest.mark.usefixtures()
class TestProperty3PrerequisiteValidation:
    """
    Feature: installer-packaging, Property 3: 构建前置工具验证
    **Validates: Requirements 7.6**
    """

    @settings(max_examples=100)
    @given(installed_tools=_partial_installed_tools_st)
    def test_missing_tools_causes_failure(
        self,
        installed_tools: frozenset[str],
    ):
        """
        Feature: installer-packaging, Property 3: 构建前置工具验证
        **Validates: Requirements 7.6**

        缺失工具时验证函数返回失败。
        """
        result = check_prerequisites(set(installed_tools))

        expected_missing = REQUIRED_TOOLS - installed_tools

        # 验证：当有缺失工具时，验证返回失败
        assert result.success is False, (
            f"Expected failure when tools {expected_missing} are missing, "
            f"but got success. Installed: {installed_tools}"
        )

        # 验证：缺失工具列表不为空
        assert len(result.missing_tools) > 0, (
            f"Expected non-empty missing tools list. Installed: {installed_tools}"
        )

        # 验证：错误信息不为空
        assert result.error_message is not None, (
            f"Expected error message when tools are missing. Installed: {installed_tools}"
        )

    @settings(max_examples=100)
    @given(installed_tools=_partial_installed_tools_st)
    def test_error_message_contains_all_missing_tool_names(
        self,
        installed_tools: frozenset[str],
    ):
        """
        Feature: installer-packaging, Property 3: 构建前置工具验证
        **Validates: Requirements 7.6**

        错误信息包含所有缺失工具的名称。
        """
        result = check_prerequisites(set(installed_tools))

        expected_missing = REQUIRED_TOOLS - installed_tools

        # 验证：每个缺失工具的名称都出现在错误信息中
        for tool_name in expected_missing:
            assert tool_name in result.error_message, (
                f"Error message '{result.error_message}' should contain "
                f"missing tool name '{tool_name}'. "
                f"Installed: {installed_tools}, Missing: {expected_missing}"
            )

        # 验证：错误信息格式与 PowerShell 脚本一致
        assert result.error_message.startswith("错误: 以下必需工具未找到:"), (
            f"Error message '{result.error_message}' should start with "
            f"'错误: 以下必需工具未找到:'"
        )

    @settings(max_examples=100)
    @given(installed_tools=_installed_tools_st)
    def test_all_tools_installed_succeeds(
        self,
        installed_tools: frozenset[str],
    ):
        """
        Feature: installer-packaging, Property 3: 构建前置工具验证
        **Validates: Requirements 7.6**

        当所有工具都已安装时，验证函数返回成功。
        """
        result = check_prerequisites(set(installed_tools))

        if installed_tools == REQUIRED_TOOLS:
            # 所有工具都已安装 → 验证成功
            assert result.success is True, (
                f"Expected success when all tools are installed, "
                f"but got failure. Missing: {result.missing_tools}"
            )
            assert result.error_message is None, (
                f"Expected no error message when all tools installed, "
                f"got '{result.error_message}'"
            )
            assert len(result.missing_tools) == 0, (
                f"Expected empty missing tools list, "
                f"got {result.missing_tools}"
            )
        else:
            # 部分工具缺失 → 验证失败
            assert result.success is False, (
                f"Expected failure when not all tools installed. "
                f"Installed: {installed_tools}"
            )
