import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// 品牌信息本地持久化存储（纯本地开源版）
///
/// 优先级：
/// 1. 本地持久化数据
/// 2. assets/branding/ 中打包时写入的默认值
class BrandingStore {
  static BrandingStore? _instance;
  static BrandingStore get instance => _instance ??= BrandingStore._();
  BrandingStore._();

  String _companyName = '';
  String _logoLocalPath = '';

  String get companyName => _companyName;
  String get logoLocalPath => _logoLocalPath;
  bool get hasLogo => _logoLocalPath.isNotEmpty && File(_logoLocalPath).existsSync();

  /// 获取本地存储目录
  static Future<Directory> get _brandDir async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}/branding');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> get _jsonFile async {
    final dir = await _brandDir;
    return File('${dir.path}/branding.json');
  }

  /// 初始化：先读本地持久化，没有则读 assets 默认值
  Future<void> init() async {
    // 1. 尝试读取本地持久化的品牌信息
    final loaded = await _loadFromLocal();
    if (loaded) return;

    // 2. 读取 assets 中打包时写入的默认值
    await _loadFromAssets();
  }

  Future<bool> _loadFromLocal() async {
    try {
      final f = await _jsonFile;
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _companyName = (data['company_name'] ?? '').toString().trim();
        final logoFile = (data['logo_local_path'] ?? '').toString().trim();
        if (logoFile.isNotEmpty && File(logoFile).existsSync()) {
          _logoLocalPath = logoFile;
        }
        return _companyName.isNotEmpty;
      }
    } catch (_) {}
    return false;
  }

  Future<void> _loadFromAssets() async {
    try {
      final jsonStr = await rootBundle.loadString('assets/branding/branding.json');
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      _companyName = (data['company_name'] ?? '').toString().trim();

      // 尝试将 assets logo 复制到本地
      final logoFile = (data['logo_file'] ?? '').toString().trim();
      if (logoFile.isNotEmpty) {
        try {
          final bytes = await rootBundle.load('assets/branding/$logoFile');
          final dir = await _brandDir;
          final localLogo = File('${dir.path}/$logoFile');
          await localLogo.writeAsBytes(bytes.buffer.asUint8List());
          _logoLocalPath = localLogo.path;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 更新品牌信息并持久化
  Future<void> update({
    required String name,
    String logoLocalPath = '',
  }) async {
    if (name.isEmpty && logoLocalPath.isEmpty) return;
    if (name.isNotEmpty) _companyName = name;
    if (logoLocalPath.isNotEmpty) _logoLocalPath = logoLocalPath;
    await _saveToLocal();
  }

  Future<void> _saveToLocal() async {
    try {
      final f = await _jsonFile;
      final data = {
        'company_name': _companyName,
        'logo_local_path': _logoLocalPath,
      };
      await f.writeAsString(jsonEncode(data));
    } catch (_) {}
  }
}
