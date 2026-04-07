import 'package:dio/dio.dart';

import '../models/detection_models.dart';

/// API异常，封装用户友好的中文错误消息
class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

class DetectionApiService {
  DetectionApiService(String baseUrl)
      : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 300),
            headers: {'Content-Type': 'application/json'},
          ),
        );

  final Dio _dio;
  
  /// 获取当前 baseUrl
  String get baseUrl => _dio.options.baseUrl;

  

  // --------------- 服务器运行时信息 ---------------

  /// 获取服务器运行时信息（GET /api/server/runtime）
  Future<Map<String, dynamic>> serverRuntime() async {
    try {
      final response = await _dio.get('/api/server/runtime');
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  // --------------- 模型列表 ---------------

  /// 获取服务器上的模型列表（GET /api/models）
  Future<Map<String, dynamic>> getModels() async {
    try {
      final response = await _dio.get('/api/models');
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  // --------------- 健康检查 ---------------

  Future<Map<String, dynamic>> health() async {
    try {
      final response = await _dio.get('/health');
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  // --------------- GPU / 系统诊断 ---------------

  /// 获取 GPU 硬件状态和依赖诊断信息（GET /api/system/gpu_status）
  Future<Map<String, dynamic>> getGpuStatus() async {
    try {
      final response = await _dio.get('/api/system/gpu_status');
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  // --------------- 模型加载 ---------------

  /// 通过完整参数加载模型（POST /api/model/load）
  Future<Map<String, dynamic>> loadModel({
    required String modelPath,
    required List<String> labels,
    required int inputWidth,
    required int inputHeight,
    required double confidenceThreshold,
    required double iouThreshold,
    required String outputLayout,
    bool normalize = true,
    bool swapRb = true,
    String backendPreference = 'onnxruntime',
  }) async {
    try {
      final response = await _dio.post(
        '/api/model/load',
        data: {
          'model_path': modelPath,
          'labels': labels,
          'input_width': inputWidth,
          'input_height': inputHeight,
          'confidence_threshold': confidenceThreshold,
          'iou_threshold': iouThreshold,
          'output_layout': outputLayout,
          'normalize': normalize,
          'swap_rb': swapRb,
          'backend_preference': backendPreference,
        },
      );
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  /// 通过ModelConfig加载模型
  Future<Map<String, dynamic>> loadModelFromConfig(ModelConfig config) async {
    try {
      final response = await _dio.post(
        '/api/model/load',
        data: config.toJson(),
      );
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  /// 通过配置文件路径加载模型（POST /api/model/load_profile）
  Future<Map<String, dynamic>> loadModelByProfile({
    required String profilePath,
  }) async {
    try {
      final response = await _dio.post(
        '/api/model/load_profile',
        queryParameters: {'profile_path': profilePath},
      );
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  // --------------- 单张检测 ---------------

  /// 单张图像检测（POST /api/detect）
  Future<DetectResult> detect({
    required String imagePath,
    required double confidenceThreshold,
    required double iouThreshold,
    bool saveVisualization = false,
    String? visualizationDir,
    int strokeWidth = 2,
    int fontSize = 16,
    bool showBoxes = true,
    bool showLabels = true,
    bool showConfidence = true,
  }) async {
    try {
      final data = <String, dynamic>{
        'image_path': imagePath,
        'confidence_threshold': confidenceThreshold,
        'iou_threshold': iouThreshold,
        'save_visualization': saveVisualization,
        'stroke_width': strokeWidth,
        'font_size': fontSize,
        'show_boxes': showBoxes,
        'show_labels': showLabels,
        'show_confidence': showConfidence,
      };
      if (visualizationDir != null) {
        data['visualization_dir'] = visualizationDir;
      }
      final response = await _dio.post('/api/detect', data: data);
      return DetectResult.fromJson(_asMap(response.data));
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  // --------------- 批量检测 ---------------

  /// 批量图像检测（POST /api/detect/batch）
  Future<BatchSummary> detectBatch({
    required String inputDir,
    required double confidenceThreshold,
    required double iouThreshold,
    bool recursive = true,
    List<String>? extensions,
    int maxImages = 5000,
    bool saveVisualization = false,
    String? visualizationDir,
    int strokeWidth = 2,
    int fontSize = 16,
    bool showBoxes = true,
    bool showLabels = true,
    bool showConfidence = true,
  }) async {
    try {
      final data = <String, dynamic>{
        'input_dir': inputDir,
        'recursive': recursive,
        'confidence_threshold': confidenceThreshold,
        'iou_threshold': iouThreshold,
        'max_images': maxImages,
        'save_visualization': saveVisualization,
        'stroke_width': strokeWidth,
        'font_size': fontSize,
        'show_boxes': showBoxes,
        'show_labels': showLabels,
        'show_confidence': showConfidence,
      };
      if (extensions != null) {
        data['extensions'] = extensions;
      }
      if (visualizationDir != null) {
        data['visualization_dir'] = visualizationDir;
      }
      final response = await _dio.post('/api/detect/batch', data: data);
      return BatchSummary.fromJson(_asMap(response.data));
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  // --------------- 图片分割 ---------------

  /// 图片分割（POST /api/segment）
  Future<Map<String, dynamic>> segment({
    required String imagePath,
    required bool filterEdges,
    bool autoCrop = false,
    bool perspectiveCrop = false,
    int expandPx = 0,
    int cropQuality = 95,
    String? outputDir,
    String? relativeSubdir,
    int cropResW = 0,
    int cropResH = 0,
    List<List<List<double>>>? manualQuads,
  }) async {
    try {
      final data = <String, dynamic>{
        'image_path': imagePath,
        'filter_edges': filterEdges,
        'auto_crop': autoCrop,
        'perspective_crop': perspectiveCrop,
        'expand_px': expandPx,
        'crop_quality': cropQuality,
      };
      if (outputDir != null && outputDir.isNotEmpty) data['output_dir'] = outputDir;
      if (relativeSubdir != null && relativeSubdir.isNotEmpty) data['relative_subdir'] = relativeSubdir;
      if (cropResW > 0 && cropResH > 0) {
        data['crop_res_w'] = cropResW;
        data['crop_res_h'] = cropResH;
      }
      if (manualQuads != null && manualQuads.isNotEmpty) {
        data['manual_quads'] = manualQuads;
      }
      final response = await _dio.post('/api/segment', data: data);
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  // --------------- CSV报告导出 ---------------

  /// 导出CSV报告（POST /api/report/export_csv）
  Future<Map<String, dynamic>> exportCsv({
    required Map<String, dynamic> projectInfo,
    required String outputPath,
  }) async {
    try {
      final response = await _dio.post('/api/report/export_csv', data: {
        'project_info': projectInfo,
        'output_path': outputPath,
      });
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  /// 导出Word报告（POST /api/report/export_word）
  /// 大量图片导出耗时很长，使用独立超长超时（30分钟）
  Future<Map<String, dynamic>> exportWord({
    required Map<String, dynamic> projectInfo,
    required String outputPath,
  }) async {
    try {
      final response = await _dio.post(
        '/api/report/export_word',
        data: {
          'project_info': projectInfo,
          'output_path': outputPath,
        },
        options: Options(
          receiveTimeout: const Duration(minutes: 30),
          sendTimeout: const Duration(minutes: 5),
        ),
      );
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  /// 导出Excel报告（POST /api/report/export_excel）
  /// 大量数据导出耗时可能很长，使用独立超长超时（30分钟）
  Future<Map<String, dynamic>> exportExcel({
    required Map<String, dynamic> projectInfo,
    required String outputPath,
  }) async {
    try {
      final response = await _dio.post(
        '/api/report/export_excel',
        data: {
          'project_info': projectInfo,
          'output_path': outputPath,
        },
        options: Options(
          receiveTimeout: const Duration(minutes: 30),
          sendTimeout: const Duration(minutes: 5),
        ),
      );
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  /// 导出Excel组串图片报告（POST /api/report/export_excel_grid）
  Future<Map<String, dynamic>> exportExcelGrid({
    required String sourceDir,
    required String outputPath,
    int colsPerString = 10,
    int imgQuality = 85,
    String exportMode = 'both', // both | images | names
    Map<String, dynamic>? projectInfo,
  }) async {
    try {
      final response = await _dio.post('/api/report/export_excel_grid', data: {
        'source_dir': sourceDir,
        'output_path': outputPath,
        'cols_per_string': colsPerString,
        'img_quality': imgQuality,
        'export_mode': exportMode,
        'project_info': projectInfo ?? {},
      });
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  /// 导出带标注的检测图片（POST /api/report/export_images）
  Future<Map<String, dynamic>> exportImages({
    required Map<String, dynamic> projectInfo,
    required String outputDir,
  }) async {
    try {
      final response = await _dio.post('/api/report/export_images', data: {
        'project_info': projectInfo,
        'output_dir': outputDir,
      });
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  // --------------- 地理信息提取 ---------------

  /// 从图片中提取 GPS 元数据（POST /api/utils/extract_gps）
  Future<Map<String, dynamic>> extractGps(String imagePath) async {
    try {
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(imagePath),
      });
      final response = await _dio.post('/api/utils/extract_gps', data: formData);
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _convertDioException(e);
    }
  }

  // --------------- 工具方法 ---------------

  /// 将DioException转换为用户友好的ApiException
  static ApiException _convertDioException(DioException e) {
    // 有HTTP响应时，优先提取后端返回的detail字段
    if (e.response != null) {
      final data = e.response!.data;
      if (data is Map && data.containsKey('detail')) {
        return ApiException(data['detail'].toString());
      }
      return ApiException('请求失败 (${e.response!.statusCode})');
    }

    // 无响应时，根据错误类型返回中文提示
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return ApiException('连接超时，请检查后端服务是否启动');
      case DioExceptionType.sendTimeout:
        return ApiException('发送超时，请检查网络连接');
      case DioExceptionType.receiveTimeout:
        return ApiException('接收超时，检测任务可能需要更长时间');
      case DioExceptionType.connectionError:
        return ApiException('网络连接失败，请检查后端服务是否在运行');
      case DioExceptionType.cancel:
        return ApiException('请求已取消');
      default:
        return ApiException('网络请求异常: ${e.message ?? "未知错误"}');
    }
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return {};
  }

}


