import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import '../services/detection_api_service.dart';

class DynamicReportPreviewPage extends StatefulWidget {
  final Map<String, dynamic> initialData;
  final String templatePath;
  final String serverUrl;

  const DynamicReportPreviewPage({
    Key? key,
    required this.initialData,
    required this.templatePath,
    required this.serverUrl,
  }) : super(key: key);

  @override
  State<DynamicReportPreviewPage> createState() => _DynamicReportPreviewPageState();
}

class _DynamicReportPreviewPageState extends State<DynamicReportPreviewPage> {
  late final Dio _dio;
  bool _isLoading = true;
  bool _isGeneratingPreview = false;
  Timer? _debounceTimer;
  
  List<String> _dynamicFields = [];
  Map<String, TextEditingController> _controllers = {};
  
  List<String> _previewImagesBase64 = []; // List of base64 preview page images

  @override
  void initState() {
    super.initState();
    _dio = Dio(BaseOptions(baseUrl: widget.serverUrl));
    _loadTemplateFields();
  }

  Future<void> _loadTemplateFields() async {
    try {
      final res = await _dio.post('/api/report/template_fields', data: {
        'template_path': widget.templatePath,
      });
      
      if (res.data['success'] == true) {
        final List<dynamic> fields = res.data['fields'];
        setState(() {
          _dynamicFields = fields.map((e) => e.toString()).toList();
          for (var field in _dynamicFields) {
            _controllers[field] = TextEditingController(text: widget.initialData[field]?.toString() ?? '');
          }
          _isLoading = false;
        });
        
        // 生成初次预览
        _refreshPreview();
      } else {
        _showError('解析模板失败: ${res.data["detail"]}');
      }
    } catch (e) {
      _showError('网络请求失败: $e');
    }
  }

  Future<void> _refreshPreview() async {
    setState(() => _isGeneratingPreview = true);
    try {
      final Map<String, dynamic> submitData = Map.from(widget.initialData);
      for (var f in _dynamicFields) {
        submitData[f] = _controllers[f]?.text ?? '';
      }
      
      final res = await _dio.post('/api/report/live_preview', data: {
        'template_path': widget.templatePath,
        'fields_data': submitData,
      });

      if (res.data['success'] == true) {
        setState(() {
          _previewImagesBase64 = List<String>.from(res.data['pages']);
        });
      } else {
        _showError(res.data['error'] ?? 'PDF生成失败');
      }
    } catch (e) {
      _showError('预览引擎超时或失败: $e');
    } finally {
      setState(() => _isGeneratingPreview = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    setState(() => _isLoading = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    for (var c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E293B),
      appBar: AppBar(
        title: const Text('动态报告设计器 (所见即所得)', style: TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF0F172A),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '触发布局渲染',
            onPressed: _refreshPreview,
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.download, size: 16),
            label: const Text('最终导出为Word'),
            onPressed: () async {
              String? savePath = await FilePicker.platform.saveFile(
                dialogTitle: '保存最终报告',
                fileName: '自动生成报告.docx',
                allowedExtensions: ['docx'],
                type: FileType.custom,
              );
              if (savePath == null) return;
              if (!savePath.toLowerCase().endsWith('.docx')) savePath += '.docx';
              
              final Map<String, dynamic> submitData = Map.from(widget.initialData);
              for (var f in _dynamicFields) {
                submitData[f] = _controllers[f]?.text ?? '';
              }
              
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('正在通过 docxtpl 引擎生成高保真报告...')));
              try {
                final res = await _dio.post('/api/report/dynamic_generate', data: {
                  'template_path': widget.templatePath,
                  'output_path': savePath,
                  'fields_data': submitData,
                });
                if (res.data['success'] == true) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('高保真动态报告已导出至 $savePath')));
                } else {
                  _showError('生成失败: ${res.data['detail'] ?? res.data['error']}');
                }
              } catch (e) {
                _showError('导出出错: $e');
              }
            },
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : Row(
            children: [
              // 左侧：完美的A4纸实时预览
              Expanded(
                flex: 2,
                child: Container(
                  color: const Color(0xFF0F172A),
                  child: _previewImagesBase64.isEmpty
                      ? (_isGeneratingPreview 
                         ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 16), Text('正调用 Windows Office 服务进行100%真实排版渲染...', style: TextStyle(color: Colors.white70))]))
                         : const Center(child: Text('无预览可用', style: TextStyle(color: Colors.white54))))
                      : Stack(
                          children: [
                            InteractiveViewer(
                              minScale: 0.5,
                              maxScale: 3.0,
                              child: ListView.builder(
                                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 40),
                                itemCount: _previewImagesBase64.length,
                                itemBuilder: (context, index) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 20),
                                    child: PhysicalModel(
                                      color: Colors.white,
                                      elevation: 8,
                                      child: Image.memory(
                                        base64Decode(_previewImagesBase64[index]),
                                        fit: BoxFit.contain,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            if (_isGeneratingPreview)
                              Positioned(
                                bottom: 20,
                                right: 20,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.black87,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                                      SizedBox(width: 10),
                                      Text('实时渲染更新中...', style: TextStyle(color: Colors.white, fontSize: 13)),
                                    ],
                                  ),
                                ),
                              )
                          ],
                        ),
                ),
              ),
              // 右侧：动态收集的表单
              Container(width: 1, color: Colors.blueGrey.withOpacity(0.3)),
              Expanded(
                flex: 1,
                child: Container(
                  color: const Color(0xFF1E293B),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('请填写模板字段：', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      const Text('以下字段全部通过自动扫描 Word 模板获取。', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      const SizedBox(height: 24),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _dynamicFields.length,
                          itemBuilder: (context, index) {
                            final fieldName = _dynamicFields[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: TextFormField(
                                controller: _controllers[fieldName],
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  labelText: fieldName, // 模板中扫描出来的{{ XXX }}名字
                                  labelStyle: const TextStyle(color: Color(0xFF7DD3FC)),
                                  filled: true,
                                  fillColor: const Color(0xFF0F172A),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide.none,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(color: Color(0xFF334155)),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(color: Color(0xFF7DD3FC)),
                                  ),
                                ),
                                onChanged: (value) {
                                  if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
                                  _debounceTimer = Timer(const Duration(milliseconds: 400), () {
                                    _refreshPreview();
                                  });
                                },
                                onEditingComplete: () {
                                  // 失焦或回车时，静默触发重新渲染
                                  FocusScope.of(context).unfocus();
                                  _refreshPreview();
                                },
                              ),
                            );
                          },
                        ),
                      )
                    ],
                  ),
                ),
              )
            ],
          ),
    );
  }
}
