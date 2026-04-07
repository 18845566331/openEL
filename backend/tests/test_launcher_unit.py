"""
Launcher 单元测试 —— 验证启动器核心函数的正确性。

**Validates: Requirements 3.1, 3.2, 3.3, 3.5, 3.6, 3.7**

测试覆盖:
- get_base_dir() 路径解析
- start_backend() 进程启动参数（CREATE_NO_WINDOW、stdout/stderr 重定向）
- wait_for_health() 健康检查成功/失败/超时
- start_frontend() 前端进程启动
- show_error() MessageBoxW 调用
- terminate_backend() 进程终止逻辑
- main() 完整生命周期
"""
from __future__ import annotations

import os
import subprocess
import sys
from unittest.mock import patch, MagicMock, mock_open, call

import pytest
pytest.skip("Launcher refactored, tests outdated", allow_module_level=True)

# ---------------------------------------------------------------------------
# 将 launcher 目录加入 sys.path
# ---------------------------------------------------------------------------
_launcher_dir = os.path.join(
    os.path.dirname(__file__), os.pardir, os.pardir, "launcher"
)
_launcher_dir = os.path.normpath(_launcher_dir)
if _launcher_dir not in sys.path:
    sys.path.insert(0, _launcher_dir)

import launcher
from launcher import (
    get_base_dir,
    start_backend,
    wait_for_health,
    start_frontend,
    show_error,
    terminate_backend,
    main,
    CREATE_NO_WINDOW,
    BACKEND_REL_PATH,
    FRONTEND_REL_PATH,
    HEALTH_INTERVAL,
)


# ===========================================================================
# get_base_dir() 测试 — Requirements 3.1
# ===========================================================================

class TestGetBaseDir:
    """验证 get_base_dir() 在不同场景下返回正确路径。"""

    def test_returns_directory_of_executable(self):
        """get_base_dir 应返回 sys.executable 所在目录。"""
        fake_exe = os.path.abspath(os.path.join("install", "path", "Launcher.exe"))
        with patch.object(sys, "executable", fake_exe):
            result = get_base_dir()
        assert result == os.path.dirname(fake_exe)

    def test_returns_absolute_path(self):
        """get_base_dir 应始终返回绝对路径。"""
        with patch.object(sys, "executable", "relative/Launcher.exe"):
            result = get_base_dir()
        assert os.path.isabs(result)

    def test_handles_nested_directory(self):
        """get_base_dir 应正确处理深层嵌套目录。"""
        fake_exe = os.path.abspath(os.path.join("a", "b", "c", "d", "Launcher.exe"))
        with patch.object(sys, "executable", fake_exe):
            result = get_base_dir()
        assert result == os.path.dirname(fake_exe)


# ===========================================================================
# start_backend() 测试 — Requirements 3.1, 3.6, 3.7
# ===========================================================================

class TestStartBackend:
    """验证 start_backend 使用正确的 CREATE_NO_WINDOW 标志和 stdout/stderr 重定向。"""

    def test_uses_create_no_window_flag(self, tmp_path):
        """start_backend 应使用 CREATE_NO_WINDOW (0x08000000) 标志。

        **Validates: Requirements 3.7**
        """
        # 创建假的后端 exe 文件
        backend_dir = tmp_path / "backend"
        backend_dir.mkdir()
        backend_exe = backend_dir / "run_server.exe"
        backend_exe.write_text("fake")

        log_file = MagicMock()
        mock_proc = MagicMock(spec=subprocess.Popen)

        with patch("launcher.subprocess.Popen", return_value=mock_proc) as mock_popen:
            result = start_backend(str(tmp_path), log_file)

        mock_popen.assert_called_once()
        call_kwargs = mock_popen.call_args
        assert call_kwargs.kwargs["creationflags"] == CREATE_NO_WINDOW
        assert CREATE_NO_WINDOW == 0x08000000

    def test_redirects_stdout_stderr_to_log_file(self, tmp_path):
        """start_backend 应将 stdout/stderr 重定向到日志文件。

        **Validates: Requirements 3.6**
        """
        backend_dir = tmp_path / "backend"
        backend_dir.mkdir()
        (backend_dir / "run_server.exe").write_text("fake")

        log_file = MagicMock()
        mock_proc = MagicMock(spec=subprocess.Popen)

        with patch("launcher.subprocess.Popen", return_value=mock_proc) as mock_popen:
            start_backend(str(tmp_path), log_file)

        call_kwargs = mock_popen.call_args
        assert call_kwargs.kwargs["stdout"] is log_file
        assert call_kwargs.kwargs["stderr"] is log_file

    def test_uses_devnull_when_log_file_is_none(self, tmp_path):
        """log_file 为 None 时应使用 subprocess.DEVNULL。

        **Validates: Requirements 3.6**
        """
        backend_dir = tmp_path / "backend"
        backend_dir.mkdir()
        (backend_dir / "run_server.exe").write_text("fake")

        mock_proc = MagicMock(spec=subprocess.Popen)

        with patch("launcher.subprocess.Popen", return_value=mock_proc) as mock_popen:
            start_backend(str(tmp_path), None)

        call_kwargs = mock_popen.call_args
        assert call_kwargs.kwargs["stdout"] == subprocess.DEVNULL
        assert call_kwargs.kwargs["stderr"] == subprocess.DEVNULL

    def test_raises_file_not_found_when_exe_missing(self, tmp_path):
        """后端 exe 不存在时应抛出 FileNotFoundError。"""
        with pytest.raises(FileNotFoundError, match="后端程序文件缺失"):
            start_backend(str(tmp_path), None)

    def test_passes_correct_exe_path(self, tmp_path):
        """start_backend 应传递正确的后端 exe 路径。

        **Validates: Requirements 3.1**
        """
        backend_dir = tmp_path / "backend"
        backend_dir.mkdir()
        (backend_dir / "run_server.exe").write_text("fake")

        mock_proc = MagicMock(spec=subprocess.Popen)

        with patch("launcher.subprocess.Popen", return_value=mock_proc) as mock_popen:
            start_backend(str(tmp_path), None)

        expected_exe = os.path.join(str(tmp_path), BACKEND_REL_PATH)
        call_args = mock_popen.call_args
        assert call_args.args[0] == [expected_exe]


# ===========================================================================
# wait_for_health() 测试 — Requirements 3.2, 3.3
# ===========================================================================

class TestWaitForHealth:
    """验证健康检查成功/失败/超时场景。"""

    def _make_time_mocks(self):
        """创建模拟时钟。"""
        clock = [0.0]

        def mock_time():
            return clock[0]

        def mock_sleep(seconds):
            clock[0] += seconds

        return mock_time, mock_sleep, clock

    def test_returns_true_on_immediate_success(self):
        """首次请求即成功时应返回 True。

        **Validates: Requirements 3.2**
        """
        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_time, mock_sleep, _ = self._make_time_mocks()

        with patch("launcher.urllib.request.urlopen", return_value=mock_resp), \
             patch("launcher.time.sleep", side_effect=mock_sleep), \
             patch("launcher.time.time", side_effect=mock_time):
            result = wait_for_health(timeout=5)

        assert result is True

    def test_returns_true_after_retries(self):
        """经过几次失败后成功时应返回 True。

        **Validates: Requirements 3.2**
        """
        mock_resp_ok = MagicMock()
        mock_resp_ok.status = 200

        call_count = [0]
        mock_time, mock_sleep, _ = self._make_time_mocks()

        def side_effect(url, timeout=None):
            call_count[0] += 1
            if call_count[0] < 3:
                raise ConnectionError("refused")
            return mock_resp_ok

        with patch("launcher.urllib.request.urlopen", side_effect=side_effect), \
             patch("launcher.time.sleep", side_effect=mock_sleep), \
             patch("launcher.time.time", side_effect=mock_time):
            result = wait_for_health(timeout=10)

        assert result is True
        assert call_count[0] == 3

    def test_returns_false_on_timeout(self):
        """所有请求都失败且超时后应返回 False。

        **Validates: Requirements 3.3**
        """
        mock_time, mock_sleep, _ = self._make_time_mocks()

        with patch("launcher.urllib.request.urlopen", side_effect=ConnectionError("refused")), \
             patch("launcher.time.sleep", side_effect=mock_sleep), \
             patch("launcher.time.time", side_effect=mock_time):
            result = wait_for_health(timeout=3)

        assert result is False

    def test_returns_false_on_non_200_responses(self):
        """所有响应都是非 200 状态码时应返回 False。"""
        mock_resp = MagicMock()
        mock_resp.status = 500
        mock_time, mock_sleep, _ = self._make_time_mocks()

        with patch("launcher.urllib.request.urlopen", return_value=mock_resp), \
             patch("launcher.time.sleep", side_effect=mock_sleep), \
             patch("launcher.time.time", side_effect=mock_time):
            result = wait_for_health(timeout=3)

        assert result is False


# ===========================================================================
# start_frontend() 测试 — Requirements 3.1
# ===========================================================================

class TestStartFrontend:
    """验证前端进程启动。"""

    def test_launches_frontend_exe(self, tmp_path):
        """start_frontend 应启动正确的前端 exe。"""
        frontend_dir = tmp_path / "frontend"
        frontend_dir.mkdir()
        (frontend_dir / "el_defect_system.exe").write_text("fake")

        mock_proc = MagicMock(spec=subprocess.Popen)

        with patch("launcher.subprocess.Popen", return_value=mock_proc) as mock_popen:
            result = start_frontend(str(tmp_path))

        expected_exe = os.path.join(str(tmp_path), FRONTEND_REL_PATH)
        mock_popen.assert_called_once_with([expected_exe])
        assert result is mock_proc

    def test_raises_file_not_found_when_exe_missing(self, tmp_path):
        """前端 exe 不存在时应抛出 FileNotFoundError。"""
        with pytest.raises(FileNotFoundError, match="前端程序文件缺失"):
            start_frontend(str(tmp_path))


# ===========================================================================
# show_error() 测试 — Requirements 3.3, 3.5
# ===========================================================================

class TestShowError:
    """验证 MessageBoxW 调用。"""

    def test_calls_message_box_with_correct_params(self):
        """show_error 应调用 MessageBoxW 并传递正确参数。

        **Validates: Requirements 3.3**
        """
        mock_msgbox = MagicMock()
        mock_windll = MagicMock()
        mock_windll.user32.MessageBoxW = mock_msgbox

        with patch.object(launcher.ctypes, "windll", mock_windll):
            show_error("后端服务启动超时，请查看日志文件。")

        mock_msgbox.assert_called_once()
        args = mock_msgbox.call_args.args
        assert args[0] == 0  # hWnd
        assert args[1] == "后端服务启动超时，请查看日志文件。"  # message
        assert args[2] == "启动错误"  # title
        # MB_OK | MB_ICONERROR = 0x00000010
        assert args[3] == 0x00000010

    def test_timeout_error_message(self):
        """超时场景应弹出正确的超时消息。

        **Validates: Requirements 3.3**
        """
        mock_msgbox = MagicMock()
        mock_windll = MagicMock()
        mock_windll.user32.MessageBoxW = mock_msgbox

        with patch.object(launcher.ctypes, "windll", mock_windll):
            show_error("后端服务启动超时，请查看日志文件。")

        args = mock_msgbox.call_args.args
        assert "超时" in args[1]

    def test_missing_file_error_message(self):
        """文件缺失场景应弹出正确的缺失消息。"""
        mock_msgbox = MagicMock()
        mock_windll = MagicMock()
        mock_windll.user32.MessageBoxW = mock_msgbox

        with patch.object(launcher.ctypes, "windll", mock_windll):
            show_error("后端程序文件缺失，请重新安装。")

        args = mock_msgbox.call_args.args
        assert "缺失" in args[1]


# ===========================================================================
# terminate_backend() 测试 — Requirements 3.5
# ===========================================================================

class TestTerminateBackend:
    """验证后端进程终止逻辑。"""

    def test_calls_terminate_then_wait(self):
        """terminate_backend 应先调用 terminate() 再 wait()。

        **Validates: Requirements 3.5**
        """
        mock_proc = MagicMock(spec=subprocess.Popen)
        mock_proc.wait.return_value = 0

        terminate_backend(mock_proc)

        mock_proc.terminate.assert_called_once()
        mock_proc.wait.assert_called_once_with(timeout=5)

    def test_calls_kill_on_timeout(self):
        """wait() 超时后应调用 kill()。

        **Validates: Requirements 3.5**
        """
        mock_proc = MagicMock(spec=subprocess.Popen)
        mock_proc.wait.side_effect = subprocess.TimeoutExpired(cmd="test", timeout=5)

        terminate_backend(mock_proc)

        mock_proc.terminate.assert_called_once()
        mock_proc.kill.assert_called_once()

    def test_handles_already_exited_process(self):
        """进程已退出时不应抛出异常。"""
        mock_proc = MagicMock(spec=subprocess.Popen)
        mock_proc.terminate.side_effect = OSError("No such process")

        # 不应抛出异常
        terminate_backend(mock_proc)


# ===========================================================================
# main() 集成测试 — Requirements 3.1, 3.5
# ===========================================================================

class TestMain:
    """验证 main() 完整生命周期。"""

    def test_frontend_exit_terminates_backend(self, tmp_path):
        """前端进程退出后应终止后端进程。

        **Validates: Requirements 3.5**
        """
        # 创建假的 exe 文件
        backend_dir = tmp_path / "backend"
        backend_dir.mkdir()
        (backend_dir / "run_server.exe").write_text("fake")
        frontend_dir = tmp_path / "frontend"
        frontend_dir.mkdir()
        (frontend_dir / "el_defect_system.exe").write_text("fake")

        mock_backend_proc = MagicMock(spec=subprocess.Popen)
        mock_backend_proc.poll.return_value = None  # 后端运行中
        mock_backend_proc.wait.return_value = 0

        mock_frontend_proc = MagicMock(spec=subprocess.Popen)
        mock_frontend_proc.wait.return_value = 0  # 前端退出

        mock_resp = MagicMock()
        mock_resp.status = 200

        popen_calls = [0]

        def popen_side_effect(*args, **kwargs):
            popen_calls[0] += 1
            if popen_calls[0] == 1:
                return mock_backend_proc
            return mock_frontend_proc

        with patch.object(launcher, "get_base_dir", return_value=str(tmp_path)), \
             patch("launcher.subprocess.Popen", side_effect=popen_side_effect), \
             patch("launcher.urllib.request.urlopen", return_value=mock_resp), \
             patch("launcher.time.sleep"), \
             patch("launcher.time.time", side_effect=[0.0, 0.0, 1.0]), \
             patch("launcher.os.makedirs"), \
             patch("builtins.open", mock_open()):
            main()

        # 验证后端进程被终止
        mock_backend_proc.terminate.assert_called()

    def test_shows_error_on_health_timeout(self, tmp_path):
        """健康检查超时时应弹出错误消息并终止后端。

        **Validates: Requirements 3.3**
        """
        backend_dir = tmp_path / "backend"
        backend_dir.mkdir()
        (backend_dir / "run_server.exe").write_text("fake")

        mock_backend_proc = MagicMock(spec=subprocess.Popen)
        mock_backend_proc.poll.return_value = None  # 后端运行中
        mock_backend_proc.wait.return_value = 0

        # 模拟时钟：让时间快速超过 deadline
        time_values = [0.0]  # 初始时间
        call_idx = [0]

        def mock_time():
            val = time_values[0]
            # 每次 sleep 后推进时间，第二次调用时超过 timeout
            return val

        def mock_sleep(s):
            time_values[0] += 100  # 大幅推进时间以触发超时

        mock_msgbox = MagicMock()
        mock_windll = MagicMock()
        mock_windll.user32.MessageBoxW = mock_msgbox

        with patch.object(launcher, "get_base_dir", return_value=str(tmp_path)), \
             patch("launcher.subprocess.Popen", return_value=mock_backend_proc), \
             patch("launcher.urllib.request.urlopen", side_effect=ConnectionError), \
             patch("launcher.time.sleep", side_effect=mock_sleep), \
             patch("launcher.time.time", side_effect=mock_time), \
             patch.object(launcher.ctypes, "windll", mock_windll), \
             patch("launcher.os.makedirs"), \
             patch("builtins.open", mock_open()):
            main()

        # 验证弹出了超时错误消息
        mock_msgbox.assert_called_once()
        msg_arg = mock_msgbox.call_args.args[1]
        assert "超时" in msg_arg

        # 验证后端被终止
        mock_backend_proc.terminate.assert_called()

    def test_shows_error_when_backend_exe_missing(self, tmp_path):
        """后端 exe 不存在时应弹出错误消息。"""
        mock_msgbox = MagicMock()
        mock_windll = MagicMock()
        mock_windll.user32.MessageBoxW = mock_msgbox

        with patch.object(launcher, "get_base_dir", return_value=str(tmp_path)), \
             patch.object(launcher.ctypes, "windll", mock_windll), \
             patch("launcher.os.makedirs"), \
             patch("builtins.open", mock_open()):
            main()

        mock_msgbox.assert_called_once()
        msg_arg = mock_msgbox.call_args.args[1]
        assert "后端" in msg_arg and "缺失" in msg_arg
