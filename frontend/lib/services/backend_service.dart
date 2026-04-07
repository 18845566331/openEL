import 'dart:io';
import 'dart:async';

/// 管理本地 Python 后端进程的自动启动和关闭
class BackendService {
  static BackendService? _instance;
  static BackendService get instance => _instance ??= BackendService._();
  BackendService._();

  Process? _process;
  bool _started = false;

  /// 后端是否已启动
  bool get isStarted => _started;

  /// 启动本地后端服务（如果尚未运行）
  Future<bool> ensureRunning() async {
    // 先检查后端是否已经在运行
    if (await _isBackendAlive()) {
      _started = true;
      return true;
    }

    // 查找 Python 后端脚本路径
    final backendScript = _findBackendScript();
    if (backendScript == null) {
      return false;
    }

    try {
      final isExe = backendScript.toLowerCase().endsWith('.exe');
      
      if (isExe) {
        // 直接启动可执行文件
        _process = await Process.start(
          backendScript,
          ['--host', '127.0.0.1', '--port', '5000'],
          workingDirectory: File(backendScript).parent.path,
          mode: ProcessStartMode.detached,
        );
      } else {
        // 使用 Python 解释器启动脚本
        final pythonExe = _findPythonExecutable();
        _process = await Process.start(
          pythonExe,
          [backendScript, '--host', '127.0.0.1', '--port', '5000'],
          workingDirectory: File(backendScript).parent.path,
          mode: ProcessStartMode.detached,
        );
      }
      
      // 等待后端启动（最多等 15 秒）
      for (var i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await _isBackendAlive()) {
          _started = true;
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 检查后端是否存活
  Future<bool> _isBackendAlive() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 2);
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:5000/health'));
      final response = await request.close();
      client.close();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 查找后端脚本或目录路径
  String? _findBackendScript() {
    // 获取当前可执行文件所在目录
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;

    // 可能的后端路径（相对于 exe 所在目录）
    final candidates = [
      '$exeDir\\backend\\run_server.py',
      '$exeDir\\backend\\run_server.exe',
      '$exeDir\\..\\backend\\run_server.exe', // 打包环境下的后端位置
      '$exeDir\\..\\..\\..\\..\\backend\\run_server.py',
      // 开发环境路径
      '${Directory.current.path}\\el_defect_system\\backend\\run_server.py',
      '${Directory.current.path}\\backend\\run_server.py',
      '${Directory.current.path}\\..\\backend\\run_server.py',
      // 如果从项目根目录启动
      '${Directory.current.path}\\..\\el_defect_system\\backend\\run_server.py',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  /// 查找合适的 Python 可执行文件（优先使用当前目录及上级目录的虚拟环境）
  String _findPythonExecutable() {
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    
    final candidates = [
      '$exeDir\\..\\..\\..\\..\\.venv\\Scripts\\python.exe',
      '${Directory.current.path}\\..\\..\\.venv\\Scripts\\python.exe',
      '${Directory.current.path}\\..\\.venv\\Scripts\\python.exe',
      '${Directory.current.path}\\.venv\\Scripts\\python.exe',
      'E:\\anaconda3\\python.exe',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    // 默认使用系统环境
    return 'python';
  }

  /// 关闭后端进程
  void shutdown() {
    _process?.kill();
    _process = null;
    _started = false;
  }
}
