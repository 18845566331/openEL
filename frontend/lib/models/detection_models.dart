/// 模型配置参数，对应后端 ModelLoadRequest 和运行时状态
class ModelConfig {
  ModelConfig({
    required this.modelPath,
    this.labels = const [],
    this.inputWidth = 640,
    this.inputHeight = 640,
    this.outputLayout = 'cxcywh_obj_cls',
    this.normalize = true,
    this.swapRb = true,
    this.confidenceThreshold = 0.55,
    this.iouThreshold = 0.45,
    this.backendPreference = 'onnxruntime',
  });

  final String modelPath;
  final List<String> labels;
  final int inputWidth;
  final int inputHeight;
  final String outputLayout;
  final bool normalize;
  final bool swapRb;
  final double confidenceThreshold;
  final double iouThreshold;
  final String backendPreference;

  /// 从JSON配置文件或后端运行时状态反序列化
  factory ModelConfig.fromJson(Map<String, dynamic> json) {
    return ModelConfig(
      modelPath: (json['model_path'] ?? '').toString(),
      labels: (json['labels'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      inputWidth: (json['input_width'] as num?)?.toInt() ?? 640,
      inputHeight: (json['input_height'] as num?)?.toInt() ?? 640,
      outputLayout:
          (json['output_layout'] ?? 'cxcywh_obj_cls').toString(),
      normalize: json['normalize'] as bool? ?? true,
      swapRb: json['swap_rb'] as bool? ?? true,
      confidenceThreshold:
          (json['confidence_threshold'] as num?)?.toDouble() ?? 0.55,
      iouThreshold:
          (json['iou_threshold'] as num?)?.toDouble() ?? 0.45,
      backendPreference:
          (json['backend_preference'] ?? 'onnxruntime').toString(),
    );
  }

  /// 序列化为JSON，用于发送到后端API
  Map<String, dynamic> toJson() {
    return {
      'model_path': modelPath,
      'labels': labels,
      'input_width': inputWidth,
      'input_height': inputHeight,
      'output_layout': outputLayout,
      'normalize': normalize,
      'swap_rb': swapRb,
      'confidence_threshold': confidenceThreshold,
      'iou_threshold': iouThreshold,
      'backend_preference': backendPreference,
    };
  }
}

class DetectionBox {
  DetectionBox({
    required this.className,
    required this.score,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  final String className;
  final double score;
  final int x1;
  final int y1;
  final int x2;
  final int y2;

  factory DetectionBox.fromJson(Map<String, dynamic> json) {
    final box = json['box'] as Map<String, dynamic>? ?? {};
    return DetectionBox(
      className: (json['class_name'] ?? '未命名缺陷').toString(),
      score: (json['score'] as num?)?.toDouble() ?? 0,
      x1: (box['x1'] as num?)?.toInt() ?? 0,
      y1: (box['y1'] as num?)?.toInt() ?? 0,
      x2: (box['x2'] as num?)?.toInt() ?? 0,
      y2: (box['y2'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'class_name': className,
      'score': score,
      'box': {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2},
    };
  }

  DetectionBox copyWithClassName(String newName) {
    return DetectionBox(
      className: newName,
      score: score,
      x1: x1, y1: y1, x2: x2, y2: y2,
    );
  }
}

class DetectResult {
  DetectResult({
    required this.imagePath,
    required this.total,
    required this.detections,
    this.visualizationPath,
    this.error,
  });

  final String imagePath;
  final int total;
  final List<DetectionBox> detections;
  final String? visualizationPath;
  final String? error;

  /// 判断该图像是否检测到缺陷（NG）
  bool get isNG => total > 0;

  factory DetectResult.fromJson(Map<String, dynamic> json) {
    final list = (json['detections'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(DetectionBox.fromJson)
        .toList();
    return DetectResult(
      imagePath: (json['image_path'] ?? '').toString(),
      total: (json['total'] as num?)?.toInt() ?? list.length,
      detections: list,
      visualizationPath: json['visualization_path']?.toString(),
      error: json['error']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'image_path': imagePath,
      'total': total,
      'detections': detections.map((d) => d.toJson()).toList(),
      if (visualizationPath != null) 'visualization_path': visualizationPath,
      if (error != null) 'error': error,
    };
  }

  DetectResult withDetections(List<DetectionBox> newDetections) {
    return DetectResult(
      imagePath: imagePath,
      total: newDetections.length,
      detections: newDetections,
      visualizationPath: visualizationPath,
      error: error,
    );
  }
}

class BatchSummary {
  BatchSummary({
    required this.totalImages,
    required this.okImages,
    required this.ngImages,
    required this.totalDefects,
    required this.defectByClass,
    required this.results,
  });

  final int totalImages;
  final int okImages;
  final int ngImages;
  final int totalDefects;
  final Map<String, int> defectByClass;
  final List<DetectResult> results;

  factory BatchSummary.fromJson(Map<String, dynamic> json) {
    final rawMap = (json['defect_by_class'] as Map<String, dynamic>? ?? {});
    final byClass = <String, int>{};
    for (final entry in rawMap.entries) {
      byClass[entry.key] = (entry.value as num?)?.toInt() ?? 0;
    }

    final resultList = (json['results'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(DetectResult.fromJson)
        .toList();

    return BatchSummary(
      totalImages: (json['total_images'] as num?)?.toInt() ?? 0,
      okImages: (json['ok_images'] as num?)?.toInt() ?? 0,
      ngImages: (json['ng_images'] as num?)?.toInt() ?? 0,
      totalDefects: (json['total_defects'] as num?)?.toInt() ?? 0,
      defectByClass: byClass,
      results: resultList,
    );
  }

  /// 序列化为JSON，用于CSV导出请求
  Map<String, dynamic> toJson() {
    return {
      'total_images': totalImages,
      'ok_images': okImages,
      'ng_images': ngImages,
      'total_defects': totalDefects,
      'defect_by_class': defectByClass,
      'results': results.map((r) => r.toJson()).toList(),
    };
  }
}

