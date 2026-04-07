import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';

class ProjectInfoPanel extends StatefulWidget {
  final Map<String, dynamic> initialProjectInfo;
  final Function(Map<String, dynamic> data) onSaveProject;
  final Function(Map<String, dynamic> data)? onInfoChanged;
  final Function(Map<String, dynamic> data)? onExportWord;
  final Function(Map<String, dynamic> data)? onExportExcel;
  final Function(Map<String, dynamic> data)? onExportCsv;
  final String? autoSaveDir; // 数据存储目录，用于自动保存
  final VoidCallback? onClose; // 关闭面板回调

  const ProjectInfoPanel({
    super.key,
    required this.initialProjectInfo,
    required this.onSaveProject,
    this.onInfoChanged,
    this.onExportWord,
    this.onExportExcel,
    this.onExportCsv,
    this.autoSaveDir,
    this.onClose,
  });

  @override
  State<ProjectInfoPanel> createState() => _ProjectInfoPanelState();
}

class _ProjectInfoPanelState extends State<ProjectInfoPanel> {
  final _formKey = GlobalKey<FormState>();
  late Map<String, dynamic> _projectInfo;

  String? _geographicImagePath;
  String? _overallImagePath;

  // 光伏组件参数列表（每项是一组参数 Map）
  List<Map<String, String>> _pvModules = [];

  final Map<String, List<String>> _checkboxSelections = {
    '建设状态': [],
    '电站类型': [],
    '土地类型': [],
    '水/土壤情况': [],
    '桩基形式': [],
    '支架形式': [],
    '气象站采集数据类型': [],
  };
  // 自动保存历史记录
  List<Map<String, dynamic>> _savedEntries = [];
  Timer? _autoSaveTimer;

  @override
  void initState() {
    super.initState();
    _projectInfo = Map.from(widget.initialProjectInfo);
    _initializeDefaults();
    _loadSavedEntries();
  }

  @override
  void didUpdateWidget(ProjectInfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialProjectInfo != oldWidget.initialProjectInfo) {
      setState(() {
        _projectInfo = Map.from(widget.initialProjectInfo);
        _checkboxSelections.forEach((key, list) => list.clear());
        _initializeDefaults();
        _formRebuildKey++;
      });
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    super.dispose();
  }

  String get _autoSaveFilePath {
    final dir = widget.autoSaveDir ?? Directory.current.path;
    return '$dir${Platform.pathSeparator}project_info_autosave.json';
  }

  Future<void> _loadSavedEntries() async {
    try {
      final file = File(_autoSaveFilePath);
      if (await file.exists()) {
        final data = json.decode(await file.readAsString());
        if (data is List) {
          setState(() => _savedEntries = data.cast<Map<String, dynamic>>());
        }
      }
    } catch (_) {}
  }

  void _triggerAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () => _doAutoSave());
  }

  Future<void> _doAutoSave() async {
    try {
      _formKey.currentState?.save();
      _collectCheckboxData();
      final name = _projectInfo['项目名称']?.toString() ?? _projectInfo['project_name']?.toString() ?? '';
      if (name.isEmpty) return; // 没有项目名称不保存

      final entry = Map<String, dynamic>.from(_projectInfo);
      entry['_auto_save_time'] = DateTime.now().toIso8601String();

      // 更新或添加
      final idx = _savedEntries.indexWhere((e) =>
          (e['项目名称']?.toString() ?? e['project_name']?.toString() ?? '') == name);
      if (idx >= 0) {
        _savedEntries[idx] = entry;
      } else {
        _savedEntries.insert(0, entry);
      }

      // 最多保留 20 条
      if (_savedEntries.length > 20) _savedEntries = _savedEntries.sublist(0, 20);

      await File(_autoSaveFilePath).writeAsString(json.encode(_savedEntries));
    } catch (_) {}
  }

  void _initializeDefaults() {
    final now = DateTime.now();
    final dateStr = "${now.year}/${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}";
    _setDefault('签发日期', dateStr);
    if (widget.initialProjectInfo['geographic_image_path'] != null) {
      _geographicImagePath = widget.initialProjectInfo['geographic_image_path'];
    }
    if (widget.initialProjectInfo['overall_image_path'] != null) {
      _overallImagePath = widget.initialProjectInfo['overall_image_path'];
    }
    // 从已保存的数据中恢复复选框状态
    _restoreCheckboxSelections();
    // 从已保存的数据中恢复光伏组件参数
    _restorePvModules();
  }

  /// 从 _projectInfo 中解析 ☑/☐ 格式的字符串，恢复 _checkboxSelections
  void _restoreCheckboxSelections() {
    final checkboxGroups = {
      '建设状态': ['选址', '可研', '初设', '施工', '并网', '其他'],
      '电站类型': ['地面', '山地', '农业大棚', '渔光', '其他'],
      '土地类型': ['荒山/坡', '沙漠', '滩涂', '湖泊', '农田', '戈壁', '矿区(采煤沉陷区)'],
      '水/土壤情况': ['岩石', '沙地', '粉土', '其他'],
      '桩基形式': ['锚栓', '灌注桩', '螺旋桩', '条形基础'],
      '支架形式': ['固定倾角', '单轴跟踪', '双轴跟踪', '平铺', '固定可调式'],
      '气象站采集数据类型': ['平面辐照', '阵列面辐照', '直辐射', '散射计', '组件温度', '风速', '风向', '温湿度'],
    };
    checkboxGroups.forEach((groupKey, options) {
      final saved = _projectInfo[groupKey]?.toString() ?? '';
      if (saved.contains('☑')) {
        _checkboxSelections[groupKey] = [];
        for (final opt in options) {
          if (saved.contains('☑ $opt')) {
            _checkboxSelections[groupKey]!.add(opt);
          }
        }
      }
    });
  }

  /// 从 _projectInfo['pv_modules'] 中恢复光伏组件参数列表
  void _restorePvModules() {
    final saved = _projectInfo['pv_modules'];
    if (saved is List && saved.isNotEmpty) {
      _pvModules = saved.map<Map<String, String>>((item) {
        if (item is Map) {
          return item.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
        }
        return <String, String>{};
      }).toList();
    } else {
      // 默认一组空的光伏组件参数
      _pvModules = [_emptyPvModule()];
    }
  }

  Map<String, String> _emptyPvModule() {
    return {
      '生产厂家': '', '型号': '', '类型': '', 'Pmax (Wp)': '',
      'Voc (V)': '', 'Vmp (V)': '', 'Isc (A)': '', 'Imp (A)': '',
      '组件尺寸 (mm)': '', '短路电流温度系数 (%/°C)': '',
      '功率温度系数 (%/°C)': '', '开路电压温度系数 (%/°C)': '',
    };
  }

  void _setDefault(String key, String value) {
    if (_projectInfo[key] == null || _projectInfo[key].toString().isEmpty) {
      _projectInfo[key] = value;
    }
  }

  // 用于强制 TextFormField 在加载历史时重建
  int _formRebuildKey = 0;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 顶部标题栏 + 历史记录 ──
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF1E293B), width: 1)),
              gradient: LinearGradient(
                colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.article_outlined, color: Color(0xFF22D3EE), size: 22),
                  const SizedBox(width: 10),
                  const Text('生成检测报告', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (_savedEntries.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F766E).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('已保存 ${_savedEntries.length} 条', style: const TextStyle(color: Color(0xFF2DD4BF), fontSize: 11)),
                    ),
                  if (widget.onClose != null) ...[
                    const SizedBox(width: 16),
                    IconButton(
                      icon: const Icon(Icons.close, color: Color(0xFF94A3B8)),
                      onPressed: widget.onClose,
                      tooltip: '关闭',
                      constraints: const BoxConstraints(),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ]),
                if (_savedEntries.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: null,
                    hint: const Text('📌 加载历史保存的项目信息...', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                    dropdownColor: const Color(0xFF334155),
                    style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
                    decoration: InputDecoration(
                      filled: true, fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF334155))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF334155))),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      prefixIcon: const Icon(Icons.history, size: 18, color: Color(0xFF64748B)),
                    ),
                    items: _savedEntries.asMap().entries.map((e) {
                      final entry = e.value;
                      final name = entry['项目名称']?.toString() ?? entry['project_name']?.toString() ?? '未命名';
                      final time = entry['_auto_save_time']?.toString() ?? '';
                      final timeStr = time.length >= 16 ? time.substring(0, 16).replaceAll('T', ' ') : '';
                      return DropdownMenuItem(value: e.key, child: Text('$name  ($timeStr)', overflow: TextOverflow.ellipsis));
                    }).toList(),
                    onChanged: (idx) {
                      if (idx != null && idx < _savedEntries.length) {
                        setState(() {
                          _projectInfo = Map<String, dynamic>.from(_savedEntries[idx]);
                          _restoreCheckboxSelections();
                          _restorePvModules();
                          _geographicImagePath = _projectInfo['geographic_image_path']?.toString();
                          _overallImagePath = _projectInfo['overall_image_path']?.toString();
                          _formRebuildKey++; // 强制重建TextFormField
                        });
                        widget.onInfoChanged?.call(_projectInfo);
                      }
                    },
                  ),
                ],
              ],
            ),
          ),

          // ── 表单主体 ──
          Expanded(
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                child: Column(
                  key: ValueKey(_formRebuildKey),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Section 1: 报告封面信息 ──
                    _buildSectionHeader('1. 报告封面信息', Icons.badge_outlined),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: _buildTextField('报告编号', '报告编号', required: true)),
                      const SizedBox(width: 16),
                      Expanded(child: _buildDateField('签发日期', '签发日期')),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: _buildTextField('委托单位', '委托单位')),
                      const SizedBox(width: 16),
                      Expanded(child: _buildTextField('检测单位', '检测单位')),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: _buildTextField('项目名称', '项目名称')),
                      const SizedBox(width: 16),
                      Expanded(child: _buildAddressField('项目地址', '项目地址')),
                    ]),
                    const SizedBox(height: 28),

                    // ── Section 2: 技术尽调报告 ──
                    _buildSectionHeader('2. 技术尽调报告', Icons.assignment_outlined),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: _buildAddressField('委托单位地址', '委托单位地址')),
                      const SizedBox(width: 16),
                      Expanded(child: _buildDateRangeField('检测日期', '检测日期')),
                    ]),
                    const SizedBox(height: 12),
                    _buildFieldRow2('样品来源', '样品来源', '抽样原则', '抽样原则'),
                    const SizedBox(height: 12),
                    _buildTextField('参考标准', '参考标准', maxLines: 2),
                    const SizedBox(height: 12),
                    _buildFieldRow3('检测人(签字)', '检测人员', '审核人(签字)', '审核人员', '批准人(签字)', '批准人员'),
                    const SizedBox(height: 28),

                    // ── Section 3: 项目概述与图片 ──
                    _buildSectionHeader('3. 项目概述与图片', Icons.image_outlined),
                    const SizedBox(height: 12),
                    _buildTextField('项目概述', '项目概述', maxLines: 3),
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(child: _buildImagePicker('光伏厂区地理位置图', _geographicImagePath, (p) {
                        setState(() => _geographicImagePath = p);
                        _projectInfo['geographic_image_path'] = p;
                        widget.onInfoChanged?.call(_projectInfo);
                      })),
                      const SizedBox(width: 24),
                      Expanded(child: _buildImagePicker('光伏厂区整体图', _overallImagePath, (p) {
                        setState(() => _overallImagePath = p);
                        _projectInfo['overall_image_path'] = p;
                        widget.onInfoChanged?.call(_projectInfo);
                      })),
                    ]),
                    const SizedBox(height: 28),

                    // ── Section 4: 电站基本信息表 ──
                    _buildSectionHeader('4. 电站基本信息表', Icons.table_chart_outlined),
                    const SizedBox(height: 12),
                    _buildStationInfoTable(),
                    const SizedBox(height: 28),

                    // ── Section 5: 设备信息 — 光伏组件参数 ──
                    _buildSectionHeader('5. 设备信息 — 光伏组件参数', Icons.solar_power_outlined),
                    const SizedBox(height: 12),
                    ..._buildPvModuleSections(),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() => _pvModules.add(_emptyPvModule())),
                        icon: const Icon(Icons.add_circle_outline, size: 16),
                        label: Text('添加光伏组件 ${_pvModules.length + 1}'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF22D3EE),
                          side: const BorderSide(color: Color(0xFF22D3EE), width: 1),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),

          // ── 底部操作栏 ──
          Container(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            decoration: BoxDecoration(
              border: const Border(top: BorderSide(color: Color(0xFF1E293B), width: 1)),
              gradient: LinearGradient(
                colors: [const Color(0xFF1E293B).withOpacity(0.5), const Color(0xFF0F172A)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: _buildActionButtons(),
          ),
        ],
      ),
    );
  }

  // ── 电站基本信息表 (严格按图片顺序) ──
  Widget _buildStationInfoTable() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF475569)),
        color: const Color(0xFF0F172A),
      ),
      child: Column(children: [
        // 表头
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          color: const Color(0xFF1E293B),
          child: const Text('电站基本信息表', textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        const Divider(height: 1, color: Color(0xFF475569)),

        // 行1: 项目名称 (全宽)
        _tRow1('项目名称', '项目名称'),
        // 行2: 电站地址 (全宽)
        _tRow1('电站地址', '电站地址'),
        // 行3: 联系人 | 联系方式
        _tRow2('联系人', '联系人', '联系方式', '联系方式'),
        // 行4: 业主单位名称 (全宽)
        _tRow1('业主单位名称', '业主单位名称'),
        // 行5: 设计单位名称 (全宽)
        _tRow1('设计单位名称', '设计单位名称'),
        // 行6: EPC单位名称 (全宽)
        _tRow1('EPC单位名称', 'EPC单位名称'),
        // 行7: 运维单位名称 (全宽)
        _tRow1('运维单位名称', '运维单位名称'),
        // 行8: 电站直流安装容量 | 分几期建设
        _tRow2('电站直流安装容量', '电站直流安装容量', '分几期建设', '分几期建设'),
        // 行9: 状态 (checkbox)
        _tCheckbox('状态', '建设状态', ['选址', '可研', '初设', '施工', '并网', '其他']),
        // 行10: 电站类型 (checkbox)
        _tCheckbox('电站类型', '电站类型', ['地面', '山地', '农业大棚', '渔光', '其他']),
        // 行11: 土地类型 (checkbox)
        _tCheckbox('土地类型', '土地类型', ['荒山/坡', '沙漠', '滩涂', '湖泊', '农田', '戈壁', '矿区(采煤沉陷区)']),
        // 行12: 土地现状 | 占地面积
        _tRow2('土地现状', '土地现状', '占地面积', '占地面积'),
        // 行13: 设计倾角 | 建设成本/W
        _tRow2('设计倾角', '设计倾角', '建设成本/W', '建设成本'),
        // 行14: 地理坐标 | 地形地貌
        _tRow2('地理坐标', '地理坐标', '地形地貌', '地形地貌'),
        // 行15: 水/土壤情况 (checkbox)
        _tCheckbox('水/土壤情况', '水/土壤情况', ['岩石', '沙地', '粉土', '其他']),
        // 行16: 电网接入方式 | 并网电压等级
        _tRow2('电网接入方式', '电网接入方式', '并网电压等级', '并网电压等级'),
        // 行17: 并网接入距离 | 主变容量
        _tRow2('并网接入距离', '并网接入距离', '主变容量', '主变容量'),
        // 行18: 是否限电 | 限电调控方式
        _tRow2('是否限电', '是否限电', '限电调控方式', '限电调控方式'),
        // 行19: 并网时间(容量) | 上网电价
        _tRow2('并网时间(容量)', '并网时间', '上网电价', '上网电价'),
        // 行20: 桩基形式 (checkbox)
        _tCheckbox('桩基形式', '桩基形式', ['锚栓', '灌注桩', '螺旋桩', '条形基础']),
        // 行21: 支架形式 (checkbox)
        _tCheckbox('支架形式', '支架形式', ['固定倾角', '单轴跟踪', '双轴跟踪', '平铺', '固定可调式']),
        // 行22: 单个组串组件数 | 组件固定方式
        _tRow2('单个组串组件数', '单个组串组件数', '组件固定方式', '组件固定方式'),
        // 行23: 组件下边缘距地高度 (全宽)
        _tRow1('组件下边缘距地高度', '组件下边缘距地高度'),
        // 行24: 是否配置气象站 | 气象站距离光伏区距离
        _tRow2('是否配置气象站', '是否配置气象站', '气象站距离光伏区距离', '气象站距离光伏区距离'),
        // 行25: 气象站厂家 | 气象站型号
        _tRow2('气象站厂家', '气象站厂家', '气象站型号', '气象站型号'),
        // 行26: 气象站采集数据类型 (checkbox)
        _tCheckbox('气象站采集数据类型', '气象站采集数据类型', ['平面辐照', '阵列面辐照', '直辐射', '散射计', '组件温度', '风速', '风向', '温湿度']),
      ]),
    );
  }

  // ── Table row builders (short names for readability) ──

  Widget _tRow1(String label, String key) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF475569)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _tLabel(label),
        Expanded(child: _tInput(key)),
      ]),
    );
  }

  Widget _tRow2(String l1, String k1, String l2, String k2) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF475569)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _tLabel(l1),
        Expanded(child: _tInput(k1)),
        Container(width: 1, color: const Color(0xFF475569)),
        _tLabel(l2),
        Expanded(child: _tInput(k2)),
      ]),
    );
  }

  Widget _tCheckbox(String label, String groupKey, List<String> options) {
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF475569)))),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _tLabel(label),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Wrap(
                spacing: 12, runSpacing: 4,
                children: options.map((opt) {
                  final sel = _checkboxSelections[groupKey]?.contains(opt) ?? false;
                  return InkWell(
                    onTap: () => setState(() {
                      _checkboxSelections[groupKey] ??= [];
                      sel ? _checkboxSelections[groupKey]!.remove(opt) : _checkboxSelections[groupKey]!.add(opt);
                    }),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(sel ? Icons.check_box : Icons.check_box_outline_blank, size: 16,
                          color: sel ? const Color(0xFF22D3EE) : const Color(0xFF64748B)),
                      const SizedBox(width: 4),
                      Text(opt, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12)),
                    ]),
                  );
                }).toList(),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tLabel(String text) {
    return Container(
      width: 150,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(right: BorderSide(color: Color(0xFF475569))),
      ),
      child: Text(text, textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  Widget _tInput(String key, {String? hint}) {
    return TextFormField(
      key: ValueKey('t-$key-${_projectInfo[key]}'),
      initialValue: _projectInfo[key]?.toString(),
      style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        border: InputBorder.none,
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF475569), fontSize: 12),
      ),
      onChanged: (v) { _projectInfo[key] = v; widget.onInfoChanged?.call(_projectInfo); _triggerAutoSave(); },
      onSaved: (v) => _projectInfo[key] = v,
    );
  }

  // ── Section header ──
  Widget _buildSectionHeader(String title, [IconData? icon]) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [const Color(0xFF0E7490).withOpacity(0.15), Colors.transparent],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        border: const Border(left: BorderSide(color: Color(0xFF22D3EE), width: 3)),
        borderRadius: const BorderRadius.only(topRight: Radius.circular(6), bottomRight: Radius.circular(6)),
      ),
      child: Row(children: [
        if (icon != null) ...[Icon(icon, color: const Color(0xFF22D3EE), size: 18), const SizedBox(width: 8)],
        Text(title, style: const TextStyle(color: Color(0xFF22D3EE), fontSize: 14, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  // ── Field row helpers for cover/due-diligence sections ──
  Widget _buildFieldRow2(String l1, String k1, String l2, String k2, {bool required1 = false, String? hint2}) {
    return Row(children: [
      Expanded(child: _buildTextField(l1, k1, required: required1)),
      const SizedBox(width: 16),
      Expanded(child: _buildTextField(l2, k2, placeholder: hint2)),
    ]);
  }

  Widget _buildFieldRow3(String l1, String k1, String l2, String k2, String l3, String k3) {
    return Row(children: [
      Expanded(child: _buildTextField(l1, k1, placeholder: '签字')),
      const SizedBox(width: 16),
      Expanded(child: _buildTextField(l2, k2, placeholder: '签字')),
      const SizedBox(width: 16),
      Expanded(child: _buildTextField(l3, k3, placeholder: '签字')),
    ]);
  }

  // ── 日期选择器 ──
  Widget _buildDateField(String label, String key) {
    final current = _projectInfo[key]?.toString() ?? '';
    return InkWell(
      onTap: () async {
        final initial = _parseDate(current) ?? DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: DateTime(2000),
          lastDate: DateTime(2050),
          locale: const Locale('zh'),
        );
        if (picked != null) {
          final str = '${picked.year}/${picked.month.toString().padLeft(2, '0')}/${picked.day.toString().padLeft(2, '0')}';
          setState(() => _projectInfo[key] = str);
          widget.onInfoChanged?.call(_projectInfo);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          filled: true, fillColor: const Color(0xFF1E293B),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          suffixIcon: const Icon(Icons.calendar_today, size: 16, color: Color(0xFF64748B)),
        ),
        child: Text(current.isEmpty ? '点击选择日期' : current,
            style: TextStyle(color: current.isEmpty ? const Color(0xFF475569) : const Color(0xFFE2E8F0), fontSize: 13)),
      ),
    );
  }

  DateTime? _parseDate(String s) {
    try {
      final parts = s.split('/');
      if (parts.length == 3) return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    } catch (_) {}
    return null;
  }

  // ── 日期范围选择器 ──
  Widget _buildDateRangeField(String label, String key) {
    final current = _projectInfo[key]?.toString() ?? '';
    return InkWell(
      onTap: () async {
        DateTimeRange? initial;
        if (current.contains('~')) {
          final parts = current.split('~');
          final s = _parseDate(parts[0].trim());
          final e = _parseDate(parts[1].trim());
          if (s != null && e != null) initial = DateTimeRange(start: s, end: e);
        }
        final picked = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2000),
          lastDate: DateTime(2050),
          initialDateRange: initial ?? DateTimeRange(start: DateTime.now(), end: DateTime.now().add(const Duration(days: 7))),
          locale: const Locale('zh'),
        );
        if (picked != null) {
          String fmt(DateTime d) => '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
          final str = '${fmt(picked.start)}~${fmt(picked.end)}';
          setState(() => _projectInfo[key] = str);
          widget.onInfoChanged?.call(_projectInfo);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          filled: true, fillColor: const Color(0xFF1E293B),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          suffixIcon: const Icon(Icons.date_range, size: 16, color: Color(0xFF64748B)),
        ),
        child: Text(current.isEmpty ? '点击选择日期范围' : current,
            style: TextStyle(color: current.isEmpty ? const Color(0xFF475569) : const Color(0xFFE2E8F0), fontSize: 13)),
      ),
    );
  }

  // ── 地址级联选择器 (省→市→区 + 详细地址) ──
  Widget _buildAddressField(String label, String key) {
    // 解析已有地址
    final current = _projectInfo[key]?.toString() ?? '';
    String province = '', city = '', detail = '';
    if (current.isNotEmpty) {
      // 尝试解析 "省/市/区 详细地址" 格式
      final match = RegExp(r'^(.+?)[省市](.+?)[市区县](.*)$').firstMatch(current);
      if (match != null) {
        detail = current; // 保留原始文本作为详细地址
      } else {
        detail = current;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
        const SizedBox(height: 4),
        InkWell(
          onTap: () => _showAddressDialog(key, current),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(children: [
              Expanded(child: Text(
                current.isEmpty ? '点击选择地址' : current,
                style: TextStyle(color: current.isEmpty ? const Color(0xFF475569) : const Color(0xFFE2E8F0), fontSize: 13),
                overflow: TextOverflow.ellipsis,
              )),
              const Icon(Icons.location_on_outlined, size: 16, color: Color(0xFF64748B)),
            ]),
          ),
        ),
      ],
    );
  }

  void _showAddressDialog(String key, String current) {
    String selProvince = '';
    String selCity = '';
    String selDistrict = '';
    String detailText = current;

    // 尝试从已有数据中恢复选择
    for (final prov in _chinaRegions.keys) {
      if (current.startsWith(prov)) {
        selProvince = prov;
        final cities = _chinaRegions[prov] ?? {};
        for (final city in cities.keys) {
          if (current.contains(city)) {
            selCity = city;
            final districts = cities[city] ?? [];
            for (final d in districts) {
              if (current.contains(d)) { selDistrict = d; break; }
            }
            break;
          }
        }
        break;
      }
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDlgState) {
          final cities = selProvince.isNotEmpty ? (_chinaRegions[selProvince] ?? {}) : <String, List<String>>{};
          final districts = selCity.isNotEmpty ? (cities[selCity] ?? []) : <String>[];

          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: const Text('选择地址', style: TextStyle(color: Colors.white, fontSize: 16)),
            content: SizedBox(
              width: 500,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  // 省
                  Expanded(child: DropdownButtonFormField<String>(
                    initialValue: selProvince.isEmpty ? null : selProvince,
                    hint: const Text('选择省份', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                    dropdownColor: const Color(0xFF334155),
                    style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), labelText: '省', labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                    items: _chinaRegions.keys.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                    onChanged: (v) => setDlgState(() { selProvince = v ?? ''; selCity = ''; selDistrict = ''; }),
                  )),
                  const SizedBox(width: 8),
                  // 市
                  Expanded(child: DropdownButtonFormField<String>(
                    initialValue: selCity.isEmpty ? null : selCity,
                    hint: const Text('选择城市', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                    dropdownColor: const Color(0xFF334155),
                    style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), labelText: '市', labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                    items: cities.keys.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                    onChanged: (v) => setDlgState(() { selCity = v ?? ''; selDistrict = ''; }),
                  )),
                  const SizedBox(width: 8),
                  // 区/县
                  Expanded(child: DropdownButtonFormField<String>(
                    initialValue: selDistrict.isEmpty ? null : selDistrict,
                    hint: const Text('选择区/县', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                    dropdownColor: const Color(0xFF334155),
                    style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), labelText: '区/县', labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                    items: districts.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                    onChanged: (v) => setDlgState(() => selDistrict = v ?? ''),
                  )),
                ]),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: detailText,
                  style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: '详细地址（可选）',
                    labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                    filled: true, fillColor: Color(0xFF0F172A),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => detailText = v,
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              ElevatedButton(
                onPressed: () {
                  final addr = [selProvince, selCity, selDistrict].where((s) => s.isNotEmpty).join('');
                  final full = detailText.isNotEmpty && !detailText.startsWith(addr)
                      ? '$addr$detailText'
                      : (addr.isNotEmpty ? addr : detailText);
                  setState(() => _projectInfo[key] = full);
                  widget.onInfoChanged?.call(_projectInfo);
                  Navigator.pop(ctx);
                },
                child: const Text('确定'),
              ),
            ],
          );
        });
      },
    );
  }

  // ── 中国省市区数据 (主要省会城市) ──
  static final Map<String, Map<String, List<String>>> _chinaRegions = {
    '北京市': {'北京市': ['东城区', '西城区', '朝阳区', '海淀区', '丰台区', '石景山区', '通州区', '顺义区', '大兴区', '昌平区', '房山区', '门头沟区', '怀柔区', '平谷区', '密云区', '延庆区']},
    '上海市': {'上海市': ['黄浦区', '徐汇区', '长宁区', '静安区', '普陀区', '虹口区', '杨浦区', '浦东新区', '闵行区', '宝山区', '嘉定区', '松江区', '金山区', '青浦区', '奉贤区', '崇明区']},
    '天津市': {'天津市': ['和平区', '河东区', '河西区', '南开区', '河北区', '红桥区', '东丽区', '西青区', '津南区', '北辰区', '武清区', '宝坻区', '滨海新区']},
    '重庆市': {'重庆市': ['渝中区', '大渡口区', '江北区', '沙坪坝区', '九龙坡区', '南岸区', '北碚区', '渝北区', '巴南区', '涪陵区', '万州区']},
    '河北省': {'石家庄市': ['长安区', '桥西区', '新华区', '裕华区'], '唐山市': ['路南区', '路北区', '丰润区'], '保定市': ['竞秀区', '莲池区'], '邯郸市': ['邯山区', '丛台区'], '廊坊市': ['广阳区', '安次区']},
    '山西省': {'太原市': ['小店区', '迎泽区', '杏花岭区', '万柏林区'], '大同市': ['平城区', '云冈区'], '运城市': ['盐湖区']},
    '辽宁省': {'沈阳市': ['沈河区', '和平区', '大东区', '皇姑区', '铁西区'], '大连市': ['中山区', '西岗区', '沙河口区', '甘井子区']},
    '吉林省': {'长春市': ['南关区', '宽城区', '朝阳区', '二道区'], '吉林市': ['昌邑区', '龙潭区']},
    '黑龙江省': {'哈尔滨市': ['道里区', '南岗区', '道外区', '香坊区'], '齐齐哈尔市': ['龙沙区', '建华区']},
    '江苏省': {'南京市': ['玄武区', '秦淮区', '建邺区', '鼓楼区', '栖霞区', '江宁区'], '苏州市': ['姑苏区', '吴中区', '相城区', '虎丘区'], '无锡市': ['梁溪区', '锡山区', '惠山区'], '常州市': ['天宁区', '钟楼区']},
    '浙江省': {'杭州市': ['上城区', '拱墅区', '西湖区', '滨江区', '余杭区', '临平区'], '宁波市': ['海曙区', '江北区', '鄞州区'], '温州市': ['鹿城区', '龙湾区'], '嘉兴市': ['南湖区', '秀洲区']},
    '安徽省': {'合肥市': ['蜀山区', '庐阳区', '瑶海区', '包河区'], '芜湖市': ['镜湖区', '弋江区'], '蚌埠市': ['蚌山区']},
    '福建省': {'福州市': ['鼓楼区', '台江区', '仓山区', '晋安区'], '厦门市': ['思明区', '湖里区', '集美区', '海沧区']},
    '江西省': {'南昌市': ['东湖区', '西湖区', '青山湖区', '红谷滩区'], '九江市': ['浔阳区', '濂溪区']},
    '山东省': {'济南市': ['历下区', '市中区', '槐荫区', '天桥区', '历城区'], '青岛市': ['市南区', '市北区', '崂山区', '黄岛区'], '烟台市': ['芝罘区', '福山区']},
    '河南省': {'郑州市': ['中原区', '二七区', '管城区', '金水区', '惠济区'], '洛阳市': ['涧西区', '西工区'], '开封市': ['龙亭区', '鼓楼区']},
    '湖北省': {'武汉市': ['江岸区', '江汉区', '硚口区', '汉阳区', '武昌区', '洪山区'], '宜昌市': ['西陵区', '点军区'], '襄阳市': ['襄城区', '樊城区']},
    '湖南省': {'长沙市': ['芙蓉区', '天心区', '岳麓区', '开福区', '雨花区'], '株洲市': ['天元区', '荷塘区'], '湘潭市': ['雨湖区', '岳塘区']},
    '广东省': {'广州市': ['天河区', '越秀区', '海珠区', '荔湾区', '白云区', '番禺区', '黄埔区'], '深圳市': ['福田区', '罗湖区', '南山区', '宝安区', '龙岗区', '龙华区'], '东莞市': ['东莞市'], '佛山市': ['禅城区', '南海区', '顺德区']},
    '广西壮族自治区': {'南宁市': ['兴宁区', '青秀区', '江南区', '良庆区'], '柳州市': ['城中区', '鱼峰区'], '桂林市': ['秀峰区', '叠彩区']},
    '海南省': {'海口市': ['龙华区', '美兰区', '琼山区', '秀英区'], '三亚市': ['吉阳区', '天涯区']},
    '四川省': {'成都市': ['锦江区', '青羊区', '金牛区', '武侯区', '成华区', '龙泉驿区'], '绵阳市': ['涪城区', '游仙区'], '德阳市': ['旌阳区']},
    '贵州省': {'贵阳市': ['南明区', '云岩区', '花溪区', '乌当区'], '遵义市': ['红花岗区', '汇川区']},
    '云南省': {'昆明市': ['五华区', '盘龙区', '官渡区', '西山区'], '大理白族自治州': ['大理市']},
    '陕西省': {'西安市': ['新城区', '碑林区', '莲湖区', '雁塔区', '未央区', '灞桥区'], '咸阳市': ['秦都区', '渭城区']},
    '甘肃省': {'兰州市': ['城关区', '七里河区', '安宁区', '西固区'], '天水市': ['秦州区', '麦积区']},
    '青海省': {'西宁市': ['城东区', '城中区', '城西区', '城北区']},
    '内蒙古自治区': {'呼和浩特市': ['新城区', '回民区', '玉泉区', '赛罕区'], '包头市': ['昆都仑区', '青山区']},
    '西藏自治区': {'拉萨市': ['城关区', '堆龙德庆区']},
    '宁夏回族自治区': {'银川市': ['兴庆区', '西夏区', '金凤区']},
    '新疆维吾尔自治区': {'乌鲁木齐市': ['天山区', '沙依巴克区', '新市区', '水磨沟区'], '克拉玛依市': ['独山子区', '克拉玛依区']},
  };

  Widget _buildTextField(String label, String key, {bool required = false, int maxLines = 1, String? placeholder}) {
    return TextFormField(
      key: ValueKey('$key-${_projectInfo[key]}'),
      initialValue: _projectInfo[key]?.toString(),
      maxLines: maxLines,
      style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        hintText: placeholder,
        filled: true,
        fillColor: const Color(0xFF1E293B),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
      ),
      validator: required ? (v) => (v == null || v.isEmpty) ? '必填' : null : null,
      onChanged: (v) { _projectInfo[key] = v; widget.onInfoChanged?.call(_projectInfo); _triggerAutoSave(); },
      onSaved: (v) => _projectInfo[key] = v,
    );
  }

  Widget _buildImagePicker(String label, String? path, Function(String) onPick) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      InkWell(
        onTap: () async {
          final result = await FilePicker.platform.pickFiles(type: FileType.image);
          if (result != null && result.files.single.path != null) onPick(result.files.single.path!);
        },
        child: Container(
          height: 180, width: double.infinity,
          decoration: BoxDecoration(color: const Color(0xFF1E293B), border: Border.all(color: const Color(0xFF475569))),
          child: path != null
              ? Image.file(File(path), fit: BoxFit.contain)
              : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.add_photo_alternate, size: 32, color: Color(0xFF64748B)),
                  SizedBox(height: 8),
                  Text('点击上传', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                ]),
        ),
      ),
      if (path != null)
        Padding(padding: const EdgeInsets.only(top: 4),
            child: Text(path.split(RegExp(r'[/\\]')).last, style: const TextStyle(color: Color(0xFF64748B), fontSize: 11))),
    ]);
  }

  // ── Action buttons ──
  Widget _buildActionButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (widget.onClose != null) ...[
          OutlinedButton(
            onPressed: widget.onClose,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF94A3B8),
              side: const BorderSide(color: Color(0xFF475569)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            child: const Text('取消'),
          ),
          const SizedBox(width: 12),
        ],
        ElevatedButton.icon(
          onPressed: _handleSave,
          icon: const Icon(Icons.save, size: 18),
          label: const Text('保存项目信息'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary, foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          ),
        ),
      ],
    );
  }

  void _handleExport(Function(Map<String, dynamic>) exportFn) {
    _formKey.currentState!.save();
    _collectCheckboxData();
    if (_geographicImagePath != null) _projectInfo['geographic_image_path'] = _geographicImagePath;
    if (_overallImagePath != null) _projectInfo['overall_image_path'] = _overallImagePath;
    exportFn(_projectInfo);
  }

  void _collectCheckboxData() {
    _checkboxSelections.forEach((key, selected) {
      List<String> options = [];
      if (key == '建设状态') {
        options = ['选址', '可研', '初设', '施工', '并网', '其他'];
      } else if (key == '电站类型') options = ['地面', '山地', '农业大棚', '渔光', '其他'];
      else if (key == '土地类型') options = ['荒山/坡', '沙漠', '滩涂', '湖泊', '农田', '戈壁', '矿区(采煤沉陷区)'];
      else if (key == '水/土壤情况') options = ['岩石', '沙地', '粉土', '其他'];
      else if (key == '桩基形式') options = ['锚栓', '灌注桩', '螺旋桩', '条形基础'];
      else if (key == '支架形式') options = ['固定倾角', '单轴跟踪', '双轴跟踪', '平铺', '固定可调式'];
      else if (key == '气象站采集数据类型') options = ['平面辐照', '阵列面辐照', '直辐射', '散射计', '组件温度', '风速', '风向', '温湿度'];

      if (options.isNotEmpty) {
        final str = options.map((opt) => selected.contains(opt) ? '☑ $opt' : '☐ $opt').join('  ');
        _projectInfo[key] = str;
      }
    });
    // 序列化光伏组件参数
    _projectInfo['pv_modules'] = _pvModules;
  }

  // ── 光伏组件参数 UI ──
  List<Widget> _buildPvModuleSections() {
    final widgets = <Widget>[];
    for (int i = 0; i < _pvModules.length; i++) {
      widgets.add(_buildPvModuleTable(i));
      if (i < _pvModules.length - 1) widgets.add(const SizedBox(height: 16));
    }
    return widgets;
  }

  Widget _buildPvModuleTable(int index) {
    final mod = _pvModules[index];
    final title = '光伏组件 ${index + 1}';
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF475569)),
        color: const Color(0xFF0F172A),
      ),
      child: Column(children: [
        // 表头 + 删除按钮
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          color: const Color(0xFF1E293B),
          child: Row(
            children: [
              Expanded(child: Text(title, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14))),
              if (index > 0)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Color(0xFFEF4444), size: 18),
                  tooltip: '删除此组件',
                  onPressed: () => setState(() => _pvModules.removeAt(index)),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF475569)),
        // Row 1: 生产厂家 | 型号
        _pvRow2(mod, '生产厂家', '型号'),
        // Row 2: 类型 | Pmax
        _pvRow2(mod, '类型', 'Pmax (Wp)'),
        // Row 3: Voc | Vmp
        _pvRow2(mod, 'Voc (V)', 'Vmp (V)'),
        // Row 4: Isc | Imp
        _pvRow2(mod, 'Isc (A)', 'Imp (A)'),
        // Row 5: 组件尺寸 | 短路电流温度系数
        _pvRow2(mod, '组件尺寸 (mm)', '短路电流温度系数 (%/°C)'),
        // Row 6: 功率温度系数 | 开路电压温度系数
        _pvRow2(mod, '功率温度系数 (%/°C)', '开路电压温度系数 (%/°C)'),
      ]),
    );
  }

  Widget _pvRow2(Map<String, String> mod, String k1, String k2) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF475569)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _tLabel(k1),
        Expanded(child: _pvInput(mod, k1)),
        Container(width: 1, color: const Color(0xFF475569)),
        _tLabel(k2),
        Expanded(child: _pvInput(mod, k2)),
      ]),
    );
  }

  Widget _pvInput(Map<String, String> mod, String key) {
    return TextFormField(
      initialValue: mod[key] ?? '',
      style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        border: InputBorder.none,
      ),
      onChanged: (v) {
        mod[key] = v;
        widget.onInfoChanged?.call(_projectInfo);
        _triggerAutoSave();
      },
    );
  }

  void _handleSave() {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    if (_geographicImagePath != null) _projectInfo['geographic_image_path'] = _geographicImagePath;
    if (_overallImagePath != null) _projectInfo['overall_image_path'] = _overallImagePath;

    _collectCheckboxData();

    widget.onSaveProject(_projectInfo);
  }
}
