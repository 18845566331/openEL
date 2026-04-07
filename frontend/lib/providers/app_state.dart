import 'package:flutter/foundation.dart';

import '../models/detection_models.dart';

/// 应用全局状态管理 — 任务20
///
/// 管理模型加载状态、检测任务状态、检测结果数据和UI配置参数。
/// 使用Provider进行状态管理，各页面通过Consumer/context.watch消费状态。
class AppState extends ChangeNotifier {
  // ============ 后端连接 ============
  String _backendUrl = 'http://127.0.0.1:5000';
  String get backendUrl => _backendUrl;
  void setBackendUrl(String url) {
    _backendUrl = url;
    notifyListeners();
  }

  // ============ 模型加载状态 ============
  bool _modelLoaded = false;
  bool get modelLoaded => _modelLoaded;

  String? _modelPath;
  String? get modelPath => _modelPath;

  List<String> _labels = [];
  List<String> get labels => _labels;

  void setModelLoaded(bool value) {
    _modelLoaded = value;
    notifyListeners();
  }

  void setModelPath(String? path) {
    _modelPath = path;
    notifyListeners();
  }

  void setLabels(List<String> labels) {
    _labels = labels;
    notifyListeners();
  }

  // ============ 检测参数 ============
  double _confidence = 0.55;
  double get confidence => _confidence;

  double _iou = 0.45;
  double get iou => _iou;

  void setConfidence(double value) {
    _confidence = value;
    notifyListeners();
  }

  void setIou(double value) {
    _iou = value;
    notifyListeners();
  }

  // ============ 检测任务状态 ============
  bool _detecting = false;
  bool get detecting => _detecting;

  void setDetecting(bool value) {
    _detecting = value;
    notifyListeners();
  }

  // ============ 检测结果数据 ============
  DetectResult? _lastSingleResult;
  DetectResult? get lastSingleResult => _lastSingleResult;

  BatchSummary? _lastBatchResult;
  BatchSummary? get lastBatchResult => _lastBatchResult;

  void setLastSingleResult(DetectResult? result) {
    _lastSingleResult = result;
    notifyListeners();
  }

  void setLastBatchResult(BatchSummary? result) {
    _lastBatchResult = result;
    notifyListeners();
  }

  // ============ UI导航状态 ============
  int _activePageIndex = 0;
  int get activePageIndex => _activePageIndex;

  void setActivePageIndex(int index) {
    _activePageIndex = index;
    notifyListeners();
  }
}
