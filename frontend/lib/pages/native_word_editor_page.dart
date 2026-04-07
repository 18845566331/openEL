import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import '../services/detection_api_service.dart';

class NativeWordEditorPage extends StatefulWidget {
  final Map<String, dynamic> initialData;
  final String templatePath;
  final String serverUrl;

  const NativeWordEditorPage({
    Key? key,
    required this.initialData,
    required this.templatePath,
    required this.serverUrl,
  }) : super(key: key);

  @override
  State<NativeWordEditorPage> createState() => _NativeWordEditorPageState();
}

class _NativeWordEditorPageState extends State<NativeWordEditorPage> {
  String? _draftPath;
  DateTime? _lastModified;
  Timer? _watchTimer;
  int _saveCount = 0;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _prepareDraft();
  }

  Future<void> _prepareDraft() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final fileName = "Draft_Template_${DateTime.now().millisecondsSinceEpoch}.docx";
      _draftPath = "${tempDir.path}\\$fileName";
      
      // 复制主模板作为草稿
      File(widget.templatePath).copySync(_draftPath!);
      _lastModified = File(_draftPath!).lastModifiedSync();
      
      // 启动心跳监控，每 1.5 秒检查一次文件最后修改时间
      _watchTimer = Timer.periodic(const Duration(milliseconds: 1500), (timer) {
        if (!mounted) return;
        if (_draftPath != null && File(_draftPath!).existsSync()) {
          final currentMod = File(_draftPath!).lastModifiedSync();
          if (_lastModified != null && currentMod.isAfter(_lastModified!)) {
             setState(() {
               _lastModified = currentMod;
               _saveCount++;
             });
          }
        }
      });
    } catch (e) {
      debugPrint('草稿准备失败: $e');
    }
  }

  @override
  void dispose() {
    _watchTimer?.cancel();
    super.dispose();
  }

  void _openInWord() {
    if (_draftPath != null) {
      // 在 Windows 本地强行使用默认程序（Word/WPS）打开文档
      Process.run('cmd', ['/c', 'start', '', _draftPath!]);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已唤醒系统默认办公软件 (Word / WPS)。请全屏自由编写并在完成后按 Ctrl + S 保存。'),
          backgroundColor: Colors.blueAccent,
          duration: Duration(seconds: 4),
        )
      );
    }
  }

  Future<void> _handleExport() async {
    if (_draftPath == null) return;
    String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存这篇由您深度定制的最终报告',
      fileName: '光伏缺陷检测深度定制报告.docx',
      allowedExtensions: ['docx'],
      type: FileType.custom,
    );
    if (savePath == null) return;
    if (!savePath.toLowerCase().endsWith('.docx')) savePath += '.docx';

    setState(() => _isExporting = true);
    
    // 如果想要系统AI进一步接管填充，可以在此传给后端。
    // 因为不能修改现有API，我们选择把已经编辑好的草稿拷贝过去作为"最终带模板的手工填充版"。
    // 【注】如果您希望后台继续往里面塞图片，可以在此处将 _draftPath 传给 backend，
    // 前提是对 DetectionApiService 的 exportWord 扩展了 "customTemplatePath" 参数。
    try {
      final api = DetectionApiService(widget.serverUrl);
      
      // 出于纯前端方案，如果不需要后端再塞入AI数据，直接copy：
      File(_draftPath!).copySync(savePath);
      // 如果现有接口支持，调用原有接口：
      await api.exportWord(projectInfo: widget.initialData, outputPath: savePath);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('🎉 最终报告已成功导出至：$savePath')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // 深色酷炫背景
      appBar: AppBar(
        title: const Text('原生 Office 联调引擎 (方案1 - 桥接护航版)', style: TextStyle(fontSize: 16, color: Colors.white)),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 800),
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 状态监测面板
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _saveCount > 0 ? Colors.green.withOpacity(0.5) : const Color(0xFF334155), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    )
                  ],
                ),
                child: Column(
                  children: [
                    Icon(
                      _saveCount > 0 ? Icons.check_circle : Icons.sync_problem,
                      size: 64,
                      color: _saveCount > 0 ? Colors.greenAccent : Colors.orangeAccent,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _saveCount > 0 
                        ? '系统已成功拦截到您的 $_saveCount 次保存流' 
                        : '系统监听中，正等待您唤醒 Office 进行编辑...',
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _lastModified != null 
                        ? '草稿最后安全同步时间：${_lastModified.toString().split('.')[0]}'
                        : '尚未进行同步',
                      style: const TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 48),

              // 核心操作区
              Row(
                children: [
                   Expanded(
                     child: _buildActionCard(
                       title: '步骤 1 : 唤醒原生 Word 强编辑',
                       subtitle: '将脱离界面，开启真正的 100% 原始界面并享受无极调版。完成后请务必在 Word 内按 Ctrl + S 保存。',
                       icon: Icons.edit_document,
                       color: const Color(0xFF3B82F6),
                       onTap: _openInWord,
                     ),
                   ),
                   const SizedBox(width: 24),
                   Expanded(
                     child: _buildActionCard(
                       title: '步骤 2 : 锁定排版并生成最终报告',
                       subtitle: '系统将锁定您刚刚保存的心血结晶，并将它带回工业系统中打包。',
                       icon: Icons.upgrade_rounded,
                       color: _saveCount > 0 ? const Color(0xFF10B981) : Colors.grey, // 有保存才变亮
                       onTap: _isExporting ? null : _handleExport,
                       isLoading: _isExporting,
                     ),
                   ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
    bool isLoading = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: isLoading 
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(icon, color: color, size: 28),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
