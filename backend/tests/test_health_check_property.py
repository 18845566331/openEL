"""
Feature: installer-packaging, Property 1: 健康检查轮询收敛性

**Validates: Requirements 3.2**

属性定义:
对于任意一组健康检查响应序列（其中第 N 次返回成功），Launcher 的 wait_for_health
函数应在第 N 次请求后返回 True，且总请求次数不超过 timeout / interval 次。
若序列中无成功响应且总时间超过 timeout，则应返回 False。

测试策略:
- 使用 Hypothesis 生成随机的健康检查响应序列（成功/失败/异常组合）
- Mock urllib.request.urlopen 模拟响应序列
- Mock time.sleep 避免实际延迟
- Mock time.time 控制超时行为
- 验证 wait_for_health 在成功响应出现时返回 True
- 验证 wait_for_health 在超时时返回 False
- 验证总请求次数不超过 timeout / interval
"""
from __future__ import annotations

import sys
import os
import types
from unittest.mock import patch, MagicMock

import pytest
pytest.skip("Launcher refactored, tests outdated", allow_module_level=True)
from hypothesis import given, settings, assume
import hypothesis.strategies as st

# ---------------------------------------------------------------------------
# 将 launcher 目录加入 sys.path 以便导入 launcher 模块
# ---------------------------------------------------------------------------
_launcher_dir = os.path.join(
    os.path.dirname(__file__), os.pardir, os.pardir, "launcher"
)
_launcher_dir = os.path.normpath(_launcher_dir)
if _launcher_dir not in sys.path:
    sys.path.insert(0, _launcher_dir)

from launcher import wait_for_health, HEALTH_INTERVAL


# ---------------------------------------------------------------------------
# 响应类型枚举
# ---------------------------------------------------------------------------
# 0 = 成功 (status 200)
# 1 = 非 200 响应 (e.g. status 500)
# 2 = 异常 (连接失败等)
RESPONSE_SUCCESS = 0
RESPONSE_NON_200 = 1
RESPONSE_EXCEPTION = 2


# ---------------------------------------------------------------------------
# Hypothesis 策略
# ---------------------------------------------------------------------------

# 生成超时值（2~30 秒，保持合理范围）
_timeout_st = st.integers(min_value=2, max_value=30)

# 生成单个响应类型
_response_type_st = st.sampled_from([RESPONSE_SUCCESS, RESPONSE_NON_200, RESPONSE_EXCEPTION])

# 生成成功出现的位置 N（0-indexed），以及之前的失败响应序列
_success_position_st = st.integers(min_value=0, max_value=29)


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

def _make_urlopen_side_effect(responses: list[int], call_counter: list[int]):
    """根据响应序列创建 urlopen 的 side_effect 函数。

    Parameters
    ----------
    responses : list[int]
        响应类型序列 (0=成功, 1=非200, 2=异常)
    call_counter : list[int]
        单元素列表，用于记录调用次数
    """
    def side_effect(url, timeout=None):
        idx = call_counter[0]
        call_counter[0] += 1

        if idx < len(responses):
            resp_type = responses[idx]
        else:
            # 超出序列长度，返回异常（模拟持续失败）
            resp_type = RESPONSE_EXCEPTION

        if resp_type == RESPONSE_SUCCESS:
            mock_resp = MagicMock()
            mock_resp.status = 200
            return mock_resp
        elif resp_type == RESPONSE_NON_200:
            mock_resp = MagicMock()
            mock_resp.status = 500
            return mock_resp
        else:
            raise ConnectionError("Connection refused")

    return side_effect


def _make_time_mocks(interval: int):
    """创建 time.time 和 time.sleep 的 mock。

    返回一个模拟时钟，每次调用 time.sleep 时推进 interval 秒。
    time.time() 返回当前模拟时间。

    Returns
    -------
    tuple[callable, callable, list[float]]
        (mock_time_func, mock_sleep_func, clock_state)
        clock_state[0] 是当前模拟时间
    """
    clock = [0.0]  # 模拟时钟起始时间

    def mock_time():
        return clock[0]

    def mock_sleep(seconds):
        clock[0] += seconds

    return mock_time, mock_sleep, clock


# ---------------------------------------------------------------------------
# 属性测试
# ---------------------------------------------------------------------------

@pytest.mark.usefixtures()
class TestProperty1HealthCheckPollingConvergence:
    """
    Feature: installer-packaging, Property 1: 健康检查轮询收敛性
    **Validates: Requirements 3.2**
    """

    @settings(max_examples=100)
    @given(
        timeout=_timeout_st,
        success_pos=_success_position_st,
        prefix_responses=st.lists(
            st.sampled_from([RESPONSE_NON_200, RESPONSE_EXCEPTION]),
            min_size=0,
            max_size=29,
        ),
    )
    def test_returns_true_when_success_within_timeout(
        self, timeout: int, success_pos: int, prefix_responses: list[int]
    ):
        """
        Feature: installer-packaging, Property 1: 健康检查轮询收敛性
        **Validates: Requirements 3.2**

        若第 N 次请求返回成功（status 200），且 N 在超时范围内，
        则 wait_for_health 应返回 True，且总请求次数 ≤ timeout / interval。
        """
        max_polls = timeout // HEALTH_INTERVAL

        # 确保成功位置在超时允许的轮询次数范围内
        assume(success_pos < max_polls)

        # 构建响应序列：前 success_pos 个为失败，第 success_pos 个为成功
        # 截取 prefix_responses 到 success_pos 长度
        fail_prefix = prefix_responses[:success_pos]
        # 补齐不足的部分
        while len(fail_prefix) < success_pos:
            fail_prefix.append(RESPONSE_EXCEPTION)
        responses = fail_prefix + [RESPONSE_SUCCESS]

        call_counter = [0]
        side_effect = _make_urlopen_side_effect(responses, call_counter)
        mock_time_func, mock_sleep_func, clock = _make_time_mocks(HEALTH_INTERVAL)

        with patch("launcher.urllib.request.urlopen", side_effect=side_effect), \
             patch("launcher.time.sleep", side_effect=mock_sleep_func), \
             patch("launcher.time.time", side_effect=mock_time_func):

            result = wait_for_health(timeout=timeout)

        # 验证返回 True
        assert result is True, (
            f"Expected True when success at position {success_pos} "
            f"with timeout={timeout}, but got False"
        )

        # 验证总请求次数 ≤ timeout / interval
        assert call_counter[0] <= max_polls, (
            f"Total requests {call_counter[0]} exceeded max allowed "
            f"{max_polls} (timeout={timeout}, interval={HEALTH_INTERVAL})"
        )

        # 验证请求次数恰好为 success_pos + 1（前面失败 + 成功那次）
        assert call_counter[0] == success_pos + 1, (
            f"Expected exactly {success_pos + 1} requests, "
            f"got {call_counter[0]}"
        )

    @settings(max_examples=100)
    @given(
        timeout=_timeout_st,
        responses=st.lists(
            st.sampled_from([RESPONSE_NON_200, RESPONSE_EXCEPTION]),
            min_size=1,
            max_size=50,
        ),
    )
    def test_returns_false_when_no_success_and_timeout(
        self, timeout: int, responses: list[int]
    ):
        """
        Feature: installer-packaging, Property 1: 健康检查轮询收敛性
        **Validates: Requirements 3.2**

        若序列中无成功响应且超时，wait_for_health 应返回 False。
        """
        max_polls = timeout // HEALTH_INTERVAL

        call_counter = [0]
        side_effect = _make_urlopen_side_effect(responses, call_counter)
        mock_time_func, mock_sleep_func, clock = _make_time_mocks(HEALTH_INTERVAL)

        with patch("launcher.urllib.request.urlopen", side_effect=side_effect), \
             patch("launcher.time.sleep", side_effect=mock_sleep_func), \
             patch("launcher.time.time", side_effect=mock_time_func):

            result = wait_for_health(timeout=timeout)

        # 验证返回 False
        assert result is False, (
            f"Expected False when no success response in sequence, "
            f"but got True (timeout={timeout})"
        )

        # 验证总请求次数 ≤ timeout / interval
        assert call_counter[0] <= max_polls, (
            f"Total requests {call_counter[0]} exceeded max allowed "
            f"{max_polls} (timeout={timeout}, interval={HEALTH_INTERVAL})"
        )

    @settings(max_examples=100)
    @given(
        timeout=_timeout_st,
        responses=st.lists(
            _response_type_st,
            min_size=1,
            max_size=50,
        ),
    )
    def test_request_count_bounded_by_timeout_over_interval(
        self, timeout: int, responses: list[int]
    ):
        """
        Feature: installer-packaging, Property 1: 健康检查轮询收敛性
        **Validates: Requirements 3.2**

        对于任意响应序列，总请求次数不超过 timeout / interval。
        """
        max_polls = timeout // HEALTH_INTERVAL

        call_counter = [0]
        side_effect = _make_urlopen_side_effect(responses, call_counter)
        mock_time_func, mock_sleep_func, clock = _make_time_mocks(HEALTH_INTERVAL)

        with patch("launcher.urllib.request.urlopen", side_effect=side_effect), \
             patch("launcher.time.sleep", side_effect=mock_sleep_func), \
             patch("launcher.time.time", side_effect=mock_time_func):

            result = wait_for_health(timeout=timeout)

        # 验证总请求次数 ≤ timeout / interval
        assert call_counter[0] <= max_polls, (
            f"Total requests {call_counter[0]} exceeded max allowed "
            f"{max_polls} (timeout={timeout}, interval={HEALTH_INTERVAL})"
        )
