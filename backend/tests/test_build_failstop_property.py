"""
Feature: installer-packaging, Property 2: 构建脚本失败即停

**Validates: Requirements 7.5**

属性定义:
对于任意构建步骤序列，若第 K 步返回非零退出码，则构建脚本应立即停止执行，
不执行第 K+1 步及之后的步骤，且输出包含第 K 步名称的错误信息。

测试策略:
- 创建 Python 模型模拟 build_installer.ps1 中 Invoke-BuildStep 的失败即停逻辑
- 使用 Hypothesis 生成随机构建步骤序列和随机失败位置 K
- 验证：第 K 步失败后，第 K+1 步及之后的步骤不被执行
- 验证：错误信息包含第 K 步的步骤名称
"""
from __future__ import annotations

from dataclasses import dataclass, field

import pytest
from hypothesis import given, settings, assume
import hypothesis.strategies as st


# ---------------------------------------------------------------------------
# Python 模型：模拟 build_installer.ps1 的 Invoke-BuildStep 逻辑
# ---------------------------------------------------------------------------

@dataclass
class BuildStepResult:
    """单个构建步骤的执行结果。"""
    step_name: str
    exit_code: int


@dataclass
class BuildResult:
    """整个构建流程的执行结果。"""
    executed_steps: list[str] = field(default_factory=list)
    error_message: str | None = None
    success: bool = True


def invoke_build_step(
    step_name: str,
    exit_code: int,
    result: BuildResult,
) -> bool:
    """模拟 PowerShell Invoke-BuildStep 函数。

    执行一个构建步骤，检查退出码。非零则记录包含步骤名称的错误信息并返回 False
    表示应停止后续步骤。

    这精确模拟了 build_installer.ps1 中的逻辑：
        & $Action
        if ($LASTEXITCODE -ne 0) {
            Write-Host "错误: 步骤 [$StepName] 失败 (退出码: $LASTEXITCODE)"
            exit 1
        }

    Parameters
    ----------
    step_name : str
        步骤名称
    exit_code : int
        步骤执行后的退出码（0 = 成功，非零 = 失败）
    result : BuildResult
        累积的构建结果

    Returns
    -------
    bool
        True 表示继续执行下一步，False 表示应停止
    """
    result.executed_steps.append(step_name)

    if exit_code != 0:
        result.error_message = f"错误: 步骤 [{step_name}] 失败 (退出码: {exit_code})"
        result.success = False
        return False

    return True


def run_build_pipeline(steps: list[BuildStepResult]) -> BuildResult:
    """模拟 build_installer.ps1 的完整构建流程。

    按顺序执行每个步骤，任一步骤失败则立即停止。

    Parameters
    ----------
    steps : list[BuildStepResult]
        构建步骤列表，每个步骤包含名称和退出码

    Returns
    -------
    BuildResult
        构建结果，包含已执行步骤列表、错误信息和成功标志
    """
    result = BuildResult()

    for step in steps:
        should_continue = invoke_build_step(step.step_name, step.exit_code, result)
        if not should_continue:
            break

    return result


# ---------------------------------------------------------------------------
# Hypothesis 策略
# ---------------------------------------------------------------------------

# 生成步骤名称（模拟真实构建步骤名称格式）
_step_name_st = st.text(
    alphabet=st.characters(whitelist_categories=("L", "N"), whitelist_characters="-_ "),
    min_size=1,
    max_size=30,
)

# 生成非零退出码（模拟失败）
_nonzero_exit_code_st = st.integers(min_value=1, max_value=255)

# 生成步骤数量
_step_count_st = st.integers(min_value=2, max_value=20)


# ---------------------------------------------------------------------------
# 属性测试
# ---------------------------------------------------------------------------

@pytest.mark.usefixtures()
class TestProperty2BuildFailStop:
    """
    Feature: installer-packaging, Property 2: 构建脚本失败即停
    **Validates: Requirements 7.5**
    """

    @settings(max_examples=100)
    @given(
        step_names=st.lists(_step_name_st, min_size=2, max_size=20),
        fail_position=st.integers(min_value=0, max_value=19),
        fail_exit_code=_nonzero_exit_code_st,
    )
    def test_stops_after_failed_step(
        self,
        step_names: list[str],
        fail_position: int,
        fail_exit_code: int,
    ):
        """
        Feature: installer-packaging, Property 2: 构建脚本失败即停
        **Validates: Requirements 7.5**

        若第 K 步返回非零退出码，则第 K+1 步及之后的步骤不被执行。
        """
        # 确保 fail_position 在步骤范围内
        assume(fail_position < len(step_names))

        # 构建步骤序列：fail_position 之前全部成功，fail_position 处失败
        steps = []
        for i, name in enumerate(step_names):
            if i < fail_position:
                steps.append(BuildStepResult(step_name=name, exit_code=0))
            elif i == fail_position:
                steps.append(BuildStepResult(step_name=name, exit_code=fail_exit_code))
            else:
                steps.append(BuildStepResult(step_name=name, exit_code=0))

        result = run_build_pipeline(steps)

        # 验证：只有前 K+1 个步骤被执行（0..K）
        assert len(result.executed_steps) == fail_position + 1, (
            f"Expected {fail_position + 1} steps executed, "
            f"got {len(result.executed_steps)}. "
            f"Steps: {result.executed_steps}"
        )

        # 验证：第 K+1 步及之后的步骤未被执行
        executed_set = set(result.executed_steps)
        for i in range(fail_position + 1, len(step_names)):
            assert step_names[i] not in executed_set or step_names[i] in step_names[:fail_position + 1], (
                f"Step '{step_names[i]}' at position {i} should not have been "
                f"executed after failure at position {fail_position}"
            )

        # 验证：构建标记为失败
        assert result.success is False, "Build should be marked as failed"

    @settings(max_examples=100)
    @given(
        step_names=st.lists(_step_name_st, min_size=2, max_size=20),
        fail_position=st.integers(min_value=0, max_value=19),
        fail_exit_code=_nonzero_exit_code_st,
    )
    def test_error_message_contains_failed_step_name(
        self,
        step_names: list[str],
        fail_position: int,
        fail_exit_code: int,
    ):
        """
        Feature: installer-packaging, Property 2: 构建脚本失败即停
        **Validates: Requirements 7.5**

        错误信息包含第 K 步的步骤名称。
        """
        assume(fail_position < len(step_names))

        steps = []
        for i, name in enumerate(step_names):
            if i == fail_position:
                steps.append(BuildStepResult(step_name=name, exit_code=fail_exit_code))
            else:
                steps.append(BuildStepResult(step_name=name, exit_code=0))

        result = run_build_pipeline(steps)

        # 验证：错误信息不为空
        assert result.error_message is not None, (
            f"Expected error message when step at position {fail_position} fails"
        )

        # 验证：错误信息包含失败步骤的名称
        failed_step_name = step_names[fail_position]
        assert failed_step_name in result.error_message, (
            f"Error message '{result.error_message}' should contain "
            f"the failed step name '{failed_step_name}'"
        )

        # 验证：错误信息格式与 PowerShell 脚本一致
        expected_prefix = f"错误: 步骤 [{failed_step_name}] 失败"
        assert expected_prefix in result.error_message, (
            f"Error message '{result.error_message}' should match "
            f"PowerShell format: '{expected_prefix}'"
        )

    @settings(max_examples=100)
    @given(
        step_names=st.lists(_step_name_st, min_size=1, max_size=20),
    )
    def test_all_steps_succeed_when_no_failure(
        self,
        step_names: list[str],
    ):
        """
        Feature: installer-packaging, Property 2: 构建脚本失败即停
        **Validates: Requirements 7.5**

        若所有步骤退出码为 0，则所有步骤都被执行且构建成功。
        """
        steps = [
            BuildStepResult(step_name=name, exit_code=0)
            for name in step_names
        ]

        result = run_build_pipeline(steps)

        # 验证：所有步骤都被执行
        assert len(result.executed_steps) == len(step_names), (
            f"Expected all {len(step_names)} steps executed, "
            f"got {len(result.executed_steps)}"
        )

        # 验证：构建成功
        assert result.success is True, "Build should succeed when all steps pass"

        # 验证：无错误信息
        assert result.error_message is None, (
            f"Expected no error message, got '{result.error_message}'"
        )
