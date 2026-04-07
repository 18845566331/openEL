import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';

class ReportConfigDialog extends StatefulWidget {
  final Map<String, dynamic> initialProjectInfo;

  const ReportConfigDialog({super.key, required this.initialProjectInfo});

  @override
  State<ReportConfigDialog> createState() => _ReportConfigDialogState();
}

class _ReportConfigDialogState extends State<ReportConfigDialog> {
  final _formKey = GlobalKey<FormState>();
  late Map<String, dynamic> _projectInfo;

  // Images
  String? _geographicImagePath;
  String? _overallImagePath;

  // Checkbox Selections (Multi-select logic for template string generation)
  final Map<String, List<String>> _checkboxSelections = {
    '建设状态': [], // 选址/可研/初设...
    '电站类型': [], // 地面/山地/农业大棚...
    '土地类型': [], // 荒山/沙漠...
    '水/土壤情况': [], // 岩石/沙地...
    '桩基形式': [], // 灌注桩/螺旋桩...
    '支架形式': [], // 固定倾角/固定可调...
    '气象站采集数据类型': [], // 平面辐射/阵列面辐射...
  };

  @override
  void initState() {
    super.initState();
    _projectInfo = Map.from(widget.initialProjectInfo);
    _initializeDefaults();
  }

  void _initializeDefaults() {
    final now = DateTime.now();
    final dateStr = "${now.year}/${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}";
    
    _setDefault('检测日期', dateStr);
    _setDefault('签发日期', dateStr);
    // Initialize image paths if passed in props
    if (widget.initialProjectInfo['geographic_image_path'] != null) {
      _geographicImagePath = widget.initialProjectInfo['geographic_image_path'];
    }
    if (widget.initialProjectInfo['overall_image_path'] != null) {
      _overallImagePath = widget.initialProjectInfo['overall_image_path'];
    }
  }

  void _setDefault(String key, String value) {
    if (_projectInfo[key] == null || _projectInfo[key].toString().isEmpty) {
      _projectInfo[key] = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)), // Sharp corners like printed doc
      child: Container(
        width: 1000,
        height: 900,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('生成检测报告 (严格模版布局)', style: TextStyle(color: Color(0xFFE6F0FF), fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(icon: const Icon(Icons.close, color: Color(0xFF94A3B8)), onPressed: () => Navigator.of(context).pop()),
              ],
            ),
            const SizedBox(height: 16),
            
            // Scrollable Content
            Expanded(
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      // Section 1: Cover Info
                      _buildSectionHeader('1. 报告封面信息'),
                      _buildCoverInfo(),
                      const SizedBox(height: 24),

                      // Section 2: Overview & Images
                      _buildSectionHeader('2. 项目概述与图片'),
                      _buildOverviewAndImages(),
                      const SizedBox(height: 24),

                      // Section 3: Station Basic Info Table (The Grid)
                      _buildSectionHeader('3. 电站基本信息表'),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFF475569)), // Outer border
                          color: const Color(0xFF0F172A),
                        ),
                        child: Column(
                          children: [
                            // Table Header
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              color: const Color(0xFF1E293B),
                              child: const Text('电站基本信息表', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                            ),
                            const Divider(height: 1, color: Color(0xFF475569)),

                            // Rows based directly on Image 4
                            _buildRow1Col('项目名称', '项目名称'),
                            _buildRow1Col('电站地址', '电站地址'), // Or '项目地址'? Image says '电站地址'
                            _buildRow2Col('联系人', '联系人', '联系方式', '联系方式'),
                            _buildRow1Col('业主单位名称', '业主单位名称'),
                            _buildRow1Col('设计单位名称', '设计单位名称'),
                            _buildRow1Col('EPC 单位名称', 'EPC单位名称'),
                            _buildRow1Col('运维单位名称', '运维单位名称'),
                            
                            // Capacity / Phases / Period
                            _buildRow3Col('电站直流安装容量', '电站直流安装容量', '分几期建设', '分几期建设', '建设期数', '第x期'), // "分几期" and "1期"

                            // Checkbox Rows
                            _buildCheckboxRow('状态', '建设状态', ['选址', '可研', '初设', '施工', '并网', '其他']),
                            _buildCheckboxRow('电站类型', '电站类型', ['地面', '山地', '农业大棚', '渔光', '其他']),
                            _buildCheckboxRow('土地类型', '土地类型', ['荒山/坡', '沙漠', '滩涂', '湖泊', '农田', '戈壁', '矿区']),

                            _buildRow2Col('土地现状', '土地现状', '占地面积', '占地面积'),
                            _buildRow2Col('设计倾角', '设计倾角', '建设成本', '建设成本'),
                            _buildRow2Col('地理坐标', '地理坐标', '地形地貌', '地形地貌'),
                            
                            _buildCheckboxRow('水/土壤情况', '水/土壤情况', ['岩石', '沙地', '粉土', '其他']),

                            _buildRow2Col('电网接入方式', '电网接入方式', '并网电压等级', '并网电压等级'),
                            _buildRow2Col('并网接入距离', '并网接入距离', '主变容量', '主变容量'),
                            _buildRow2Col('是否限电', '是否限电', '限电调控方式', '限电调控方式'),
                            _buildRow2Col('并网时间 (容量)', '并网时间', '上网电价', '上网电价'),
                            
                            _buildCheckboxRow('桩基形式', '桩基形式', ['锚栓', '灌注桩', '螺旋桩', '条形基础']),
                            _buildCheckboxRow('支架形式', '支架形式', ['固定倾角', '单轴跟踪', '双轴跟踪', '平铺', '固定可调式']),
                            
                            _buildRow2Col('单个组串组件数', '单个组串组件数', '组件固定方式', '组件固定方式'), // "压块固定"
                            _buildRow1Col('组件下边缘距地高度', '组件下边缘距地高度'),

                            // Weather Station
                            _buildRow2Col('是否配置气象站', '是否配置气象站', '气象站距离', '气象站距离光伏区距离'),
                            _buildRow2Col('气象站厂家', '气象站厂家', '气象站型号', '气象站型号'),
                            _buildCheckboxRow('气象站采集数据类型', '气象站采集数据类型', ['平面辐照', '阵列面辐照', '直辐射', '散射', '组件温度', '风速', '风向', '温湿度']), // Layout matches image approx
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            
            // Actions
            const SizedBox(height: 16),
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-Wiget Builders
  // ---------------------------------------------------------------------------

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(title, style: const TextStyle(color: Color(0xFF22D3EE), fontSize: 14, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildCoverInfo() {
    return GridView.count(
      crossAxisCount: 3,
      childAspectRatio: 5,
      shrinkWrap: true,
      mainAxisSpacing: 12,
      crossAxisSpacing: 24,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _buildTextField('报告编号', '报告编号', required: true),
        _buildTextField('委托单位', '委托单位'),
        _buildTextField('检测单位', '检测单位'),
        _buildTextField('签发日期', '签发日期'),
        _buildTextField('检测人员', '检测人员', placeholder: '签字'),
        _buildTextField('审核人员', '审核人员', placeholder: '签字'),
        _buildTextField('批准人员', '批准人员', placeholder: '签字'),
      ],
    );
  }

  Widget _buildOverviewAndImages() {
    return Column(
      children: [
        _buildTextField('项目概述', '项目概述', maxLines: 3),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _buildImagePicker('光伏厂区地理位置图', _geographicImagePath, (p) => setState(() => _geographicImagePath = p))),
            const SizedBox(width: 24),
            Expanded(child: _buildImagePicker('光伏厂区整体图', _overallImagePath, (p) => setState(() => _overallImagePath = p))),
          ],
        ),
      ],
    );
  }

  // --- Table Row Builders ---

  // Standard Bordered Input Field
  Widget _buildTableInput(String key, {String? hint}) {
    return TextFormField(
      initialValue: _projectInfo[key]?.toString(),
      style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        border: InputBorder.none,
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF475569), fontSize: 12),
      ),
      onSaved: (v) => _projectInfo[key] = v,
    );
  }

  // Label Cell
  Widget _buildTableLabel(String text, {double width = 120}) {
    return Container(
      width: width,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B), // Darker header/label bg
        border: Border(right: BorderSide(color: Color(0xFF475569))),
      ),
      child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }

  // 1-Column Row: [Label | Value (Expanded)]
  Widget _buildRow1Col(String label, String key) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF475569))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTableLabel(label),
          Expanded(child: _buildTableInput(key)),
        ],
      ),
    );
  }

  // 2-Column Row: [Label | Value | Label | Value]
  Widget _buildRow2Col(String label1, String key1, String label2, String key2) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF475569))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTableLabel(label1),
          Expanded(child: _buildTableInput(key1)),
          Container(width: 1, color: const Color(0xFF475569)), // Divider
          _buildTableLabel(label2),
          Expanded(child: _buildTableInput(key2)),
        ],
      ),
    );
  }

  // 3-Column Row (Special for Capacity/Phase/Period)
  Widget _buildRow3Col(String l1, String k1, String l2, String k2, String l3, String k3) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF475569))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTableLabel(l1, width: 120),
          Expanded(flex: 2, child: _buildTableInput(k1)),
          Container(width: 1, color: const Color(0xFF475569)),
          _buildTableLabel(l2, width: 90),
          Expanded(flex: 1, child: _buildTableInput(k2)),
          Container(width: 1, color: const Color(0xFF475569)),
          _buildTableLabel(l3, width: 70),
          Expanded(flex: 1, child: _buildTableInput(k3)),
        ],
      ),
    );
  }

  // Checkbox Row: [Label | Checkbox Group]
  Widget _buildCheckboxRow(String label, String groupKey, List<String> options) {
    // Note: We need to handle state for checkboxes
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF475569))),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTableLabel(label),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: options.map((opt) {
                     final isSelected = _checkboxSelections[groupKey]?.contains(opt) ?? false;
                     return InkWell(
                       onTap: () {
                         setState(() {
                           if (_checkboxSelections[groupKey] == null) _checkboxSelections[groupKey] = [];
                           if (isSelected) {
                             _checkboxSelections[groupKey]!.remove(opt);
                           } else {
                             _checkboxSelections[groupKey]!.add(opt);
                           }
                         });
                       },
                       child: Row(
                         mainAxisSize: MainAxisSize.min,
                         children: [
                           Icon(
                             isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                             size: 16,
                             color: isSelected ? const Color(0xFF22D3EE) : const Color(0xFF64748B),
                           ),
                           const SizedBox(width: 4),
                           Text(opt, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12)),
                         ],
                       ),
                     );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helper Widgets
  // ---------------------------------------------------------------------------

  Widget _buildTextField(String label, String key, {bool required = false, int maxLines = 1, String? placeholder}) {
    return TextFormField(
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
      validator: required ? (v) => (v == null || v.isEmpty) ? 'Required' : null : null,
      onSaved: (v) => _projectInfo[key] = v,
    );
  }

  Widget _buildImagePicker(String label, String? path, Function(String) onPick) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        InkWell(
          onTap: () async {
            final result = await FilePicker.platform.pickFiles(type: FileType.image);
            if (result != null && result.files.single.path != null) {
              onPick(result.files.single.path!);
            }
          },
          child: Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              border: Border.all(color: const Color(0xFF475569), style: BorderStyle.solid),
            ),
            child: path != null
                ? Image.file(File(path), fit: BoxFit.contain)
                : const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_photo_alternate, size: 32, color: Color(0xFF64748B)),
                      SizedBox(height: 8),
                      Text('点击上传', style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                    ],
                  ),
          ),
        ),
        if (path != null) 
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(path.split(RegExp(r'[/\\]')).last, style: const TextStyle(color: Color(0xFF64748B), fontSize: 11)),
          ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(color: Color(0xFF94A3B8))),
        ),
        const SizedBox(width: 16),
        ElevatedButton.icon(
          onPressed: _handleExport,
          icon: const Icon(Icons.description, size: 18),
          label: const Text('生成检测报告'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)), // Sharp
          ),
        ),
      ],
    );
  }

  void _handleExport() {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    // 1. Process Images
    if (_geographicImagePath != null) _projectInfo['geographic_image_path'] = _geographicImagePath;
    if (_overallImagePath != null) _projectInfo['overall_image_path'] = _overallImagePath;

    // 2. Process Checkboxes -> String Conversion
    // Template likely expects "☑ 选址 ☐ 可研 ..."
    // We will generate the string and save it to the key.
    // NOTE: The key names in _checkboxSelections match the form keys we want to populate.
    _checkboxSelections.forEach((key, selected) {
        // We need the full list of options to generate the string. 
        // We can infer them from the layout definition or store them map.
        // For simplicity, we'll iterate the known options in the build logic... but we can't access them here easily without refactoring.
        // Let's hardcode the options list here for the keys we know. It's duplication but safer for immediate fix.
        
        List<String> options = [];
        if (key == '建设状态') {
          options = ['选址', '可研', '初设', '施工', '并网', '其他'];
        } else if (key == '电站类型') options = ['地面', '山地', '农业大棚', '渔光', '其他'];
        else if (key == '土地类型') options = ['荒山/坡', '沙漠', '滩涂', '湖泊', '农田', '戈壁', '矿区'];
        else if (key == '水/土壤情况') options = ['岩石', '沙地', '粉土', '其他'];
        else if (key == '桩基形式') options = ['锚栓', '灌注桩', '螺旋桩', '条形基础'];
        else if (key == '支架形式') options = ['固定倾角', '单轴跟踪', '双轴跟踪', '平铺', '固定可调式'];
        else if (key == '气象站采集数据类型') options = ['平面辐照', '阵列面辐照', '直辐射', '散射', '组件温度', '风速', '风向', '温湿度'];
        
        if (options.isNotEmpty) {
           final str = options.map((opt) {
             final isChecked = selected.contains(opt);
             // Use proper unicode symbols
             return isChecked ? '☑ $opt' : '☐ $opt';
           }).join('  ');
           _projectInfo[key] = str;
        }
    });

    Navigator.of(context).pop({'type': 'Word', 'data': _projectInfo});
  }
}
